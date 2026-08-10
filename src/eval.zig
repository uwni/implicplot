//! One evaluator, generic over the arithmetic domain.
//!
//! `Domain` is any type providing `splat` plus the operations named by
//! `expr.Tag` - `interval.Interval(n)` and `real.Real(n)` both qualify. The
//! original carried three hand-written copies of this switch (`eval`,
//! `evalInterval`, `evalIntervalSet`), each recursive, one of them dead, and
//! the interval-set one allocating a heap list per node per visit.
//!
//! Evaluation is a single forward pass over the node array. Because operands
//! precede their parents (see `expr.zig`), every node is computed exactly once,
//! and the scratch buffer is allocated once per worker rather than per visit.

const std = @import("std");
const expr = @import("expr.zig");

pub fn Evaluator(comptime Domain: type) type {
    return struct {
        const Self = @This();
        program: *const expr.Program,
        scratch: []Domain,

        pub fn init(gpa: std.mem.Allocator, program: *const expr.Program) !Self {
            // `eval` reads operands out of already-filled scratch slots without
            // bounds checks, so the invariant it depends on is checked once
            // here rather than trusted. `Program` is public: a caller can hand
            // us a hand-built one.
            for (program.nodes, 0..) |node, i| switch (node.tag.arity()) {
                0 => {},
                1 => std.debug.assert(node.a < i),
                2 => std.debug.assert(node.a < i and node.b < i),
                else => unreachable,
            };
            return .{ .program = program, .scratch = try gpa.alloc(Domain, program.nodes.len) };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.scratch);
            self.* = undefined;
        }

        /// Evaluate every node for the given x and y, then read off `root`.
        ///
        /// Only the four tags whose shape is special are written out. Every
        /// other operator dispatches by name - `expr.Tag.sqrt` calls
        /// `Domain.sqrt` - so the domain contract is enforced by the compiler
        /// rather than by a comment, and adding an operator means adding a tag
        /// and implementing it in the two domains. There is no third place to
        /// forget.
        pub fn eval(self: *Self, root: expr.Index, x: Domain, y: Domain) Domain {
            const v = self.scratch;
            for (self.program.nodes, 0..) |node, i| {
                v[i] = switch (node.tag) {
                    .constant => Domain.splat(node.value),
                    .x => x,
                    .y => y,
                    .powi => v[node.a].powi(node.exponent()),
                    inline else => |tag| switch (comptime tag.arity()) {
                        1 => @field(Domain, @tagName(tag))(v[node.a]),
                        2 => @field(Domain, @tagName(tag))(v[node.a], v[node.b]),
                        else => comptime unreachable,
                    },
                };
            }
            return v[root];
        }
    };
}

const testing = std.testing;

test "the same program evaluates in both domains" {
    const Interval = @import("interval.zig").Interval;
    const Real = @import("real.zig").Real;

    var b = expr.Builder.init(testing.allocator);
    defer b.deinit();
    // sin(x^2 + y^2) - cos(x*y)
    const xi = try b.x();
    const yi = try b.y();
    const root = try b.sub(
        try b.call(.sin, try b.add(try b.powi(xi, 2), try b.powi(yi, 2))),
        try b.call(.cos, try b.mul(xi, yi)),
    );
    var program = try b.build();
    defer program.deinit(testing.allocator);

    var real: Evaluator(Real(4)) = try .init(testing.allocator, &program);
    defer real.deinit(testing.allocator);
    var box: Evaluator(Interval(1)) = try .init(testing.allocator, &program);
    defer box.deinit(testing.allocator);

    const xs = [4]f64{ 0.25, 0.5, -1.0, 2.0 };
    const ys = [4]f64{ -0.75, 1.5, 0.0, 0.5 };
    const point: [4]f64 = real.eval(root, Real(4).init(xs), Real(4).init(ys)).v;
    for (0..4) |i| {
        const want = @sin(xs[i] * xs[i] + ys[i] * ys[i]) - @cos(xs[i] * ys[i]);
        try testing.expectApproxEqAbs(want, point[i], 1e-12);
    }

    // The interval over a box containing all four points must enclose them all.
    const enclosure = box.eval(root, Interval(1).repeat(-1, 2), Interval(1).repeat(-0.75, 1.5));
    for (point) |v| {
        try testing.expect(enclosure.lo[0] <= v and v <= enclosure.hi[0]);
    }
}

test "shared nodes are evaluated once" {
    const Real = @import("real.zig").Real;
    var b = expr.Builder.init(testing.allocator);
    defer b.deinit();
    const xi = try b.x();
    // A chain that would be exponential under naive recursive evaluation:
    // t1 = x+x, t2 = t1+t1, ... t20 = t19+t19
    var t = xi;
    for (0..20) |_| t = try b.add(t, t);
    var program = try b.build();
    defer program.deinit(testing.allocator);

    // 1 node for x plus 20 sums: the DAG never expands into a tree.
    try testing.expectEqual(@as(usize, 21), program.nodes.len);

    var e: Evaluator(Real(1)) = try .init(testing.allocator, &program);
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 1 << 20), e.eval(t, Real(1).splat(1), Real(1).splat(0)).v[0]);
}
