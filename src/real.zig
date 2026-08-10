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

        pub fn powi(a: Self, n: i32) Self {
            if (n < 0) return splat(1).div(a.powi(-n));
            var acc: F = @splat(1);
            var base = a.v;
            var e: u32 = @intCast(n);
            while (e != 0) : (e >>= 1) {
                if (e & 1 != 0) acc *= base;
                base *= base;
            }
            return .{ .v = acc };
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
