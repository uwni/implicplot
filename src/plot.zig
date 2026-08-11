//! The plotter: a quadtree over the *pixel grid*, evaluated four boxes at a
//! time, run in parallel over horizontal strips.
//!
//! ## Boxes are integer pixel rectangles
//!
//! The original subdivided the coordinate *domain* by repeated halving and then
//! converted the resulting floating-point rectangle back to pixel indices with
//! a truncate on one edge and a ceil on the other. Unless the image size was a
//! power of two the cells never lined up with pixels, so a box could bleed into
//! its neighbours, and the conversion itself was an unchecked `@intFromFloat`
//! on an unclamped value.
//!
//! Here a box is `[x0, x1) x [y0, y1)` in pixel indices. Splitting is integer
//! arithmetic, painting is an exact `Raster.fill`, and the interval handed to
//! the evaluator is derived from the indices rather than the other way round.
//!
//! ## Parallelism
//!
//! Rows are partitioned into strips, one task per strip via `std.Io.Group`.
//! `Raster` gives every row its own bytes, so tasks owning disjoint row ranges
//! never touch the same memory.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const interval = @import("interval.zig");
const relation = @import("relation.zig");
const Raster = @import("raster.zig").Raster;

const Tri = interval.Tri;
const Relation = relation.Relation;
const Reading = relation.Reading;
const Rect = relation.Rect;
const Corners = relation.Corners;

/// The mapping between pixel indices and the plane.
pub const View = struct {
    width: u32,
    height: u32,
    x_min: f64 = -10,
    x_max: f64 = 10,
    y_min: f64 = -10,
    y_max: f64 = 10,

    /// x coordinate of the left edge of pixel column `px`.
    pub fn xAt(self: View, px: u32) f64 {
        const t = @as(f64, @floatFromInt(px)) / @as(f64, @floatFromInt(self.width));
        return self.x_min + (self.x_max - self.x_min) * t;
    }

    /// y coordinate of the top edge of pixel row `py`. Rows run downwards, so
    /// row 0 is `y_max`.
    pub fn yAt(self: View, py: u32) f64 {
        const t = @as(f64, @floatFromInt(py)) / @as(f64, @floatFromInt(self.height));
        return self.y_max - (self.y_max - self.y_min) * t;
    }
};

pub const Options = struct {
    view: View,
    /// How many times a single undecided pixel may be split before giving up.
    ///
    /// The original used an absolute width of 1e-5 regardless of the plot
    /// scale, which is both meaningless at a different zoom and, at four-way
    /// recursion, up to 4^14 evaluations for one pixel.
    subpixel_depth: u8 = 8,
    /// Number of row strips; 0 picks a multiple of the CPU count so that the
    /// (very unevenly distributed) work balances.
    tasks: u32 = 0,
    progress: std.Progress.Node = .none,
};

pub const Box = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    pub fn cols(self: Box) u32 {
        return self.x1 - self.x0;
    }
    pub fn rows(self: Box) u32 {
        return self.y1 - self.y0;
    }
    pub fn isPixel(self: Box) bool {
        return self.cols() == 1 and self.rows() == 1;
    }

    /// Split into two or four children, whichever the box's shape allows.
    pub fn split(self: Box, out: *[4]Box) u8 {
        const xm = self.x0 + self.cols() / 2;
        const ym = self.y0 + self.rows() / 2;
        if (self.cols() > 1 and self.rows() > 1) {
            out[0] = .{ .x0 = self.x0, .y0 = self.y0, .x1 = xm, .y1 = ym };
            out[1] = .{ .x0 = xm, .y0 = self.y0, .x1 = self.x1, .y1 = ym };
            out[2] = .{ .x0 = self.x0, .y0 = ym, .x1 = xm, .y1 = self.y1 };
            out[3] = .{ .x0 = xm, .y0 = ym, .x1 = self.x1, .y1 = self.y1 };
            return 4;
        }
        if (self.cols() > 1) {
            out[0] = .{ .x0 = self.x0, .y0 = self.y0, .x1 = xm, .y1 = self.y1 };
            out[1] = .{ .x0 = xm, .y0 = self.y0, .x1 = self.x1, .y1 = self.y1 };
            return 2;
        }
        out[0] = .{ .x0 = self.x0, .y0 = self.y0, .x1 = self.x1, .y1 = ym };
        out[1] = .{ .x0 = self.x0, .y0 = ym, .x1 = self.x1, .y1 = self.y1 };
        return 2;
    }
};

/// The five points a quartering adds to a rect's four corners, forming a 3x3
/// grid: the edge midpoints - bottom, left, right, top - then the centre.
const grid_points = 5;

/// Which grid points each quarter of `Rect.quarters` has as corners, as a bit
/// set: every quarter touches the centre and its two adjacent edge midpoints.
const quarter_points = [4]u5{ 0b10011, 0b10101, 0b11010, 0b11100 };

/// A quarter's corner values, assembled from its parent's corners and the grid
/// samples - in the lane order `relation.Corners` documents, which is how they
/// are handed down to the next level of `refine`.
fn quarterCorners(corners: Corners, vals: [grid_points]f64, quarter: usize) Corners {
    return switch (quarter) {
        0 => .{ corners[0], vals[1], vals[0], vals[4] },
        1 => .{ vals[0], vals[4], corners[2], vals[2] },
        2 => .{ vals[1], corners[1], vals[4], vals[3] },
        3 => .{ vals[4], vals[3], vals[2], corners[3] },
        else => unreachable,
    };
}

/// One strip of rows, plus the scratch needed to work on it. Everything a task
/// allocates is allocated here, before the group starts.
const Worker = struct {
    prober: relation.Prober,
    raster: Raster,
    view: View,
    depth: u8,
    strip: Box,
    progress: std.Progress.Node,

    fn run(self: *Worker) void {
        const r = self.prober.probe(.{self.rectOf(self.strip)} ** 4)[0];
        self.visit(self.strip, r);
        self.progress.completeOne();
    }

    /// The pixel rectangle's footprint in the plane. Rows run downwards, so the
    /// bottom edge of the box is the larger row index.
    fn rectOf(self: *const Worker, box: Box) Rect {
        return .{
            .x0 = self.view.xAt(box.x0),
            .x1 = self.view.xAt(box.x1),
            .y0 = self.view.yAt(box.y1),
            .y1 = self.view.yAt(box.y0),
        };
    }

    fn visit(self: *Worker, box: Box, r: Reading) void {
        if (!self.settled(box, r)) self.explore(box);
    }

    /// Paint, refine or drop a box that needs no further probing. False means
    /// the box stays open: it must be split and its children probed.
    fn settled(self: *Worker, box: Box, r: Reading) bool {
        if (r.tri == .false) return true;

        if (box.isPixel()) {
            const rect = self.rectOf(box);
            if (r.tri == .true or self.refine(rect, r, self.prober.cornerValues(rect), self.depth)) {
                self.raster.set(box.x0, box.y0);
            }
            return true;
        }

        // A `true` verdict may only be painted wholesale if the relation is
        // defined across the entire box; otherwise the undefined part has to be
        // resolved by subdividing.
        if (r.tri == .true and r.dec.isDefined()) {
            self.raster.fill(box.x0, box.y0, box.x1, box.y1);
            return true;
        }
        return false;
    }

    /// Split an open box and probe its children.
    ///
    /// A quad split fills a probe exactly. A binary split would leave half of
    /// every pass as padding - and once a box splits two ways, so does every
    /// descendant, so whole chains of passes would run half empty; under
    /// `defaultTasks`' thin strips those chains carry most of the above-pixel
    /// work. `explorePair` instead probes the children of two open siblings
    /// in one full pass. Pairing changes which lanes a box occupies and
    /// nothing else: lanes are independent, so every box gets the same
    /// reading and the raster is bitwise identical either way.
    fn explore(self: *Worker, box: Box) void {
        var children: [4]Box = undefined;
        const n = box.split(&children);
        if (n == 4) {
            var rects: [4]Rect = undefined;
            for (&rects, &children) |*rect, child| rect.* = self.rectOf(child);
            const readings = self.prober.probe(rects);
            for (children, readings) |child, reading| self.visit(child, reading);
            return;
        }

        const padding = self.rectOf(children[1]);
        const readings = self.prober.probe(.{ self.rectOf(children[0]), padding, padding, padding });
        self.descend(children[0..2].*, readings[0..2].*);
    }

    /// Two open siblings of binary splits: their four children fill one probe.
    /// Only ever called on boxes that split two ways - a binary split's
    /// children are binary or pixels, never quads, so the invariant holds all
    /// the way down.
    fn explorePair(self: *Worker, a: Box, b: Box) void {
        var children: [4]Box = undefined;
        var second: [4]Box = undefined;
        const an = a.split(&children);
        const bn = b.split(&second);
        std.debug.assert(an == 2 and bn == 2);
        children[2] = second[0];
        children[3] = second[1];

        var rects: [4]Rect = undefined;
        for (&rects, &children) |*rect, child| rect.* = self.rectOf(child);
        const readings = self.prober.probe(rects);
        self.descend(children, readings);
    }

    /// Recurse into whichever probed children stay open, pairing them up so
    /// that their own splits keep the probes full.
    fn descend(self: *Worker, children: anytype, readings: anytype) void {
        var open: [4]Box = undefined;
        var count: usize = 0;
        for (children, readings) |child, reading| {
            if (!self.settled(child, reading)) {
                open[count] = child;
                count += 1;
            }
        }
        var i: usize = 0;
        while (i + 1 < count) : (i += 2) self.explorePair(open[i], open[i + 1]);
        if (count % 2 == 1) self.explore(open[count - 1]);
    }

    /// Below one pixel there is no grid left to index, so refinement falls back
    /// to bisecting the rectangle - but with a bounded depth.
    ///
    /// `corners` holds the values of `f` at the rect's own corners; the caller
    /// always has them. The sixteen corners of the four quarters are the nine
    /// points of a 3x3 grid, of which four are `corners`, so a level samples at
    /// most the five points it lacks instead of sixteen.
    ///
    /// The sampling is deliberately eager: everything the unknown quarters
    /// want, before any recursion. When the first recursion settles the rect,
    /// points only its never-visited siblings wanted were sampled for nothing
    /// - bounded at one extra pass per rect - but sampling lazily per quarter
    /// costs more in bookkeeping than that waste does; both were measured.
    fn refine(self: *Worker, rect: Rect, r: Reading, corners: Corners, depth: u8) bool {
        if (self.prober.provenBy(r, corners)) return true;
        if (depth == 0) return false;

        const quarters = rect.quarters();
        const readings = self.prober.probe(quarters);

        // A wholly-true quarter settles the rect by itself. Taking it before
        // any recursion changes no verdict - every path out of the original
        // interleaved loop returned true - it only skips needless sampling.
        var needed: u5 = 0;
        for (readings, quarter_points) |reading, points| switch (reading.tri) {
            .true => return true,
            .false => {},
            .unknown => needed |= points,
        };
        if (needed == 0) return false;

        var vals: [grid_points]f64 = undefined;
        if (@popCount(needed) <= 4) {
            sampleGrid(&self.prober, rect, needed, &vals);
        } else {
            sampleGrid(&self.prober, rect, 0b01111, &vals);
            sampleGrid(&self.prober, rect, 0b10000, &vals);
        }
        for (quarters, readings, 0..) |quarter, reading, i| {
            if (reading.tri != .unknown) continue;
            if (self.refine(quarter, reading, quarterCorners(corners, vals, i), depth - 1)) return true;
        }
        return false;
    }
};

/// Evaluate the grid points listed in `batch` - between one and four of
/// them - into their slots of `vals`, in one vector pass, the unused lanes
/// repeating a point.
fn sampleGrid(prober: *relation.Prober, rect: Rect, batch: u5, vals: *[grid_points]f64) void {
    // The same midpoint expressions as `Rect.quarters`, so a sample lands
    // exactly on the corner of the quarter it stands for.
    const xm = 0.5 * (rect.x0 + rect.x1);
    const ym = 0.5 * (rect.y0 + rect.y1);
    const grid_x = [grid_points]f64{ xm, rect.x0, rect.x1, xm, xm };
    const grid_y = [grid_points]f64{ rect.y0, ym, ym, rect.y1, ym };

    var lanes: [4]u3 = undefined;
    var count: usize = 0;
    for (0..grid_points) |p| {
        if ((batch >> @intCast(p)) & 1 != 0) {
            lanes[count] = @intCast(p);
            count += 1;
        }
    }
    for (lanes[count..]) |*slot| slot.* = lanes[0];

    var xs: [4]f64 = undefined;
    var ys: [4]f64 = undefined;
    for (lanes, &xs, &ys) |p, *x, *y| {
        x.* = grid_x[p];
        y.* = grid_y[p];
    }
    const got: [4]f64 = prober.evalPoints(xs, ys);
    for (lanes[0..count], got[0..count]) |p, value| vals[p] = value;
}

/// Render `rel` into a fresh raster. Caller owns the result.
///
/// `io` is where the row strips run. Passing `null` renders inline on the
/// calling thread - plotting is pure computation, so an environment without
/// threads (a freestanding wasm plugin, say) should not have to invent an `Io`
/// implementation just to satisfy a signature.
pub fn render(gpa: std.mem.Allocator, io: ?Io, rel: *const Relation, opts: Options) !Raster {
    const view = opts.view;
    // An inverted or degenerate range would hand the evaluator intervals with
    // `lo > hi`, which every operation in `interval.zig` assumes cannot happen.
    // The failure is silent - a blank or mirrored image - so it is a contract,
    // not a hint. The CLI checks the same thing earlier to report it kindly.
    std.debug.assert(view.width > 0 and view.height > 0);
    std.debug.assert(view.x_min < view.x_max and view.y_min < view.y_max);

    var raster = try Raster.init(gpa, view.width, view.height);
    errdefer raster.deinit(gpa);

    const requested: u32 = if (io == null) 1 else if (opts.tasks != 0) opts.tasks else defaultTasks();
    const task_count = @max(1, @min(view.height, requested));

    const workers = try gpa.alloc(Worker, task_count);
    defer gpa.free(workers);

    const node = opts.progress.start("strips", task_count);
    defer node.end();

    var made: usize = 0;
    errdefer for (workers[0..made]) |*w| w.prober.deinit(gpa);
    while (made < task_count) : (made += 1) {
        const y0: u32 = @intCast(@as(u64, view.height) * made / task_count);
        const y1: u32 = @intCast(@as(u64, view.height) * (made + 1) / task_count);
        workers[made] = .{
            .prober = try .init(gpa, rel),
            .raster = raster,
            .view = view,
            .depth = opts.subpixel_depth,
            .strip = .{ .x0 = 0, .y0 = y0, .x1 = view.width, .y1 = y1 },
            .progress = node,
        };
    }
    defer for (workers) |*w| w.prober.deinit(gpa);

    if (io) |runner| {
        var group: Io.Group = .init;
        defer group.cancel(runner);
        for (workers) |*w| group.async(runner, Worker.run, .{w});
        try group.await(runner);
    } else {
        for (workers) |*w| w.run();
    }

    return raster;
}

fn defaultTasks() u32 {
    // `builtin.single_threaded` is comptime, so on a freestanding wasm build
    // `std.Thread` is never even analysed.
    if (builtin.single_threaded) return 1;
    const cpus = std.Thread.getCpuCount() catch 4;
    return @intCast(@min(cpus * 8, 256));
}

const testing = std.testing;
const expr = @import("expr.zig");

fn testRelation(op: interval.Op, comptime f: fn (*expr.Builder) anyerror!expr.Index) !Relation {
    var b = expr.Builder.init(testing.allocator);
    defer b.deinit();
    const root = try f(&b);
    return .{ .program = try b.build(), .root = root, .op = op };
}

test "box splitting tiles the parent exactly, for any size" {
    for ([_]u32{ 1, 2, 3, 5, 7, 8, 13, 64 }) |w| {
        for ([_]u32{ 1, 2, 3, 5, 9, 16 }) |h| {
            const box: Box = .{ .x0 = 0, .y0 = 0, .x1 = w, .y1 = h };
            if (box.isPixel()) continue;
            var children: [4]Box = undefined;
            const n = box.split(&children);
            var area: u32 = 0;
            for (children[0..n]) |c| {
                try testing.expect(c.x1 > c.x0 and c.y1 > c.y0);
                try testing.expect(c.x0 >= box.x0 and c.x1 <= box.x1);
                try testing.expect(c.y0 >= box.y0 and c.y1 <= box.y1);
                area += c.cols() * c.rows();
            }
            try testing.expectEqual(w * h, area);
        }
    }
}

test "half plane renders exactly, at a non power of two size" {
    // x < 0 over [-1, 1]^2. Every pixel strictly left of centre is filled,
    // every pixel strictly right of it is not.
    var rel = try testRelation(.lt, struct {
        fn f(b: *expr.Builder) !expr.Index {
            return b.x();
        }
    }.f);
    defer rel.deinit(testing.allocator);

    var raster = try render(testing.allocator, testing.io, &rel, .{
        .view = .{ .width = 30, .height = 10, .x_min = -1, .x_max = 1, .y_min = -1, .y_max = 1 },
    });
    defer raster.deinit(testing.allocator);

    var y: u32 = 0;
    while (y < raster.height) : (y += 1) {
        var x: u32 = 0;
        while (x < raster.width) : (x += 1) {
            if (x < 15) try testing.expect(raster.isSet(x, y));
            if (x >= 15) try testing.expect(!raster.isSet(x, y));
        }
    }
}

test "a circle lands on the pixels the equation passes through" {
    // x^2 + y^2 - 1 = 0 over [-1.5, 1.5]^2.
    var rel = try testRelation(.eq, struct {
        fn f(b: *expr.Builder) !expr.Index {
            const s = try b.add(try b.powi(try b.x(), 2), try b.powi(try b.y(), 2));
            return b.sub(s, try b.constant(1));
        }
    }.f);
    defer rel.deinit(testing.allocator);

    const n = 64;
    var raster = try render(testing.allocator, testing.io, &rel, .{
        .view = .{ .width = n, .height = n, .x_min = -1.5, .x_max = 1.5, .y_min = -1.5, .y_max = 1.5 },
    });
    defer raster.deinit(testing.allocator);

    const view: View = .{ .width = n, .height = n, .x_min = -1.5, .x_max = 1.5, .y_min = -1.5, .y_max = 1.5 };

    // Every point of the true circle must be covered.
    for (0..360) |deg| {
        const a = @as(f64, @floatFromInt(deg)) * std.math.pi / 180.0;
        const px: u32 = @intFromFloat((@cos(a) - view.x_min) / (view.x_max - view.x_min) * n);
        const py: u32 = @intFromFloat((view.y_max - @sin(a)) / (view.y_max - view.y_min) * n);
        try testing.expect(raster.isSet(@min(px, n - 1), @min(py, n - 1)));
    }

    // And nothing far from it may be.
    try testing.expect(!raster.isSet(n / 2, n / 2));
    try testing.expect(!raster.isSet(0, 0));

    // A curve, not a blob.
    try testing.expect(raster.count() < n * n / 4);

    // Soundness in the other direction: a pixel is only ever lit because a
    // solution was *proved* to be inside it, so every lit pixel's box must
    // actually meet the circle.
    var py: u32 = 0;
    while (py < n) : (py += 1) {
        var px: u32 = 0;
        while (px < n) : (px += 1) {
            if (!raster.isSet(px, py)) continue;
            const x0 = view.xAt(px);
            const x1 = view.xAt(px + 1);
            const y1 = view.yAt(py);
            const y0 = view.yAt(py + 1);
            const near_x = if (x0 <= 0 and 0 <= x1) 0 else @min(x0 * x0, x1 * x1);
            const near_y = if (y0 <= 0 and 0 <= y1) 0 else @min(y0 * y0, y1 * y1);
            const far = @max(x0 * x0, x1 * x1) + @max(y0 * y0, y1 * y1);
            try testing.expect(near_x + near_y <= 1 + 1e-9);
            try testing.expect(far >= 1 - 1e-9);
        }
    }
}

test "an everywhere-undefined relation renders nothing" {
    // sqrt(-1 - x^2) = y  has no real solutions anywhere in view.
    var rel = try testRelation(.eq, struct {
        fn f(b: *expr.Builder) !expr.Index {
            const inner = try b.sub(try b.constant(-1), try b.powi(try b.x(), 2));
            return b.sub(try b.unary(.sqrt, inner), try b.y());
        }
    }.f);
    defer rel.deinit(testing.allocator);

    var raster = try render(testing.allocator, testing.io, &rel, .{
        .view = .{ .width = 32, .height = 32, .x_min = -2, .x_max = 2, .y_min = -2, .y_max = 2 },
    });
    defer raster.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), raster.count());
}

test "the quarter tables agree with the geometry they encode" {
    // Four artifacts state one geometry: the order of `Rect.quarters`, the
    // `Corners` lane order, `quarter_points`, and `quarterCorners`. Nothing
    // asserts if they drift - `provenBy` is lane-order-blind, so the image
    // just changes. This pins them together, executably and *exactly*: both
    // sides use the identical midpoint expressions and per-lane pure
    // evaluation, so the equality is bitwise, not approximate.
    var rel = try testRelation(.eq, struct {
        fn f(b: *expr.Builder) !expr.Index {
            // Injective on any 3x3 grid, defined everywhere.
            return b.add(try b.x(), try b.mul(try b.constant(3.7), try b.y()));
        }
    }.f);
    defer rel.deinit(testing.allocator);

    var p = try relation.Prober.init(testing.allocator, &rel);
    defer p.deinit(testing.allocator);

    const rect: Rect = .{ .x0 = -1.25, .x1 = 2.5, .y0 = 0.5, .y1 = 3.75 };
    const corners = p.cornerValues(rect);
    var vals: [grid_points]f64 = undefined;
    sampleGrid(&p, rect, 0b01111, &vals);
    sampleGrid(&p, rect, 0b10000, &vals);

    for (rect.quarters(), 0..) |quarter, i| {
        const want: [4]f64 = p.cornerValues(quarter);
        const got: [4]f64 = quarterCorners(corners, vals, i);
        try testing.expectEqual(want, got);
        // And the mask really lists the grid points the quarter reads.
        for (0..grid_points) |point| {
            const read = std.mem.indexOfScalar(f64, &got, vals[point]) != null;
            try testing.expectEqual(read, (quarter_points[i] >> @intCast(point)) & 1 != 0);
        }
    }
}

test "the number of strips does not change the image" {
    var rel = try testRelation(.eq, struct {
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

    const view: View = .{ .width = 48, .height = 48, .x_min = -3, .x_max = 3, .y_min = -3, .y_max = 3 };
    var one = try render(testing.allocator, testing.io, &rel, .{ .view = view, .tasks = 1 });
    defer one.deinit(testing.allocator);
    var many = try render(testing.allocator, testing.io, &rel, .{ .view = view, .tasks = 17 });
    defer many.deinit(testing.allocator);

    try testing.expect(one.count() > 0);
    try testing.expectEqualSlices(u8, one.bits, many.bits);
}
