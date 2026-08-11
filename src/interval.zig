//! Interval arithmetic over `lanes` boxes at a time.
//!
//! `Interval(n)` is one *SIMD batch* of n independent intervals: every field is
//! an `n`-wide vector, every operation is branchless. The plotter always splits
//! a box into four children, so `Interval(4)` evaluates a whole quadtree split
//! in a single pass; `Interval(1)` is the ordinary scalar case and costs the
//! same as a hand-written scalar implementation.
//!
//! ## The value model
//!
//! A value is an *enclosure* `[lo, hi]` of `f` over a box, plus a `Decoration`
//! recording how much is known about `f` there - see `Decoration` below, which
//! is the lattice from IEEE 1788-2015 rather than a scheme invented here.
//!
//! The original implementation carried a set of disjoint intervals so that
//! `x/0`-style discontinuities showed up as a set of cardinality > 1. We keep
//! the hull and the decoration instead: the hull of a union is still a valid
//! enclosure, `dac` records exactly the fact the cardinality was consulted for,
//! and the whole evaluator becomes allocation-free and vectorizable.
//!
//! ## Rounding
//!
//! Every operation that rounds inflates its result outward far enough to absorb
//! that rounding, so the computed interval really does contain the exact one.

const std = @import("std");

/// Three-valued logic: a relation over a box is definitely true, definitely
/// false, or not yet decided.
pub const Tri = enum {
    false,
    true,
    unknown,

    pub fn fromBools(is_true: bool, is_false: bool) Tri {
        std.debug.assert(!(is_true and is_false));
        if (is_true) return .true;
        if (is_false) return .false;
        return .unknown;
    }
};

/// Comparison against zero. Every relation `lhs op rhs` is normalised to
/// `lhs - rhs op 0`, so this is the only comparison the plotter needs.
pub const Op = enum {
    eq,
    lt,
    le,
    gt,
    ge,

    pub fn holds(op: Op, v: f64) bool {
        return switch (op) {
            .eq => v == 0,
            .lt => v < 0,
            .le => v <= 0,
            .gt => v > 0,
            .ge => v >= 0,
        };
    }

    /// `holds` for a whole batch of samples: true if any lane satisfies it.
    ///
    /// A NaN needs no guard of its own. Every IEEE comparison against NaN is
    /// false, so a lane whose sample was lost simply fails to satisfy the
    /// relation, which is the answer a separate test would have produced.
    pub fn holdsAny(op: Op, v: anytype) bool {
        const zero: @TypeOf(v) = @splat(0);
        return @reduce(.Or, switch (op) {
            .eq => v == zero,
            .lt => v < zero,
            .le => v <= zero,
            .gt => v > zero,
            .ge => v >= zero,
        });
    }

    /// How the comparison is written. `parse.zig` matches against this rather
    /// than against spellings of its own, so each operator is spelled in
    /// exactly one place and callers never learn a second name for it.
    pub fn symbol(op: Op) []const u8 {
        return switch (op) {
            .eq => "=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
        };
    }
};

const eps: f64 = std.math.floatEps(f64);
/// Absolute slack for results that underflow: rounding a subnormal is off by at
/// most half of this. Using the smallest *normal* here instead would over-widen
/// every interval near zero by a factor of 2^52.
const tiny: f64 = std.math.floatTrueMin(f64);
const pi = std.math.pi;
const pi_2 = pi * 2.0;
const pi_3 = pi * 3.0;
const pi_half = pi / 2.0;

/// What is known about `f` on the box, as the decoration lattice of
/// IEEE 1788-2015 (clause 8): the values are ordered by how much they claim,
/// and an operation's decoration is the *minimum* of its operands' and its own.
/// That single rule replaces per-property bookkeeping - there is nothing to
/// forget to propagate.
///
/// Only the four values this plotter can distinguish are kept; the standard's
/// `com` (additionally bounded) buys nothing here, because a bounded enclosure
/// is already visible in `lo` and `hi`.
pub const Decoration = enum(u2) {
    /// Nowhere defined on the box. Nothing to draw.
    ill = 0,
    /// Defined somewhere, but not everywhere, or with a jump inside.
    trv = 1,
    /// Defined at every point of the box.
    def = 2,
    /// Defined and continuous at every point of the box.
    dac = 3,

    pub fn isDefined(d: Decoration) bool {
        return @intFromEnum(d) >= @intFromEnum(Decoration.def);
    }

    /// Continuity is only ever claimed together with definedness, which is
    /// exactly what the intermediate value theorem needs.
    pub fn isContinuous(d: Decoration) bool {
        return d == .dac;
    }
};

pub fn Interval(comptime lanes: comptime_int) type {
    return struct {
        const Self = @This();

        pub const F = @Vector(lanes, f64);
        pub const M = @Vector(lanes, bool);
        pub const D = @Vector(lanes, u2);

        lo: F,
        hi: F,
        dec: D,

        pub inline fn vec(v: f64) F {
            return @splat(v);
        }
        pub inline fn dvec(d: Decoration) D {
            return @splat(@intFromEnum(d));
        }

        /// A NaN here can only have come from evaluating something outside its
        /// domain, so the value is `ill`, not merely unknown.
        pub fn splat(v: f64) Self {
            const value = vec(v);
            return (Self{ .lo = value, .hi = value, .dec = dvec(.dac) }).erase(value != value);
        }

        pub fn init(lo: F, hi: F) Self {
            return .{ .lo = lo, .hi = hi, .dec = dvec(.dac) };
        }

        /// Broadcast a single scalar interval across all lanes.
        pub fn repeat(lo: f64, hi: f64) Self {
            return init(vec(lo), vec(hi));
        }

        pub fn decoration(self: Self, comptime i: usize) Decoration {
            return @enumFromInt(self.dec[i]);
        }

        // -- internals ---------------------------------------------------

        /// NaN means "we lost track of the true value"; the only sound
        /// replacement is the corresponding infinity.
        inline fn scrub(v: F, replacement: f64) F {
            return @select(f64, v != v, vec(replacement), v);
        }

        /// Inflate by `roundings` ulps on each side, absorbing that many
        /// round-to-nearest steps in the operation that produced `lo`/`hi`, and
        /// canonicalise the result.
        ///
        /// Infinite bounds are left alone: they need no slack, and widening one
        /// would compute `inf - inf`.
        ///
        /// A NaN bound means an intermediate overflowed and the value was lost.
        /// The sound reading is "somewhere on the real line", *not* "undefined"
        /// - the function itself may be perfectly well defined there, since
        /// `exp(x) - exp(x)` is zero however large `x` is, and erasing it would
        /// throw away real solutions. Every operation that can produce a NaN
        /// ends here, so no call site has to remember.
        inline fn inflate(self: Self, roundings: F) Self {
            const infinite = vec(std.math.inf(f64));
            const slack = roundings * vec(eps);
            var out = self;
            out.lo = @select(f64, @abs(self.lo) == infinite, self.lo, self.lo - (@abs(self.lo) * slack + vec(tiny)));
            out.hi = @select(f64, @abs(self.hi) == infinite, self.hi, self.hi + (@abs(self.hi) * slack + vec(tiny)));
            out.lo = @select(f64, out.lo != out.lo, -infinite, out.lo);
            out.hi = @select(f64, out.hi != out.hi, infinite, out.hi);
            return out;
        }

        /// The common case: the operation rounded once.
        inline fn widen(self: Self) Self {
            return self.inflate(vec(1));
        }

        /// The whole propagation rule: a result knows no more than its least
        /// informative operand.
        inline fn join(a: Self, b: Self, lo: F, hi: F) Self {
            return .{ .lo = lo, .hi = hi, .dec = @min(a.dec, b.dec) };
        }

        /// Lower the decoration of the selected lanes to at most `to`.
        inline fn demote(self: Self, bad: M, comptime to: Decoration) Self {
            var out = self;
            out.dec = @min(self.dec, @select(u2, bad, dvec(to), dvec(.dac)));
            return out;
        }

        /// Mark lanes as nowhere-defined. Their bounds become the whole line so
        /// that a caller who ignores the decoration still gets a sound - if
        /// useless - enclosure rather than a wrong one.
        inline fn erase(self: Self, bad: M) Self {
            var out = self.demote(bad, .ill);
            out.lo = @select(f64, bad, vec(-std.math.inf(f64)), self.lo);
            out.hi = @select(f64, bad, vec(std.math.inf(f64)), self.hi);
            return out;
        }

        // -- arithmetic --------------------------------------------------

        pub fn add(a: Self, b: Self) Self {
            return join(a, b, a.lo + b.lo, a.hi + b.hi).widen();
        }

        pub fn sub(a: Self, b: Self) Self {
            return join(a, b, a.lo - b.hi, a.hi - b.lo).widen();
        }

        pub fn neg(self: Self) Self {
            var out = self;
            out.lo = -self.hi;
            out.hi = -self.lo;
            return out;
        }

        pub fn mul(a: Self, b: Self) Self {
            const p0 = a.lo * b.lo;
            const p1 = a.lo * b.hi;
            const p2 = a.hi * b.lo;
            const p3 = a.hi * b.hi;
            const inf = std.math.inf(f64);
            const lo = @min(
                @min(scrub(p0, -inf), scrub(p1, -inf)),
                @min(scrub(p2, -inf), scrub(p3, -inf)),
            );
            const hi = @max(
                @max(scrub(p0, inf), scrub(p1, inf)),
                @max(scrub(p2, inf), scrub(p3, inf)),
            );
            return join(a, b, lo, hi).widen();
        }

        /// Division. A divisor reaching zero drops the quotient to `trv`: there
        /// is a pole on the box, so a sign change across it is not evidence of
        /// a root.
        pub fn div(a: Self, b: Self) Self {
            const zero = vec(0);
            const one = vec(1);
            const infinite = vec(std.math.inf(f64));

            // A divisor that merely *touches* zero leaves the quotient bounded
            // on one side, and that surviving bound is what lets `decide` prove
            // a sign. Only a divisor with zero strictly inside gives up both.
            const at_lo = b.lo == zero;
            const at_hi = b.hi == zero;
            const inside = (b.lo < zero) & (b.hi > zero);
            const degenerate = at_lo & at_hi;
            const straddles = (b.lo <= zero) & (b.hi >= zero);

            // Write the unbounded sides out explicitly rather than dividing by
            // zero and cleaning up afterwards.
            const recip = Self{
                .lo = @select(f64, at_hi | inside, -infinite, one / b.hi),
                .hi = @select(f64, at_lo | inside, infinite, one / b.lo),
                .dec = b.dec,
            };

            // Crossing or touching zero means the quotient is undefined at that
            // point and jumps across it, whatever the bounds came out as.
            return a.mul(recip.widen()).demote(straddles, .trv).erase(degenerate);
        }

        /// The sign function's range over the interval. Straddling zero widens
        /// to `[-1, 1]`, which is what makes `|a|` differentiable-with-slack in
        /// `dual.zig` instead of silently wrong at the kink.
        pub fn sign(self: Self) Self {
            const zero = vec(0);
            var out = self;
            out.lo = @select(f64, self.lo > zero, vec(1), vec(-1));
            out.hi = @select(f64, self.hi < zero, vec(-1), vec(1));
            return out;
        }

        pub fn abs(self: Self) Self {
            const zero = vec(0);
            const spans = (self.lo <= zero) & (self.hi >= zero);
            const a = @abs(self.lo);
            const b = @abs(self.hi);
            var out = self;
            out.lo = @select(f64, spans, zero, @min(a, b));
            out.hi = @max(a, b);
            return out;
        }

        /// `min` and `max` are exact on endpoints - the smaller of two
        /// representable numbers is representable - so neither widens, and
        /// both are continuous, so neither demotes. They have a kink on
        /// `{a = b}`, which is `abs`'s kink at zero and is handled the same
        /// way, in `dual.zig`, by letting `sign` widen there.
        pub fn min(a: Self, b: Self) Self {
            return join(a, b, @min(a.lo, b.lo), @min(a.hi, b.hi));
        }

        pub fn max(a: Self, b: Self) Self {
            return join(a, b, @max(a.lo, b.lo), @max(a.hi, b.hi));
        }

        /// Exact as well: the floor of an interval is the interval of the
        /// floors, with no rounding to absorb.
        ///
        /// These are the only operators here that are defined everywhere and
        /// continuous only sometimes. A box whose image crosses an integer
        /// contains a jump, which is `def`; `contour` reads that and refuses
        /// the cell rather than tracing across the step.
        ///
        /// `ceil` is `-floor(-x)` and `neg` costs nothing here, so having it as
        /// an operator of its own buys no tightness - only one node in the
        /// evaluation loop instead of three, and a name people expect to find.
        pub fn floor(self: Self) Self {
            var out = self;
            out.lo = @floor(self.lo);
            out.hi = @floor(self.hi);
            return out.demote(out.lo != out.hi, .def);
        }

        pub fn ceil(self: Self) Self {
            var out = self;
            out.lo = @ceil(self.lo);
            out.hi = @ceil(self.hi);
            return out.demote(out.lo != out.hi, .def);
        }

        /// `a - m floor(a/m)`: the modulo that takes the sign of its divisor,
        /// as Python and every graphing calculator spell it.
        ///
        /// Not `@mod`, which disagrees for a negative divisor - `@mod(7, -3)`
        /// is 1 where this is -2. Either convention would do, but the three
        /// domains have to pick the same one, and the range bound below is
        /// only sound for this one.
        ///
        /// Two enclosures are computed and intersected, because each is
        /// hopeless exactly where the other is tight. The composition is exact
        /// while the box stays inside one period and useless once it does not:
        /// `[0,10] mod 3` comes out as `[-9, 10]`. The range bound - a modulo
        /// lies between zero and its divisor - knows nothing about which
        /// period but pins that case to `[0, 3]`.
        pub fn mod(a: Self, m: Self) Self {
            const zero = vec(0);
            const composed = a.sub(m.mul(a.div(m).floor()));

            // `0` and `m` bound the *exact* modulo, and clipping to them would
            // cut off the sampler, which computes the same subtraction in
            // floating point and loses `ulp(a)` to cancellation - an absolute
            // error, at the scale of `a` rather than of the small result. The
            // range bound is given that much room before it is allowed to
            // tighten anything.
            const slack = @max(@abs(a.lo), @abs(a.hi)) * vec(2 * eps) + vec(tiny);

            var out = composed;
            out.lo = @max(composed.lo, @min(zero, m.lo) - slack);
            out.hi = @min(composed.hi, @max(zero, m.hi) + slack);

            // Two sound enclosures of the same set cannot fail to meet, so an
            // empty intersection would mean one of them is wrong. Keeping the
            // composition is the conservative reading of that.
            const empty = out.lo > out.hi;
            out.lo = @select(f64, empty, composed.lo, out.lo);
            out.hi = @select(f64, empty, composed.hi, out.hi);
            return out;
        }

        inline fn powVec(v: F, n: u32) F {
            var acc: F = vec(1);
            var base = v;
            var e = n;
            while (e != 0) : (e >>= 1) {
                if (e & 1 != 0) acc *= base;
                base *= base;
            }
            return acc;
        }

        /// Integer power. Evaluating `x^2` as a power rather than as `x * x`
        /// matters: `[-1,1] * [-1,1]` is `[-1,1]`, but `[-1,1]^2` is `[0,1]`.
        pub fn powi(self: Self, n: i32) Self {
            if (n == 0) {
                var out = self;
                out.lo = vec(1);
                out.hi = vec(1);
                return out;
            }
            // The exponent is only ever needed as a magnitude, and `@abs` of a
            // signed integer is unsigned - so the most negative i32 is
            // representable here, where recursing on `-n` for a negative
            // exponent would overflow on it. See `real.powi`.
            const k: u32 = @abs(n);
            const a = powVec(self.lo, k);
            const b = powVec(self.hi, k);
            var out = self;
            if (k % 2 == 0) {
                const spans = (self.lo <= vec(0)) & (self.hi >= vec(0));
                out.lo = @select(f64, spans, vec(0), @min(a, b));
                out.hi = @max(a, b);
            } else {
                out.lo = a;
                out.hi = b;
            }
            // Binary exponentiation rounds up to twice per bit of the exponent
            // and the errors compound, so the slack has to track the exponent.
            // One ulp - enough for the single multiply of `x^2` - is not enough
            // for anything beyond it.
            const roundings: f64 = @floatFromInt(2 * (32 - @clz(k)));
            out = out.inflate(vec(roundings));
            return if (n < 0) splat(1).div(out) else out;
        }

        // -- transcendental ----------------------------------------------

        /// cos over an interval, branchlessly.
        ///
        /// Reduce `lo` into `[0, 2pi)` and let `b = a + width`. On `[0, 4pi)`
        /// the extrema of cos sit at `0, pi, 2pi, 3pi`, so the result is
        /// determined by whether the reduced interval covers one of them.
        ///
        /// The reduction `lo - 2pi*k` is inexact, with an error that grows with
        /// `|k|` rather than with `|lo|`:
        ///
        ///     |k| * |2pi_f64 - 2pi|   <= |k| * 2.450e-16
        ///   + rounding of 2pi_f64 * k <= |k| * pi * eps
        ///   + rounding of the residue <=  2 * eps
        ///   ------------------------------------------
        ///                             ~  4.25 * |k| * eps + 2 * eps
        ///
        /// Budgeting 8 ulps per unit of `k` leaves close to 2x margin, and also
        /// covers the rounding of `hi - lo` and of `b = a + w` below. Rather
        /// than pick an arbitrary cutoff for "too large to reduce", the error is
        /// folded into the interval, which keeps the enclosure honest for small
        /// arguments and lets a huge argument degrade smoothly into `[-1, 1]`.
        pub fn cos(self: Self) Self {
            const k = @floor(self.lo / vec(pi_2));
            const err = (@abs(k) + vec(1)) * vec(8 * eps);
            const w = (self.hi - self.lo) + err + err;

            const a = (self.lo - vec(pi_2) * k) - err;
            const b = a + w;

            const ca = @cos(a);
            const cb = @cos(b);

            const has_min = ((a <= vec(pi)) & (b >= vec(pi))) | (b >= vec(pi_3));
            const has_max = (a <= vec(0)) | (b >= vec(pi_2));

            var lo = @select(f64, has_min, vec(-1), @min(ca, cb));
            var hi = @select(f64, has_max, vec(1), @max(ca, cb));

            // Anything wider than a full period, or non-finite, is the full range.
            const full = (w >= vec(pi_2)) | (self.lo != self.lo) | (self.hi != self.hi) |
                (@abs(self.lo) == vec(std.math.inf(f64))) | (@abs(self.hi) == vec(std.math.inf(f64)));
            lo = @select(f64, full, vec(-1), lo);
            hi = @select(f64, full, vec(1), hi);

            var out = self;
            out.lo = lo;
            out.hi = hi;
            out = out.widen();
            out.lo = @max(out.lo, vec(-1));
            out.hi = @min(out.hi, vec(1));
            return out;
        }

        pub fn sin(self: Self) Self {
            var shifted = self;
            shifted.lo = self.lo - vec(pi_half);
            shifted.hi = self.hi - vec(pi_half);
            return shifted.widen().cos();
        }

        pub fn tan(self: Self) Self {
            return self.sin().div(self.cos());
        }

        /// exp is increasing everywhere, so the endpoints map to the endpoints.
        pub fn exp(self: Self) Self {
            var out = self;
            out.lo = @exp(self.lo);
            out.hi = @exp(self.hi);
            return out.widen();
        }

        pub fn sqrt(self: Self) Self {
            const zero = vec(0);
            var out = self.erase(self.hi < zero).demote(self.lo < zero, .trv);
            out.lo = @sqrt(@max(out.lo, zero));
            out.hi = @sqrt(@max(out.hi, zero));
            return out.widen().erase(self.hi < zero);
        }

        pub fn log(self: Self) Self {
            const zero = vec(0);
            var out = self.erase(self.hi <= zero).demote(self.lo <= zero, .trv);
            out.lo = @select(f64, self.lo <= zero, vec(-std.math.inf(f64)), @log(self.lo));
            out.hi = @log(@max(self.hi, vec(tiny)));
            return out.widen().erase(self.hi <= zero);
        }

        /// asin/acos are only defined on [-1, 1]; clamp, and record whether the
        /// clamping threw information away.
        inline fn clampUnit(self: Self) Self {
            const outside = (self.hi < vec(-1)) | (self.lo > vec(1));
            const partial = (self.lo < vec(-1)) | (self.hi > vec(1));
            var out = self.demote(partial, .trv).erase(outside);
            out.lo = @max(@min(out.lo, vec(1)), vec(-1));
            out.hi = @max(@min(out.hi, vec(1)), vec(-1));
            return out;
        }

        pub fn asin(self: Self) Self {
            var out = self.clampUnit();
            const lo = out.lo;
            const hi = out.hi;
            inline for (0..lanes) |i| {
                out.lo[i] = std.math.asin(lo[i]);
                out.hi[i] = std.math.asin(hi[i]);
            }
            return out.widen();
        }

        pub fn acos(self: Self) Self {
            var out = self.clampUnit();
            const lo = out.lo;
            const hi = out.hi;
            inline for (0..lanes) |i| {
                out.lo[i] = std.math.acos(hi[i]);
                out.hi[i] = std.math.acos(lo[i]);
            }
            return out.widen();
        }

        pub fn atan(self: Self) Self {
            var out = self;
            inline for (0..lanes) |i| {
                out.lo[i] = std.math.atan(self.lo[i]);
                out.hi[i] = std.math.atan(self.hi[i]);
            }
            return out.widen();
        }

        // -- decision ----------------------------------------------------

        /// Per-lane verdict of `self op 0`, as a pair of masks. A lane is
        /// `unknown` when it appears in neither.
        pub const Verdict = struct {
            yes: M,
            no: M,

            /// Vectors of `bool` cannot be indexed at runtime, which is a
            /// feature here: callers unroll over the lanes.
            pub fn tri(self: Verdict, comptime i: usize) Tri {
                return Tri.fromBools(self.yes[i], self.no[i]);
            }
        };

        /// Decide `self op 0` over the box.
        ///
        /// Note the closed forms: `f < 0` is definitely *false* as soon as
        /// `lo >= 0`, not merely when `lo > 0`. The original used the strict
        /// test, so any box whose lower bound landed exactly on the boundary
        /// stayed `unknown` forever and was subdivided to the depth limit.
        ///
        /// `.eq` can only be proved by a bit-exact degenerate interval, which
        /// no arithmetic result is: every operation ends in `inflate`, so an
        /// exact zero comes back as `[-tiny, +tiny]`. That is not a gap to be
        /// closed - an outward-rounded enclosure genuinely cannot witness
        /// pointwise equality - which is why equalities are painted by
        /// `Prober.hasSolution` sampling for a sign change instead.
        pub fn decide(self: Self, op: Op) Verdict {
            const zero = vec(0);
            var v: Verdict = switch (op) {
                .eq => .{ .yes = (self.lo == zero) & (self.hi == zero), .no = (self.lo > zero) | (self.hi < zero) },
                .lt => .{ .yes = self.hi < zero, .no = self.lo >= zero },
                .le => .{ .yes = self.hi <= zero, .no = self.lo > zero },
                .gt => .{ .yes = self.lo > zero, .no = self.hi <= zero },
                .ge => .{ .yes = self.lo >= zero, .no = self.hi < zero },
            };
            // Where nothing is defined there is nothing to draw.
            const alive = self.dec != dvec(.ill);
            v.yes = @select(bool, alive, v.yes, @as(M, @splat(false)));
            v.no = @select(bool, alive, v.no, @as(M, @splat(true)));
            return v;
        }
    };
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;
const Iv = Interval(1);

fn expectEncloses(iv: Iv, v: f64) !void {
    try testing.expect(iv.lo[0] <= v and v <= iv.hi[0]);
}

test "arithmetic encloses the exact result" {
    const a = Iv.repeat(1, 2);
    const b = Iv.repeat(3, 4);
    try testing.expect(a.add(b).lo[0] <= 4 and a.add(b).hi[0] >= 6);
    try testing.expect(a.sub(b).lo[0] <= -3 and a.sub(b).hi[0] >= -1);
    try testing.expect(a.mul(b).lo[0] <= 3 and a.mul(b).hi[0] >= 8);
}

test "mul handles sign combinations and zero times infinity" {
    const m = Iv.repeat(-2, 3).mul(Iv.repeat(-5, 7));
    try testing.expect(m.lo[0] <= -15 and m.hi[0] >= 21);

    const inf = std.math.inf(f64);
    const z = Iv.repeat(0, 0).mul(Iv.repeat(-inf, inf));
    try testing.expect(!std.math.isNan(z.lo[0]) and !std.math.isNan(z.hi[0]));
}

test "squaring is tighter than self-multiplication" {
    const x = Iv.repeat(-1, 1);
    try testing.expect(x.mul(x).lo[0] < -0.5); // [-1, 1]
    try testing.expect(x.powi(2).lo[0] >= -1e-9); // [0, 1]
    try testing.expect(x.powi(2).hi[0] >= 1);
    try testing.expect(x.powi(3).lo[0] <= -1 and x.powi(3).hi[0] >= 1);
}

test "cos and sin enclose sampled values everywhere" {
    var seed: u64 = 0x9E3779B97F4A7C15;
    var rng = std.Random.DefaultPrng.init(seed);
    const r = rng.random();
    for (0..2000) |_| {
        const lo = (r.float(f64) - 0.5) * 60;
        const w = r.float(f64) * 8;
        const iv = Iv.repeat(lo, lo + w);
        const c = iv.cos();
        const s = iv.sin();
        for (0..64) |k| {
            const t = lo + w * (@as(f64, @floatFromInt(k)) / 63.0);
            try expectEncloses(c, @cos(t));
            try expectEncloses(s, @sin(t));
        }
        try testing.expect(c.lo[0] >= -1 and c.hi[0] <= 1);
    }
    seed = 0;
}

// The defining property of every operation: whatever `f` does at a point of the
// box, the computed interval contains it. `Interval` and `Real` expose the same
// operation names, so the checks below are the same expression in two domains.
test "every unary operation encloses the values it takes" {
    const Real = @import("real.zig").Real(1);
    var rng = std.Random.DefaultPrng.init(0x243F6A8885A308D3);
    const r = rng.random();
    const names = .{ "neg", "abs", "sin", "cos", "tan", "exp", "sqrt", "log", "asin", "acos", "atan" };

    for (0..3000) |_| {
        const lo = (r.float(f64) - 0.5) * 20;
        const hi = lo + r.float(f64) * 4;
        const box = Iv.repeat(lo, hi);

        inline for (names) |name| {
            const enclosure = @field(Iv, name)(box);
            var any_defined = false;
            for (0..33) |k| {
                const t = lo + (hi - lo) * (@as(f64, @floatFromInt(k)) / 32.0);
                const v = @field(Real, name)(Real.splat(t)).v[0];
                if (std.math.isNan(v)) continue;
                any_defined = true;
                if (!(enclosure.lo[0] <= v and v <= enclosure.hi[0])) {
                    std.debug.print("{s}([{d}, {d}]) = [{d}, {d}] misses f({d}) = {d}\n", .{
                        name, lo, hi, enclosure.lo[0], enclosure.hi[0], t, v,
                    });
                    return error.NotAnEnclosure;
                }
            }
            // Claiming "nowhere defined" while a sample was defined is a lie.
            if (any_defined) try testing.expect((enclosure.decoration(0) != .ill));
        }

    }
}

/// `x^n` computed exactly, as the reference for `powi`.
///
/// Checking `Interval.powi` against `Real.powi` would be vacuous: they run the
/// same binary-exponentiation loop, so the reference reproduces the very
/// rounding the test is supposed to detect.
fn exactPow(v: f64, n: i32) f128 {
    var acc: f128 = 1;
    const wide: f128 = v;
    for (0..@abs(n)) |_| acc *= wide;
    return if (n < 0) 1.0 / acc else acc;
}

test "powi encloses the exact power, not merely the one we would compute" {
    var rng = std.Random.DefaultPrng.init(0xA4093822299F31D0);
    const r = rng.random();

    for (0..2000) |_| {
        const lo = (r.float(f64) - 0.5) * 5;
        const hi = lo + r.float(f64) * 2;
        const box = Iv.repeat(lo, hi);

        inline for (.{ -3, -2, -1, 0, 1, 2, 3, 4, 8, 16, 31 }) |n| {
            const enclosure = box.powi(n);
            for (0..17) |k| {
                const t = lo + (hi - lo) * (@as(f64, @floatFromInt(k)) / 16.0);
                const exact = exactPow(t, n);
                if (!std.math.isFinite(@as(f64, @floatCast(exact)))) continue;
                if (!(@as(f128, enclosure.lo[0]) <= exact and exact <= @as(f128, enclosure.hi[0]))) {
                    std.debug.print("powi([{d}, {d}], {d}) = [{d}, {d}] misses {d}^{d}\n", .{
                        lo, hi, n, enclosure.lo[0], enclosure.hi[0], t, n,
                    });
                    return error.NotAnEnclosure;
                }
            }
        }
    }
}

test "cos and sin stay enclosures across the whole magnitude range" {
    // Argument reduction degrades with |x|, so the sweep has to reach the
    // magnitudes where it degrades. Sampling only |x| < 30, as the test above
    // does, cannot see it.
    var rng = std.Random.DefaultPrng.init(0x082EFA98EC4E6C89);
    const r = rng.random();

    for (0..400) |decade| {
        const scale = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(decade % 20)) - 3.0);
        for (0..50) |_| {
            const lo = (r.float(f64) - 0.5) * 2 * scale;
            const hi = lo + r.float(f64) * scale * 0.01;
            const c = Iv.repeat(lo, hi).cos();
            const s = Iv.repeat(lo, hi).sin();
            for (0..17) |k| {
                const t = lo + (hi - lo) * (@as(f64, @floatFromInt(k)) / 16.0);
                if (!(c.lo[0] <= @cos(t) and @cos(t) <= c.hi[0])) {
                    std.debug.print("cos([{d}, {d}]) = [{d}, {d}] misses cos({d}) = {d}\n", .{
                        lo, hi, c.lo[0], c.hi[0], t, @cos(t),
                    });
                    return error.NotAnEnclosure;
                }
                try testing.expect(s.lo[0] <= @sin(t) and @sin(t) <= s.hi[0]);
            }
        }
    }
}

test "a lost value never becomes a confident one" {
    // exp overflows for any argument past ~710, and inf - inf is NaN. That is a
    // loss of information, not an undefined point: the function is perfectly
    // well defined, so the interval must widen to the whole line and keep `any`
    // rather than erase itself and take real solutions with it.
    const big = Iv.repeat(1000, 1001).exp();
    inline for (.{ big.sub(big), big.add(big.neg()) }) |lost| {
        try testing.expect(!std.math.isNan(lost.lo[0]) and !std.math.isNan(lost.hi[0]));
        try testing.expect((lost.decoration(0) != .ill));
        try testing.expectEqual(Tri.unknown, lost.decide(.lt).tri(0));

        // The chain that used to end in a fabricated verdict.
        const chained = lost.sqrt().sub(Iv.repeat(1, 1));
        try testing.expectEqual(Tri.unknown, chained.decide(.lt).tri(0));
    }

    // And a NaN that arrives from outside is read as "nowhere defined".
    const nan = std.math.nan(f64);
    try testing.expectEqual(Decoration.ill, Iv.splat(nan).decoration(0));
    inline for (.{ "sqrt", "log", "exp", "abs", "sin", "cos", "asin" }) |name| {
        const out = @field(Iv, name)(Iv.splat(nan));
        try testing.expect(!(out.decoration(0) != .ill));
        try testing.expectEqual(Tri.false, out.decide(.gt).tri(0));
    }
}

test "division by an interval that only touches zero keeps the bound it knows" {
    const half_line = Iv.repeat(1, 2).div(Iv.repeat(0, 2));
    try testing.expect(half_line.lo[0] <= 0.5 and half_line.lo[0] > 0.4);
    try testing.expectEqual(std.math.inf(f64), half_line.hi[0]);
    try testing.expect(!half_line.decoration(0).isDefined() and !half_line.decoration(0).isContinuous());
    try testing.expectEqual(Tri.true, half_line.decide(.gt).tri(0));

    const other_side = Iv.repeat(1, 2).div(Iv.repeat(-2, 0));
    try testing.expectEqual(-std.math.inf(f64), other_side.lo[0]);
    try testing.expect(other_side.hi[0] >= -0.5 and other_side.hi[0] < -0.4);

    // Zero strictly inside really does destroy both bounds.
    const gone = Iv.repeat(1, 2).div(Iv.repeat(-1, 1));
    try testing.expectEqual(-std.math.inf(f64), gone.lo[0]);
    try testing.expectEqual(std.math.inf(f64), gone.hi[0]);
}

test "every binary operation encloses the values it takes" {
    const Real = @import("real.zig").Real(1);
    var rng = std.Random.DefaultPrng.init(0x13198A2E03707344);
    const r = rng.random();

    for (0..3000) |_| {
        const alo = (r.float(f64) - 0.5) * 20;
        const ahi = alo + r.float(f64) * 4;
        const blo = (r.float(f64) - 0.5) * 20;
        const bhi = blo + r.float(f64) * 4;
        const a = Iv.repeat(alo, ahi);
        const b = Iv.repeat(blo, bhi);

        inline for (.{ "add", "sub", "mul", "div", "mod", "min", "max" }) |name| {
            const enclosure = @field(Iv, name)(a, b);
            for (0..9) |i| {
                for (0..9) |j| {
                    const s = alo + (ahi - alo) * (@as(f64, @floatFromInt(i)) / 8.0);
                    const t = blo + (bhi - blo) * (@as(f64, @floatFromInt(j)) / 8.0);
                    const v = @field(Real, name)(Real.splat(s), Real.splat(t)).v[0];
                    if (std.math.isNan(v) or std.math.isInf(v)) continue;
                    if (!(enclosure.lo[0] <= v and v <= enclosure.hi[0])) {
                        std.debug.print("{s}([{d},{d}], [{d},{d}]) = [{d},{d}] misses f({d},{d}) = {d}\n", .{
                            name, alo, ahi, blo, bhi, enclosure.lo[0], enclosure.hi[0], s, t, v,
                        });
                        return error.NotAnEnclosure;
                    }
                }
            }
        }
    }
}

test "floor and mod are exact where they can be and honest where they cannot" {
    // `floor` costs nothing in width, and says `dac` only while the box stays
    // between two integers - the jump is what `contour` reads to refuse a cell.
    const inside = Iv.repeat(1.2, 1.8).floor();
    try testing.expectEqual(@as(f64, 1), inside.lo[0]);
    try testing.expectEqual(@as(f64, 1), inside.hi[0]);
    try testing.expectEqual(Decoration.dac, inside.decoration(0));

    const crossing = Iv.repeat(0.5, 1.5).floor();
    try testing.expectEqual(@as(f64, 0), crossing.lo[0]);
    try testing.expectEqual(@as(f64, 1), crossing.hi[0]);
    try testing.expectEqual(Decoration.def, crossing.decoration(0));

    // `ceil` is `-floor(-x)` exactly, decoration included, since `neg` neither
    // rounds nor demotes - so the operator has to agree with the composition.
    for ([_][2]f64{ .{ 1.2, 1.8 }, .{ 0.5, 1.5 }, .{ -2.5, -1.5 }, .{ 2, 3 } }) |b| {
        const direct = Iv.repeat(b[0], b[1]).ceil();
        const composed = Iv.repeat(b[0], b[1]).neg().floor().neg();
        try testing.expectEqual(composed.lo[0], direct.lo[0]);
        try testing.expectEqual(composed.hi[0], direct.hi[0]);
        try testing.expectEqual(composed.decoration(0), direct.decoration(0));
    }

    // The composition alone gives `[-9, 10]` here; the range bound is what
    // makes the answer usable.
    const spanning = Iv.repeat(0, 10).mod(Iv.repeat(3, 3));
    try testing.expect(spanning.lo[0] >= -1e-14 and spanning.hi[0] <= 3 + 1e-14);
    try testing.expectEqual(Decoration.def, spanning.decoration(0));

    // Inside one period the composition is exact and the range bound, which
    // knows nothing about which period, must not spoil it.
    const single = Iv.repeat(4, 5).mod(Iv.repeat(3, 3));
    try testing.expect(single.lo[0] <= 1 and single.hi[0] >= 2 and single.hi[0] < 2.5);
    try testing.expectEqual(Decoration.dac, single.decoration(0));

    // Floored, so the result takes the sign of the divisor: 7 mod -3 is -2.
    const negative = Iv.repeat(7, 7).mod(Iv.repeat(-3, -3));
    try testing.expect(negative.lo[0] <= -2 and negative.hi[0] >= -2 and negative.lo[0] > -3.1);

    // `min` and `max` round nothing away and stay continuous.
    const smaller = Iv.repeat(-1, 2).min(Iv.repeat(0, 3));
    try testing.expectEqual(@as(f64, -1), smaller.lo[0]);
    try testing.expectEqual(@as(f64, 2), smaller.hi[0]);
    try testing.expectEqual(Decoration.dac, smaller.decoration(0));

    const larger = Iv.repeat(-1, 2).max(Iv.repeat(0, 3));
    try testing.expectEqual(@as(f64, 0), larger.lo[0]);
    try testing.expectEqual(@as(f64, 3), larger.hi[0]);
}

test "a modulo whose subtraction cancels still encloses what the sampler computes" {
    // `a - m floor(a/m)` loses `ulp(a)` to cancellation, which is enormous
    // next to the result when the divisor is tiny. Clipping to the exact
    // `[0, m]` would put the sampled value outside the enclosure, and the
    // plotter reads both.
    const Real = @import("real.zig").Real(1);
    for ([_][2]f64{ .{ 5, 1e-15 }, .{ 5, 1e-12 }, .{ -7.5, 1e-14 }, .{ 1e6, 1e-9 } }) |case| {
        const a = case[0];
        const m = case[1];
        const enclosure = Iv.repeat(a, a).mod(Iv.repeat(m, m));
        const sampled = Real.splat(a).mod(Real.splat(m)).v[0];
        if (std.math.isNan(sampled)) continue;
        if (!(enclosure.lo[0] <= sampled and sampled <= enclosure.hi[0])) {
            std.debug.print("mod({d}, {d}) = [{d}, {d}] misses the sampled {d}\n", .{
                a, m, enclosure.lo[0], enclosure.hi[0], sampled,
            });
            return error.NotAnEnclosure;
        }
    }
}

test "the outward slack is never less than a rounding step" {
    // `std.math.nextAfter` is the exact answer to "the next representable
    // value". It is scalar and branchy, so it is not what the hot path wants -
    // there, one fused multiply-add per bound vectorises and this does not -
    // but it is exactly the right oracle for checking that the cheap
    // epsilon-inflation never widens by less than a rounding could move a
    // result.
    var rng = std.Random.DefaultPrng.init(0x452821E638D01377);
    const r = rng.random();
    const edges = [_]f64{ 0, 1, -1, 0.5, 2, 1024, std.math.floatMin(f64), std.math.floatTrueMin(f64) };

    for (0..2000) |i| {
        const v = if (i < edges.len) edges[i] else (r.float(f64) - 0.5) * std.math.pow(f64, 10, @floatFromInt(i % 60));
        // `add` of an exact zero rounds nowhere, so the result's width is the
        // slack alone.
        const widened = Iv.repeat(v, v).add(Iv.repeat(0, 0));
        try testing.expect(widened.lo[0] <= std.math.nextAfter(f64, v, -std.math.inf(f64)));
        try testing.expect(widened.hi[0] >= std.math.nextAfter(f64, v, std.math.inf(f64)));
    }
}

test "cos of a huge argument degrades to the full range instead of lying" {
    const c = Iv.repeat(1e17, 1e17 + 1).cos();
    try testing.expectApproxEqAbs(@as(f64, -1), c.lo[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), c.hi[0], 1e-12);
}

test "division by a straddling interval loses continuity" {
    const q = Iv.repeat(1, 2).div(Iv.repeat(-1, 1));
    try testing.expect(!q.decoration(0).isContinuous());
    try testing.expect(!q.decoration(0).isDefined());
    try testing.expect((q.decoration(0) != .ill));

    const ok = Iv.repeat(1, 2).div(Iv.repeat(2, 4));
    try testing.expect(ok.decoration(0).isContinuous() and ok.decoration(0).isDefined());
    try testing.expect(ok.lo[0] <= 0.25 and ok.hi[0] >= 1.0);

    const by_zero = Iv.repeat(1, 2).div(Iv.repeat(0, 0));
    try testing.expect(!(by_zero.decoration(0) != .ill));
}

test "overflow to infinity does not poison the interval" {
    // exp(1000) overflows; widening an infinite bound must not compute inf-inf.
    const e = Iv.repeat(1000, 1001).exp();
    try testing.expect(!std.math.isNan(e.lo[0]) and !std.math.isNan(e.hi[0]));
    try testing.expectEqual(Tri.true, e.decide(.gt).tri(0));

    const unbounded = Iv.repeat(-std.math.inf(f64), std.math.inf(f64));
    const w = unbounded.add(unbounded).mul(Iv.repeat(2, 3));
    try testing.expect(!std.math.isNan(w.lo[0]) and !std.math.isNan(w.hi[0]));
    try testing.expectEqual(Tri.unknown, w.decide(.eq).tri(0));
}

test "partial and empty domains" {
    const s = Iv.repeat(-1, 4).sqrt();
    try testing.expect((s.decoration(0) != .ill) and !s.decoration(0).isDefined());
    try testing.expect(s.hi[0] >= 2);

    const gone = Iv.repeat(-4, -1).sqrt();
    try testing.expect(!(gone.decoration(0) != .ill));

    const l = Iv.repeat(-1, 1).log();
    try testing.expect((l.decoration(0) != .ill) and !l.decoration(0).isDefined());
    try testing.expectEqual(Decoration.ill, Iv.repeat(-2, 0).log().decoration(0));
}

test "decide is exact on the boundary" {
    // The case that made the original subdivide forever: lo lands exactly on 0.
    try testing.expectEqual(Tri.false, Iv.repeat(0, 1).decide(.lt).tri(0));
    try testing.expectEqual(Tri.true, Iv.repeat(0, 1).decide(.ge).tri(0));
    try testing.expectEqual(Tri.unknown, Iv.repeat(0, 1).decide(.le).tri(0));
    try testing.expectEqual(Tri.true, Iv.repeat(-2, -1).decide(.lt).tri(0));
    try testing.expectEqual(Tri.false, Iv.repeat(1, 2).decide(.eq).tri(0));
    try testing.expectEqual(Tri.true, Iv.repeat(0, 0).decide(.eq).tri(0));
    try testing.expectEqual(Tri.unknown, Iv.repeat(-1, 1).decide(.eq).tri(0));
    try testing.expectEqual(Tri.false, Iv.repeat(-4, -1).sqrt().decide(.eq).tri(0));
}

test "lanes are independent" {
    const V = Interval(4);
    const a = V{
        .lo = .{ -2, 0, 1, -1 },
        .hi = .{ -1, 1, 2, 1 },
        .dec = @splat(@intFromEnum(Decoration.dac)),
    };
    const v = a.decide(.lt);
    try testing.expectEqual(Tri.true, v.tri(0));
    try testing.expectEqual(Tri.false, v.tri(1));
    try testing.expectEqual(Tri.false, v.tri(2));
    try testing.expectEqual(Tri.unknown, v.tri(3));

    const s = a.sin();
    inline for (0..4) |i| {
        const one = Iv.repeat(a.lo[i], a.hi[i]).sin();
        try testing.expectEqual(one.lo[0], s.lo[i]);
        try testing.expectEqual(one.hi[0], s.hi[i]);
    }
}
