//! The other interpretation of the expression language: ordinary floating point
//! numbers, `lanes` of them at a time.
//!
//! `eval.zig` runs the same program over `Interval(n)` to bound `f` on a box and
//! over `Real(n)` to sample `f` at points; keeping the two domains
//! interface-compatible is what lets there be a single evaluator.
//!
//! The plotter samples the four corners of a box at once, so `Real(4)` does that
//! in one vector walk.

const std = @import("std");

pub fn Real(comptime lanes: comptime_int) type {
    return struct {
        const Self = @This();

        pub const F = @Vector(lanes, f64);
        pub const width = lanes;

        v: F,

        pub fn splat(x: f64) Self {
            return .{ .v = @splat(x) };
        }

        pub fn init(v: F) Self {
            return .{ .v = v };
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .v = a.v + b.v };
        }
        pub fn sub(a: Self, b: Self) Self {
            return .{ .v = a.v - b.v };
        }
        pub fn mul(a: Self, b: Self) Self {
            return .{ .v = a.v * b.v };
        }
        pub fn div(a: Self, b: Self) Self {
            return .{ .v = a.v / b.v };
        }
        pub fn neg(a: Self) Self {
            return .{ .v = -a.v };
        }
        /// -1, 0 or 1, matching `Interval.sign` at a point.
        pub fn sign(a: Self) Self {
            const zero: F = @splat(0);
            const positive = @select(f64, a.v > zero, @as(F, @splat(1)), zero);
            return .{ .v = @select(f64, a.v < zero, @as(F, @splat(-1)), positive) };
        }

        pub fn abs(a: Self) Self {
            return .{ .v = @abs(a.v) };
        }

        pub fn min(a: Self, b: Self) Self {
            return .{ .v = @min(a.v, b.v) };
        }
        pub fn max(a: Self, b: Self) Self {
            return .{ .v = @max(a.v, b.v) };
        }
        pub fn floor(a: Self) Self {
            return .{ .v = @floor(a.v) };
        }
        pub fn ceil(a: Self) Self {
            return .{ .v = @ceil(a.v) };
        }

        /// Floored modulo, spelled out rather than taken from the standard
        /// library, for three reasons that were checked rather than assumed:
        ///
        ///   * `@mod` computes something else for a negative divisor -
        ///     `@mod(7, -3)` is 1 where this is -2. `interval.mod` bounds
        ///     *this* function, and a domain computing the other one would
        ///     leave the sampler and the enclosure describing different
        ///     curves.
        ///   * `std.math.mod` is scalar, returns an error union, and rejects a
        ///     negative denominator outright - none of which survives contact
        ///     with a branch-free vector evaluator - and it is a wrapper over
        ///     `@mod` anyway.
        ///   * it is faster. `@mod` and `@rem` on a float vector fall back to
        ///     one `fmod` libcall per lane; this is four vector instructions.
        ///     Measured at `@Vector(4, f64)`: 1.6 ns a call against 35.4 for
        ///     `@mod` and 25.3 for `@rem` with a sign fixup.
        pub fn mod(a: Self, m: Self) Self {
            return a.sub(m.mul(a.div(m).floor()));
        }

        /// The exponent is only ever needed as a magnitude, and `@abs` of a
        /// signed integer is unsigned, so the most negative i32 is
        /// representable here - where negating `n` to recurse on it would
        /// overflow. `dual.powi` does reach that value: the derivative of
        /// `x^n` needs `x^(n-1)`, and `n` can be `minInt + 1`.
        pub fn powi(a: Self, n: i32) Self {
            var acc: F = @splat(1);
            var base = a.v;
            var e: u32 = @abs(n);
            while (e != 0) : (e >>= 1) {
                if (e & 1 != 0) acc *= base;
                base *= base;
            }
            const magnitude: Self = .{ .v = acc };
            return if (n < 0) splat(1).div(magnitude) else magnitude;
        }

        pub fn sin(a: Self) Self {
            return .{ .v = @sin(a.v) };
        }
        pub fn cos(a: Self) Self {
            return .{ .v = @cos(a.v) };
        }
        pub fn tan(a: Self) Self {
            return .{ .v = @sin(a.v) / @cos(a.v) };
        }
        pub fn exp(a: Self) Self {
            return .{ .v = @exp(a.v) };
        }
        pub fn sqrt(a: Self) Self {
            return .{ .v = @sqrt(a.v) };
        }
        pub fn log(a: Self) Self {
            return .{ .v = @log(a.v) };
        }

        pub fn asin(a: Self) Self {
            var out = a;
            inline for (0..lanes) |i| out.v[i] = std.math.asin(a.v[i]);
            return out;
        }
        pub fn acos(a: Self) Self {
            var out = a;
            inline for (0..lanes) |i| out.v[i] = std.math.acos(a.v[i]);
            return out;
        }
        pub fn atan(a: Self) Self {
            var out = a;
            inline for (0..lanes) |i| out.v[i] = std.math.atan(a.v[i]);
            return out;
        }
    };
}

test "mod is floored, so it takes the sign of its divisor" {
    const R = Real(4);
    // The same four cases Python's `%` gives 1, 2, -2, -1 for. `@mod` would
    // give 1, 2, 1, -1, which is a different function.
    const got: [4]f64 = R.init(.{ 7, -7, 7, -7 }).mod(R.init(.{ 3, 3, -3, -3 })).v;
    try std.testing.expectEqual([4]f64{ 1, 2, -2, -1 }, got);

    const stepped: [4]f64 = R.init(.{ -1.5, 1.5, 2.0, -2.0 }).floor().v;
    try std.testing.expectEqual([4]f64{ -2, 1, 2, -2 }, stepped);
}

test "real domain matches scalar math" {
    const R = Real(4);
    const x = R.init(.{ 0.5, -0.5, 2.0, -2.0 });
    const y: [4]f64 = x.powi(3).add(x.sin()).div(R.splat(2)).v;
    const xs: [4]f64 = x.v;
    for (xs, y) |t, got| {
        try std.testing.expectApproxEqRel((t * t * t + @sin(t)) / 2, got, 1e-12);
    }
    try std.testing.expectEqual(@as(f64, 0.25), R.splat(2).powi(-2).v[0]);
}
