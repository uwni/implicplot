//! Forward-mode automatic differentiation, as an arithmetic domain.
//!
//! `Dual(Base)` carries a value and its two partial derivatives, each of them a
//! `Base`. Because it implements the same operations under the same names as
//! `Interval(n)` and `Real(n)`, `eval.Evaluator` runs an unmodified program
//! over it and returns `f` together with `grad f` - the generic evaluator needs
//! no change at all, which is what that genericity was for.
//!
//! Over `Interval(n)` this yields an *enclosure* of the gradient over a whole
//! box, which is the thing subdivision algorithms need and sampling cannot
//! provide: `Plantinga & Vegter (SGP 2004)` subdivides until
//! `<grad F(C), grad F(C)> > 0`, which says the gradient turns by less than a
//! right angle across the cell, hence the curve is a single monotone arc there.
//!
//! Differentiation is exact, not a finite difference: each rule below is the
//! textbook derivative, and over intervals the result encloses the true
//! derivative wherever the base operations do.

const std = @import("std");

pub fn Dual(comptime Base: type) type {
    return struct {
        const Self = @This();

        /// f
        v: Base,
        /// df/dx
        dx: Base,
        /// df/dy
        dy: Base,

        const zero = Base.splat(0);
        const one = Base.splat(1);
        const two = Base.splat(2);

        /// A constant: value varies with nothing.
        pub fn splat(value: f64) Self {
            return .{ .v = Base.splat(value), .dx = zero, .dy = zero };
        }

        /// The seed for the x variable: dx/dx = 1, dx/dy = 0.
        pub fn varX(value: Base) Self {
            return .{ .v = value, .dx = one, .dy = zero };
        }

        /// The seed for the y variable.
        pub fn varY(value: Base) Self {
            return .{ .v = value, .dx = zero, .dy = one };
        }

        /// Chain rule: `d(g(a)) = g'(a) * da`, given `g(a)` and `g'(a)`.
        inline fn chain(a: Self, value: Base, slope: Base) Self {
            return .{ .v = value, .dx = slope.mul(a.dx), .dy = slope.mul(a.dy) };
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .v = a.v.add(b.v), .dx = a.dx.add(b.dx), .dy = a.dy.add(b.dy) };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{ .v = a.v.sub(b.v), .dx = a.dx.sub(b.dx), .dy = a.dy.sub(b.dy) };
        }

        pub fn neg(a: Self) Self {
            return .{ .v = a.v.neg(), .dx = a.dx.neg(), .dy = a.dy.neg() };
        }

        pub fn mul(a: Self, b: Self) Self {
            return .{
                .v = a.v.mul(b.v),
                .dx = a.dx.mul(b.v).add(a.v.mul(b.dx)),
                .dy = a.dy.mul(b.v).add(a.v.mul(b.dy)),
            };
        }

        pub fn div(a: Self, b: Self) Self {
            const quotient = a.v.div(b.v);
            // (a/b)' = (a' - (a/b) b') / b, which needs one division rather than
            // the two of the quotient rule written out.
            return .{
                .v = quotient,
                .dx = a.dx.sub(quotient.mul(b.dx)).div(b.v),
                .dy = a.dy.sub(quotient.mul(b.dy)).div(b.v),
            };
        }

        /// `|a|' = sign(a) a'`. At zero the slope is not defined, and `sign`
        /// widens to `[-1, 1]` there, so the enclosure stays honest.
        pub fn abs(a: Self) Self {
            return chain(a, a.v.abs(), a.v.sign());
        }

        /// `max(a, b)` is `(a + b + |a - b|)/2`, so its derivative is
        /// `(a' + b' + sign(a-b)(a' - b'))/2`: the larger side's slope, and
        /// where the box straddles `a = b` the same widening `abs` gets at its
        /// own kink, which is the hull of the two. The *value* comes from the
        /// domain's own `max` rather than from that formula, which over
        /// intervals would be looser for nothing.
        pub fn max(a: Self, b: Self) Self {
            const s = a.v.sub(b.v).sign();
            return .{
                .v = a.v.max(b.v),
                .dx = a.dx.add(b.dx).add(s.mul(a.dx.sub(b.dx))).div(two),
                .dy = a.dy.add(b.dy).add(s.mul(a.dy.sub(b.dy))).div(two),
            };
        }

        pub fn min(a: Self, b: Self) Self {
            const s = a.v.sub(b.v).sign();
            return .{
                .v = a.v.min(b.v),
                .dx = a.dx.add(b.dx).sub(s.mul(a.dx.sub(b.dx))).div(two),
                .dy = a.dy.add(b.dy).sub(s.mul(a.dy.sub(b.dy))).div(two),
            };
        }

        /// Zero, not `chain`: a step is constant between consecutive integers,
        /// so wherever it has a derivative at all that derivative is exactly
        /// zero, whatever the argument's is. Where it has none - a box whose
        /// image crosses an integer - the value comes back `def` rather than
        /// `dac`, and `contour` drops the cell on that alone, before anything
        /// reads this.
        pub fn floor(a: Self) Self {
            return .{ .v = a.v.floor(), .dx = zero, .dy = zero };
        }

        pub fn ceil(a: Self) Self {
            return .{ .v = a.v.ceil(), .dx = zero, .dy = zero };
        }

        /// `(a - m k)'` with `k = floor(a/m)` held constant, which it is
        /// wherever `mod` is differentiable. Across a step it is not, and the
        /// value's decoration says so; see `floor`.
        pub fn mod(a: Self, m: Self) Self {
            const k = a.v.div(m.v).floor();
            return .{
                .v = a.v.mod(m.v),
                .dx = a.dx.sub(m.dx.mul(k)),
                .dy = a.dy.sub(m.dy.mul(k)),
            };
        }

        pub fn sin(a: Self) Self {
            return chain(a, a.v.sin(), a.v.cos());
        }

        pub fn cos(a: Self) Self {
            return chain(a, a.v.cos(), a.v.sin().neg());
        }

        pub fn tan(a: Self) Self {
            const t = a.v.tan();
            return chain(a, t, one.add(t.mul(t)));
        }

        pub fn exp(a: Self) Self {
            const e = a.v.exp();
            return chain(a, e, e);
        }

        pub fn sqrt(a: Self) Self {
            const r = a.v.sqrt();
            return chain(a, r, one.div(two.mul(r)));
        }

        pub fn log(a: Self) Self {
            return chain(a, a.v.log(), one.div(a.v));
        }

        pub fn asin(a: Self) Self {
            return chain(a, a.v.asin(), one.div(one.sub(a.v.mul(a.v)).sqrt()));
        }

        pub fn acos(a: Self) Self {
            return chain(a, a.v.acos(), one.div(one.sub(a.v.mul(a.v)).sqrt()).neg());
        }

        pub fn atan(a: Self) Self {
            return chain(a, a.v.atan(), one.div(one.add(a.v.mul(a.v))));
        }

        pub fn powi(a: Self, n: i32) Self {
            if (n == 0) return splat(1);
            const exponent = Base.splat(@floatFromInt(n));
            return chain(a, a.v.powi(n), exponent.mul(a.v.powi(n - 1)));
        }
    };
}

const testing = std.testing;

const Interval = @import("interval.zig").Interval;
const Real = @import("real.zig").Real;
const expr = @import("expr.zig");
const eval = @import("eval.zig");

/// Build `source`'s left-hand side and evaluate it in whatever domain.
fn evaluate(comptime Domain: type, gpa: std.mem.Allocator, source: []const u8, x: Domain, y: Domain) !Domain {
    const parse = @import("parse.zig");
    var diagnostic: parse.Diagnostic = .{};
    var rel = try parse.relationFrom(gpa, source, &diagnostic);
    defer rel.deinit(gpa);
    var evaluator: eval.Evaluator(Domain) = try .init(gpa, &rel.program);
    defer evaluator.deinit(gpa);
    return evaluator.eval(rel.root, x, y);
}

test "the generic evaluator differentiates an unmodified program" {
    const D = Dual(Real(1));
    const at = struct {
        fn point(v: f64) Real(1) {
            return Real(1).splat(v);
        }
    }.point;

    // d/dx [sin(x^2 + y^2) - cos(x*y)] = 2x cos(x^2+y^2) + y sin(x y)
    // d/dy [                         ] = 2y cos(x^2+y^2) + x sin(x y)
    for ([_][2]f64{ .{ 0.3, -1.2 }, .{ 1.7, 0.4 }, .{ -0.8, -0.8 } }) |p| {
        const x = p[0];
        const y = p[1];
        const got = try evaluate(D, testing.allocator, "sin(x^2 + y^2) = cos(x*y)", D.varX(at(x)), D.varY(at(y)));

        try testing.expectApproxEqAbs(@sin(x * x + y * y) - @cos(x * y), got.v.v[0], 1e-12);
        try testing.expectApproxEqAbs(2 * x * @cos(x * x + y * y) + y * @sin(x * y), got.dx.v[0], 1e-12);
        try testing.expectApproxEqAbs(2 * y * @cos(x * x + y * y) + x * @sin(x * y), got.dy.v[0], 1e-12);
    }
}

test "every operator's derivative matches a central difference" {
    const D = Dual(Real(1));
    const R = Real(1);
    const sources = [_][]const u8{
        "x + y = 0",       "x - y = 0",        "x * y = 0",       "x / y = 0",
        "-x * y = 0",      "abs(x) * y = 0",   "sin(x) * y = 0",  "cos(x) * y = 0",
        "tan(x) * y = 0",  "exp(x) * y = 0",   "sqrt(x) * y = 0", "log(x) * y = 0",
        "asin(x/4) = y",   "acos(x/4) = y",    "atan(x) * y = 0", "x^3 * y = 0",
        "x^-2 * y = 0",  "sqrt(x^2 + y^2) = 1",
        // The four with kinks or steps, sampled away from them: `floor` is
        // locally constant, `mod` is `a - m k` with `k` frozen, and `min`/`max`
        // are whichever side is winning.
        "floor(x) * y = 0", "ceil(x) * y = 0",   "mod(x, 3) * y = 0", "mod(x, y) = 0",
        "min(x, y) = 0",    "max(x, y) = 0",     "max(x*y, x + y) = 1",
    };

    const h = 1e-6;
    inline for (sources) |source| {
        for ([_][2]f64{ .{ 1.3, 0.7 }, .{ 2.1, -1.4 }, .{ 0.6, 2.2 } }) |p| {
            const x = p[0];
            const y = p[1];
            const d = try evaluate(D, testing.allocator, source, D.varX(R.splat(x)), D.varY(R.splat(y)));

            const fx1 = (try evaluate(R, testing.allocator, source, R.splat(x + h), R.splat(y))).v[0];
            const fx0 = (try evaluate(R, testing.allocator, source, R.splat(x - h), R.splat(y))).v[0];
            const fy1 = (try evaluate(R, testing.allocator, source, R.splat(x), R.splat(y + h))).v[0];
            const fy0 = (try evaluate(R, testing.allocator, source, R.splat(x), R.splat(y - h))).v[0];

            try testing.expectApproxEqAbs((fx1 - fx0) / (2 * h), d.dx.v[0], 1e-4);
            try testing.expectApproxEqAbs((fy1 - fy0) / (2 * h), d.dy.v[0], 1e-4);
        }
    }
}

test "over intervals the derivative is an enclosure, not an estimate" {
    const DI = Dual(Interval(1));
    const DR = Dual(Real(1));
    const Iv = Interval(1);
    const R = Real(1);

    var rng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15);
    const r = rng.random();

    const sources = [_][]const u8{
        "sin(x^2 + y^2) = cos(x*y)",
        "x^3 - 3*x*y^2 = 1",
        "exp(x) * sin(y) = x",
        "sqrt(x^2 + y^2) = 2",
        // Continuous but kinked: on a box straddling `a = b` the enclosure has
        // to be the hull of both branches, not whichever one the midpoint is on.
        "min(x, y) = 1",
        "max(x*y, x + y) = 1",
    };

    inline for (sources) |source| {
        for (0..200) |_| {
            const x0 = (r.float(f64) - 0.5) * 4;
            const y0 = (r.float(f64) - 0.5) * 4;
            const w = r.float(f64) * 0.5;
            const box = try evaluate(DI, testing.allocator, source, DI.varX(Iv.repeat(x0, x0 + w)), DI.varY(Iv.repeat(y0, y0 + w)));

            // Every point of the box must have its gradient inside the enclosure.
            for (0..5) |k| {
                const t = @as(f64, @floatFromInt(k)) / 4.0;
                const px = x0 + w * t;
                const py = y0 + w * (1 - t);
                const point = try evaluate(DR, testing.allocator, source, DR.varX(R.splat(px)), DR.varY(R.splat(py)));
                if (!std.math.isFinite(point.dx.v[0]) or !std.math.isFinite(point.dy.v[0])) continue;

                try testing.expect(box.dx.lo[0] <= point.dx.v[0] and point.dx.v[0] <= box.dx.hi[0]);
                try testing.expect(box.dy.lo[0] <= point.dy.v[0] and point.dy.v[0] <= box.dy.hi[0]);
            }
        }
    }
}
