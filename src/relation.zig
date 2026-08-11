//! An implicit relation, and the two questions the plotter asks about a box.
//!
//! Every relation is stored in the normal form `f(x, y) op 0`, where `f` is
//! `lhs - rhs`. For a single interval that is not an approximation:
//! `[a,b] - [c,d]` contains 0 exactly when `[a,b]` and `[c,d]` overlap, so
//! comparing the difference against zero decides `lhs op rhs` with the same
//! precision as comparing the two sides.
//!
//! Normalising buys three things the original did not have:
//!
//!   * one expression root instead of `lhs`, `rhs` and an *optional* `diff`
//!     that only `.Equal` was supposed to carry - the original's
//!     `Relation.init` could build an `.Equal` with `diff_expr == null`, which
//!     silently made `confirmHasSolution` return false and rendered nothing;
//!   * the verdict, the definedness test and the continuity test all come out
//!     of *one* evaluation, where the original ran a full tree walk for each;
//!   * the continuity test applies to every operator, not just equality.

const std = @import("std");
const expr = @import("expr.zig");
const eval = @import("eval.zig");
const interval = @import("interval.zig");
const real = @import("real.zig");

pub const Op = interval.Op;
const Tri = interval.Tri;
const Decoration = interval.Decoration;

const Iv4 = interval.Interval(4);
const R4 = real.Real(4);

pub const Relation = struct {
    program: expr.Program,
    /// Root of `lhs - rhs`.
    root: expr.Index,
    op: Op,

    pub fn deinit(self: *Relation, gpa: std.mem.Allocator) void {
        self.program.deinit(gpa);
        self.* = undefined;
    }
};

/// A box of the plane, as the four numbers that bound it. An `Interval` would
/// do, but only by using an arithmetic type as a coordinate pair.
pub const Rect = struct {
    x0: f64,
    x1: f64,
    y0: f64,
    y1: f64,

    pub fn quarters(self: Rect) [4]Rect {
        const xm = 0.5 * (self.x0 + self.x1);
        const ym = 0.5 * (self.y0 + self.y1);
        return .{
            .{ .x0 = self.x0, .x1 = xm, .y0 = self.y0, .y1 = ym },
            .{ .x0 = xm, .x1 = self.x1, .y0 = self.y0, .y1 = ym },
            .{ .x0 = self.x0, .x1 = xm, .y0 = ym, .y1 = self.y1 },
            .{ .x0 = xm, .x1 = self.x1, .y0 = ym, .y1 = self.y1 },
        };
    }
};

/// What one box evaluation tells us.
pub const Reading = struct {
    tri: Tri,
    dec: Decoration,
};

/// The values of `f` at the four corners of a box, one per lane, in the order
/// (x0,y0) (x0,y1) (x1,y0) (x1,y1). The plotter's refinement threads these
/// down its recursion: a quartered box shares five of its children's corners
/// with the parent, so the children never re-evaluate them.
pub const Corners = R4.F;

/// Per-worker scratch for asking questions about boxes. All allocation happens
/// here, once, never in the recursion.
pub const Prober = struct {
    rel: *const Relation,
    boxes: eval.Evaluator(Iv4),
    corners: eval.Evaluator(R4),

    pub fn init(gpa: std.mem.Allocator, rel: *const Relation) !Prober {
        std.debug.assert(rel.root < rel.program.nodes.len);
        var boxes: eval.Evaluator(Iv4) = try .init(gpa, &rel.program);
        errdefer boxes.deinit(gpa);
        const corners: eval.Evaluator(R4) = try .init(gpa, &rel.program);
        return .{ .rel = rel, .boxes = boxes, .corners = corners };
    }

    pub fn deinit(self: *Prober, gpa: std.mem.Allocator) void {
        self.boxes.deinit(gpa);
        self.corners.deinit(gpa);
        self.* = undefined;
    }

    /// Decide four boxes in one vector pass. Lanes are independent, so a caller
    /// with fewer than four boxes may repeat one - `probe(.{r} ** 4)[0]`.
    pub fn probe(self: *Prober, rects: [4]Rect) [4]Reading {
        var x_lo: [4]f64 = undefined;
        var x_hi: [4]f64 = undefined;
        var y_lo: [4]f64 = undefined;
        var y_hi: [4]f64 = undefined;
        for (rects, 0..) |r, i| {
            x_lo[i] = r.x0;
            x_hi[i] = r.x1;
            y_lo[i] = r.y0;
            y_hi[i] = r.y1;
        }

        const v = self.boxes.eval(self.rel.root, Iv4.init(x_lo, x_hi), Iv4.init(y_lo, y_hi));
        const verdict = v.decide(self.rel.op);
        var out: [4]Reading = undefined;
        inline for (0..4) |i| out[i] = .{ .tri = verdict.tri(i), .dec = v.decoration(i) };
        return out;
    }

    /// Evaluate `f` at four arbitrary points, one per lane.
    pub fn evalPoints(self: *Prober, xs: R4.F, ys: R4.F) R4.F {
        return self.corners.eval(self.rel.root, .init(xs), .init(ys)).v;
    }

    /// The corner samples of a box, in the lane order `Corners` documents.
    pub fn cornerValues(self: *Prober, rect: Rect) Corners {
        return self.evalPoints(
            .{ rect.x0, rect.x0, rect.x1, rect.x1 },
            .{ rect.y0, rect.y1, rect.y0, rect.y1 },
        );
    }

    /// Do these corner samples *prove* that the box contains a solution?
    ///
    /// For an inequality one satisfying sample is a proof. For an equality we
    /// need the intermediate value theorem, which requires `f` to be defined
    /// and pole-free on the box - hence the `Reading` argument.
    ///
    /// The corners stay in the vector they were computed in: every question
    /// below is "does any lane ...", which is one comparison and one
    /// reduction rather than four scalar tests and four branches. No question
    /// cares which lane is which corner.
    pub fn provenBy(self: *const Prober, r: Reading, v: Corners) bool {
        const zero: R4.F = @splat(0);

        // For an inequality one satisfying corner is the whole proof.
        if (self.rel.op != .eq) return self.rel.op.holdsAny(v);

        // A sample that *is* zero proves a solution by itself - it is a point
        // of the box where the relation holds, and reading that off involves no
        // intermediate value theorem and so needs no continuity. This is the
        // only thing that finds a solution of a step relation like
        // `mod(x, 2) = 0`, whose zero set is a set of isolated lines that the
        // sign-change argument below can never certify.
        if (@reduce(.Or, v == zero)) return true;

        // Everything else rests on the intermediate value theorem, which wants
        // `f` defined and pole-free across the whole box, and a sign change
        // between two corners that are really there.
        if (!r.dec.isContinuous()) return false;
        if (@reduce(.Or, v != v)) return false;
        return @reduce(.Or, v > zero) and @reduce(.Or, v < zero);
    }
};

const testing = std.testing;

fn buildRelation(gpa: std.mem.Allocator, op: Op, comptime f: fn (*expr.Builder) anyerror!expr.Index) !Relation {
    var b = expr.Builder.init(gpa);
    defer b.deinit();
    const root = try f(&b);
    return .{ .program = try b.build(), .root = root, .op = op };
}

fn one(p: *Prober, rect: Rect) Reading {
    return p.probe(.{rect} ** 4)[0];
}

test "inequality verdicts over boxes" {
    // x - y < 0
    var rel = try buildRelation(testing.allocator, .lt, struct {
        fn f(b: *expr.Builder) !expr.Index {
            return b.sub(try b.x(), try b.y());
        }
    }.f);
    defer rel.deinit(testing.allocator);

    var p = try Prober.init(testing.allocator, &rel);
    defer p.deinit(testing.allocator);

    try testing.expectEqual(Tri.true, one(&p, .{ .x0 = 0, .x1 = 1, .y0 = 2, .y1 = 3 }).tri);
    try testing.expectEqual(Tri.false, one(&p, .{ .x0 = 2, .x1 = 3, .y0 = 0, .y1 = 1 }).tri);
    try testing.expectEqual(Tri.unknown, one(&p, .{ .x0 = 0, .x1 = 2, .y0 = 1, .y1 = 3 }).tri);
}

test "lanes of a probe are independent" {
    // sin(x^2 + y^2) - cos(x*y) = 0
    var rel = try buildRelation(testing.allocator, .eq, struct {
        fn f(b: *expr.Builder) !expr.Index {
            const xi = try b.x();
            const yi = try b.y();
            return b.sub(
                try b.unary(.sin, try b.add(try b.powi(xi, 2), try b.powi(yi, 2))),
                try b.unary(.cos, try b.mul(xi, yi)),
            );
        }
    }.f);
    defer rel.deinit(testing.allocator);

    var p = try Prober.init(testing.allocator, &rel);
    defer p.deinit(testing.allocator);

    const rects = [4]Rect{
        .{ .x0 = -2, .x1 = 0, .y0 = -1, .y1 = 1 },
        .{ .x0 = 0, .x1 = 2, .y0 = -1, .y1 = 1 },
        .{ .x0 = -2, .x1 = 0, .y0 = 1, .y1 = 3 },
        .{ .x0 = 0, .x1 = 2, .y0 = 1, .y1 = 3 },
    };
    const together = p.probe(rects);
    for (rects, together) |rect, got| {
        try testing.expectEqual(one(&p, rect), got);
    }
}

test "a pole is not mistaken for a root" {
    // tan(x) - y = 0 near x = pi/2: f jumps from +inf to -inf, so the corner
    // sign change must NOT be accepted as a solution.
    var rel = try buildRelation(testing.allocator, .eq, struct {
        fn f(b: *expr.Builder) !expr.Index {
            return b.sub(try b.unary(.tan, try b.x()), try b.y());
        }
    }.f);
    defer rel.deinit(testing.allocator);

    var p = try Prober.init(testing.allocator, &rel);
    defer p.deinit(testing.allocator);

    const half_pi = std.math.pi / 2.0;
    const across: Rect = .{ .x0 = half_pi - 0.01, .x1 = half_pi + 0.01, .y0 = -1, .y1 = 1 };
    const r = one(&p, across);
    try testing.expect(!r.dec.isContinuous());
    try testing.expect(!p.provenBy(r, p.cornerValues(across)));

    // Away from the pole the same relation is happily continuous.
    const clear: Rect = .{ .x0 = 0.1, .x1 = 0.2, .y0 = -1, .y1 = 1 };
    try testing.expect(one(&p, clear).dec.isContinuous());
}

test "undefined regions are decided false rather than explored" {
    // sqrt(x) - y = 0 with x strictly negative.
    var rel = try buildRelation(testing.allocator, .eq, struct {
        fn f(b: *expr.Builder) !expr.Index {
            return b.sub(try b.unary(.sqrt, try b.x()), try b.y());
        }
    }.f);
    defer rel.deinit(testing.allocator);

    var p = try Prober.init(testing.allocator, &rel);
    defer p.deinit(testing.allocator);

    const outside: Rect = .{ .x0 = -4, .x1 = -1, .y0 = -1, .y1 = 1 };
    const r = one(&p, outside);
    try testing.expectEqual(Tri.false, r.tri);
    try testing.expectEqual(Decoration.ill, r.dec);
    // And a NaN corner sample is never read as "f is exactly zero here".
    try testing.expect(!p.provenBy(r, p.cornerValues(outside)));
}

test "quartering a rect tiles it" {
    const rect: Rect = .{ .x0 = -1, .x1 = 3, .y0 = 2, .y1 = 10 };
    const parts = rect.quarters();
    for (parts) |q| {
        try testing.expect(q.x0 >= rect.x0 and q.x1 <= rect.x1);
        try testing.expect(q.y0 >= rect.y0 and q.y1 <= rect.y1);
        try testing.expectEqual((rect.x1 - rect.x0) / 2, q.x1 - q.x0);
        try testing.expectEqual((rect.y1 - rect.y0) / 2, q.y1 - q.y0);
    }
}
