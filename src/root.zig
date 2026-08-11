//! Draw any implicit relation `f(x, y) op g(x, y)` using interval arithmetic.
//!
//! The pipeline is:
//!
//! ```text
//!   text  --parse-->  Program (flat DAG)  --eval-->  Interval / Real
//!                              |                          |
//!                              +--------- Relation --------+
//!                                             |
//!                                          plot.render  -->  Raster  --> PNG / ASCII
//! ```
//!
//! `Program` is a flat array of nodes in topological order; `eval.Evaluator` is
//! a single forward loop over it, instantiated once per arithmetic domain -
//! `interval.Interval(n)` to bound `f` over a box, `real.Real(n)` to sample it
//! at points. Both are SIMD batches, so the plotter decides a whole quadtree
//! split, or all four corners of a box, in one pass.
//!
//! Everything below `plot.render` is allocation-free: the only heap traffic in
//! a plot is the raster and one scratch buffer per worker.

const std = @import("std");

pub const interval = @import("interval.zig");
pub const real = @import("real.zig");
pub const expr = @import("expr.zig");
pub const eval = @import("eval.zig");
pub const parse = @import("parse.zig");
pub const relation = @import("relation.zig");
pub const raster = @import("raster.zig");
pub const png = @import("png.zig");
pub const plot = @import("plot.zig");
pub const dual = @import("dual.zig");
pub const contour = @import("contour.zig");

pub const Interval = interval.Interval;
pub const Op = interval.Op;
pub const Tri = interval.Tri;
pub const Builder = expr.Builder;
pub const Program = expr.Program;
pub const Relation = relation.Relation;
pub const Raster = raster.Raster;
pub const View = plot.View;
pub const render = plot.render;

test {
    std.testing.refAllDecls(@This());
}

test "end to end: a parsed relation renders" {
    const gpa = std.testing.allocator;
    var rel = try parse.relationFrom(gpa, "x^2 + y^2 <= 1", null);
    defer rel.deinit(gpa);

    var image = try render(gpa, std.testing.io, &rel, .{
        .view = .{ .width = 65, .height = 65, .x_min = -2, .x_max = 2, .y_min = -2, .y_max = 2 },
    });
    defer image.deinit(gpa);

    // The unit disc has area pi within a 4x4 view.
    const expected = std.math.pi / 16.0 * @as(f64, 65 * 65);
    const actual: f64 = @floatFromInt(image.count());
    try std.testing.expect(@abs(actual - expected) / expected < 0.1);
    try std.testing.expect(image.isSet(32, 32));
    try std.testing.expect(!image.isSet(0, 0));
}
