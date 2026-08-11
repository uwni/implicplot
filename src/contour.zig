//! The curve as polylines, by subdivision with a guaranteed topology.
//!
//! The shape of the algorithm is Plantinga & Vegter, *Isotopic Approximation of
//! Implicit Curves and Surfaces* (SGP 2004); the stopping rule is the weaker one
//! of Lin & Yap, *Adaptive Isotopic Approximation of Nonsingular Curves* (DCG 45,
//! 2011), which stops sooner for the same guarantee.
//!
//! `plot.zig` answers "which pixels may the curve touch" and returns a raster.
//! This answers "where is the curve" and returns points. Tracing the raster is
//! not a substitute: it follows the outline of the band of lit pixels.
//!
//! ## Why not marching squares on a uniform grid
//!
//! A uniform grid has no way to know it is too coarse. Where the curve turns
//! faster than the spacing, marching squares connects samples that are not
//! consecutive along the curve, and the result is wrong in a way no amount of
//! post-processing detects. Raising the resolution everywhere costs
//! quadratically and still guarantees nothing.
//!
//! What subdivision adds is a *stopping rule* that does guarantee something. A
//! cell is finished when, over interval enclosures across the whole cell,
//!
//! ```text
//!     0 not in F(C)                        - the curve misses the cell, or
//!     0 not in Fx(C)  or  0 not in Fy(C)   - "Cxy"
//! ```
//!
//! Cxy says `F` is strictly monotone in x or in y across the cell, so the curve
//! meets every vertical (or every horizontal) line at most once there: a single
//! monotone arc, no loop, no second branch, nothing to miss. That is what makes
//! the piecewise-linear output *isotopic* to the true curve - the same topology,
//! not merely a close-looking picture.
//!
//! Plantinga & Vegter instead ask that the gradient turn by less than a right
//! angle, `<grad F, grad F> > 0`. That implies Cxy, so it splits cells Cxy would
//! have accepted. Measured on `sin(x^2+y^2) = cos(x y)` over `[-8,8]^2`, the
//! weaker rule is 1.67x faster and leaves 30% fewer cells unresolved, for the
//! same curve.
//!
//! Both clauses need exactly what this project already has: interval arithmetic
//! for the first, and `dual.zig` over intervals for the second.
//!
//! ## The tree is an array
//!
//! A quadtree splits into four, so the four children are stored contiguously and
//! a node needs one index rather than four: it is four bytes. Geometry is not
//! stored either - a walk carries the cell down with it - and neither are corner
//! values, which a parent computes once and its children inherit. Every lookup
//! is an array index; nothing is hashed.
//!
//! ## What it does not do
//!
//! The proof assumes 0 is a regular value, i.e. `grad F` is non-zero on the
//! curve. At a self-intersection `grad F` vanishes, so neither clause can ever
//! hold and subdivision would not terminate. `extra_depth` stops it, and those
//! cells are counted in `Curves.uncertain` rather than quietly passed off as
//! correct. Near a singularity the output is two arcs passing within a fraction
//! of a cell instead of one crossing - a property of the singularity, not of the
//! method.

const std = @import("std");
const interval = @import("interval.zig");
const relation = @import("relation.zig");
const real = @import("real.zig");
const dual = @import("dual.zig");
const eval = @import("eval.zig");
const Rect = relation.Rect;

const Relation = relation.Relation;
const Iv4 = interval.Interval(4);
const R8 = real.Real(8);
/// A quadtree split makes exactly four children, so they are classified in one
/// vector pass - the same trick, and the same width, as `plot.zig` uses.
const Gradient = dual.Dual(Iv4);

pub const Point = struct { x: f64, y: f64 };

pub const Options = struct {
    /// Split every cell the curve may pass through at least this far, giving
    /// `2^min_depth` cells across the view.
    ///
    /// The stopping rule settles topology, not accuracy: the gradient of a
    /// circle barely turns, so a circle is *correctly* a dodecagon after four
    /// levels. This is the accuracy knob the paper suggests, and it costs
    /// nothing where the curve is not - empty cells still stop at once.
    min_depth: u5 = 6,
    /// How much further a cell the rule cannot settle may be split. Subdivision
    /// normally stops well short, but at a self-intersection neither clause can
    /// ever hold, so without a cap it would not terminate. Cells stopped here
    /// are counted in `Curves.uncertain`.
    ///
    /// Each level costs about four times the last, for shrinking returns: on
    /// `sin(x^2+y^2) = cos(x y)` over `[-8,8]^2`, going from two levels to four
    /// costs 2.4x the time to move the unresolved count from 11848 to 11696.
    extra_depth: u5 = 2,
    /// What to draw inside a cell the rule could not certify. The curve has
    /// values there - the cells sit ON the curve - but the gradient vanishes,
    /// so subdivision cannot decide how the arcs connect, and something must
    /// be drawn:
    ///
    ///   * `.avoid`: pair the four boundary crossings into two arcs that pass
    ///     each other. Right when the "crossing" is a near miss.
    ///   * `.join`: connect all four to a vertex at the cell's centre - a true
    ///     X junction. Right when the curve genuinely crosses itself, e.g.
    ///     whenever the relation factors: `sin(x^2+y^2) = cos(x y)` is
    ///     `2 cos(u) sin(v) = 0`, a union of two ellipse families, and every
    ///     family-to-family meeting is a real intersection.
    ///
    /// The choice is the caller's because it cannot be computed: the two cases
    /// are indistinguishable to any subdivision method - that is what
    /// `Curves.uncertain` reports.
    uncertain: enum { avoid, join } = .avoid,

    fn maxDepth(self: Options) u5 {
        return @min(@as(u5, coord_bits - 1), self.min_depth +| self.extra_depth);
    }
};

/// What the stopping rule says about a cell.
const State = enum {
    /// The curve misses it, or `F` is nowhere defined on it. Nothing to draw,
    /// and nothing is gained by looking closer - this is where the adaptivity
    /// comes from.
    empty,
    /// `F` is monotone in x or in y across it, so the curve is a single arc.
    finished,
    /// Neither: the cell must be split.
    unresolved,
    /// `f` is not even continuous across the cell - it contains a pole. Never
    /// drawn into: a sign change between two corners flanking a jump is the
    /// function passing through infinity, not through zero, and interpolating
    /// it manufactures a vertical line down the asymptote.
    jump,
};

/// Polylines, flattened. `points[starts[k]..starts[k+1]]` is chain `k`, so
/// `starts` has `len() + 1` entries.
pub const Curves = struct {
    points: []Point,
    starts: []u32,
    /// Cells that hit the depth limit without satisfying either stopping
    /// clause. Non-zero means the curve has a singularity (or something very
    /// close to one) and the topology near it is not guaranteed.
    uncertain: u32,

    pub fn len(self: Curves) usize {
        return self.starts.len - 1;
    }

    pub fn chain(self: Curves, k: usize) []const Point {
        return self.points[self.starts[k]..self.starts[k + 1]];
    }

    pub fn deinit(self: *Curves, gpa: std.mem.Allocator) void {
        gpa.free(self.points);
        gpa.free(self.starts);
        self.* = undefined;
    }
};

const none: u32 = std.math.maxInt(u32);

/// A cell the stopping rule never settled, and why.
const Unresolved = struct { x: u32, y: u32, jump: bool };

/// Four bytes. The four children are contiguous, so one index locates all of
/// them: child `(dx, dy)` is `first_child + 2*dy + dx`.
const Node = struct { first_child: u32 = none };

/// A cell in integer coordinates at the finest level. Never stored - a traversal
/// carries it down, which is cheaper than remembering it.
const Cell = struct {
    x: u32,
    y: u32,
    size: u32,

    fn child(self: Cell, dx: u32, dy: u32) Cell {
        const half = self.size / 2;
        return .{ .x = self.x + half * dx, .y = self.y + half * dy, .size = half };
    }

    /// Corner `2*dy + dx`, in grid coordinates.
    fn corner(self: Cell, which: u2) [2]u32 {
        const dx: u32 = @intFromBool(which & 1 != 0);
        const dy: u32 = @intFromBool(which & 2 != 0);
        return .{ self.x + self.size * dx, self.y + self.size * dy };
    }
};

/// A cell's four corner values, in the same order as its children.
const Corners = [4]f64;

/// A crossing lies on a grid *edge*, and the two cells sharing that edge derive
/// it from the same pair of samples. Naming the edge therefore names the
/// crossing, so segments join by identity rather than by comparing coordinates -
/// no welding tolerance, no epsilon.
const EdgeKey = u64;

/// How many bits a grid coordinate may need. `Options.maxDepth` clamps to
/// `coord_bits - 1`, so a corner index reaches `2^(coord_bits-1)` inclusive
/// and fits; a deeper tree would silently overflow `lo[0]` into `lo[1]`'s
/// field and collide distinct edges. The depth cap and this layout are the
/// same fact - stated once, checked below against the junction namespace
/// `joinClusters` opens at bit 48.
const coord_bits = 21;

comptime {
    std.debug.assert(coord_bits + coord_bits + 5 + 1 <= 48);
}

fn edgeKey(lo: [2]u32, length: u32, vertical: bool) EdgeKey {
    return @as(u64, lo[0]) | (@as(u64, lo[1]) << coord_bits) |
        (@as(u64, @ctz(length)) << 2 * coord_bits) | (@as(u64, @intFromBool(vertical)) << 2 * coord_bits + 5);
}

/// A crossing on the boundary of a leaf, and which of its four sides it is on.
const Crossing = struct { edge: EdgeKey, point: Point, side: u2 };

/// A crossing before duplicates from the two adjacent leaves are merged.
const Found = struct { edge: EdgeKey, point: Point };

/// The tree walk serves two turns: finding the boxes that must be split before
/// the graph can be read off, and then reading it off.
const Mode = enum { scan, emit };

const Tree = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    /// The five grid samples a split adds - side midpoints b, t, l, r, then
    /// the centre - computed once when `splitInto` makes the node internal,
    /// and read by every walk. Splits append four nodes each, so internal
    /// node `first_child` owns slot `(first_child - 1) / 4`: dense, no hash.
    /// Without this, every `emit` walk - and `trace` runs at least two, plus
    /// one per ambiguity round - re-evaluated all five per internal node.
    grid: std.ArrayList([5]f64) = .empty,
    uncertain: u32 = 0,

    rel: *const Relation,
    rect: Rect,
    span: u32,
    boxes: eval.Evaluator(Gradient),
    samples: eval.Evaluator(R8),

    found: std.ArrayList(Found) = .empty,
    /// Leaves the construction cannot read unambiguously; they get split.
    ambiguous: std.ArrayList(Cell) = .empty,
    /// Segments, as the pair of edges they connect.
    segments: std.ArrayList([2]EdgeKey) = .empty,
    /// The cells counted in `uncertain`, sorted before emit so a leaf can ask
    /// "am I one of them" with a binary search. All have the same (smallest)
    /// size, since only cells at the depth cap are ever unresolved.
    uncertain_cells: std.ArrayList(Unresolved) = .empty,
    join_uncertain: bool = false,
    min_cell_size: u32 = 1,
    spokes: std.ArrayList(struct { cell: u32, edge: EdgeKey, point: Point }) = .empty,

    fn init(gpa: std.mem.Allocator, rel: *const Relation, rect: Rect, depth: u5) !Tree {
        var boxes: eval.Evaluator(Gradient) = try .init(gpa, &rel.program);
        errdefer boxes.deinit(gpa);
        const samples: eval.Evaluator(R8) = try .init(gpa, &rel.program);
        return .{
            .gpa = gpa,
            .rel = rel,
            .rect = rect,
            .span = @as(u32, 1) << depth,
            .boxes = boxes,
            .samples = samples,
        };
    }

    fn deinit(self: *Tree) void {
        self.nodes.deinit(self.gpa);
        self.grid.deinit(self.gpa);
        self.found.deinit(self.gpa);
        self.uncertain_cells.deinit(self.gpa);
        self.spokes.deinit(self.gpa);
        self.ambiguous.deinit(self.gpa);
        self.segments.deinit(self.gpa);
        self.boxes.deinit(self.gpa);
        self.samples.deinit(self.gpa);
        self.* = undefined;
    }

    fn xAt(self: *const Tree, i: u32) f64 {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(self.span));
        return self.rect.x0 + (self.rect.x1 - self.rect.x0) * t;
    }

    fn yAt(self: *const Tree, j: u32) f64 {
        const t = @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(self.span));
        return self.rect.y0 + (self.rect.y1 - self.rect.y0) * t;
    }

    /// `F` at eight grid points at once.
    ///
    /// The lanes of a vector evaluation are independent and Zig's float mode is
    /// strict, so a point evaluated here agrees bit for bit with the same point
    /// evaluated in any other lane or batch. Two cells sharing a corner
    /// therefore cannot disagree about it, and none of this has to be cached.
    fn valuesAt(self: *Tree, ix: [8]u32, iy: [8]u32) [8]f64 {
        var xs: [8]f64 = undefined;
        var ys: [8]f64 = undefined;
        for (0..8) |k| {
            xs[k] = self.xAt(ix[k]);
            ys[k] = self.yAt(iy[k]);
        }
        return self.samples.eval(self.rel.root, R8.init(xs), R8.init(ys)).v;
    }

    fn valueAt(self: *Tree, at: [2]u32) f64 {
        return self.valuesAt(.{at[0]} ** 8, .{at[1]} ** 8)[0];
    }

    /// The paper's stopping rule, applied to four cells in one vector pass.
    fn classify(self: *Tree, cells: [4]Cell) [4]State {
        var x_lo: [4]f64 = undefined;
        var x_hi: [4]f64 = undefined;
        var y_lo: [4]f64 = undefined;
        var y_hi: [4]f64 = undefined;
        for (cells, 0..) |cell, i| {
            x_lo[i] = self.xAt(cell.x);
            x_hi[i] = self.xAt(cell.x + cell.size);
            y_lo[i] = self.yAt(cell.y);
            y_hi[i] = self.yAt(cell.y + cell.size);
        }

        const g = self.boxes.eval(
            self.rel.root,
            Gradient.varX(Iv4.init(x_lo, x_hi)),
            Gradient.varY(Iv4.init(y_lo, y_hi)),
        );

        // Cxy: `F` is strictly monotone in x, or strictly monotone in y, across
        // the cell - so the curve meets every vertical (resp. horizontal) line
        // at most once there. Plantinga & Vegter instead ask that the gradient
        // turn by less than a right angle, which *implies* Cxy and so splits
        // more than it has to.
        const zero: @Vector(4, f64) = @splat(0);
        const monotone_x = (g.dx.lo > zero) | (g.dx.hi < zero);
        const monotone_y = (g.dy.lo > zero) | (g.dy.hi < zero);
        const parametrizable = monotone_x | monotone_y;

        var out: [4]State = undefined;
        inline for (0..4) |i| {
            out[i] = blk: {
                // Nowhere defined: there is no curve here to get wrong.
                if (g.v.decoration(i) == .ill) break :blk .empty;
                // The enclosure of F excludes zero: the curve misses the cell.
                if (g.v.lo[i] > 0 or g.v.hi[i] < 0) break :blk .empty;
                // A jump inside breaks the monotonicity argument outright.
                if (!g.v.decoration(i).isContinuous()) break :blk .jump;
                break :blk if (parametrizable[i]) .finished else .unresolved;
            };
        }
        return out;
    }

    fn classifyOne(self: *Tree, cell: Cell) State {
        return self.classify(.{cell} ** 4)[0];
    }

    // -- building -------------------------------------------------------------

    fn subdivide(
        self: *Tree,
        index: u32,
        cell: Cell,
        state: State,
        depth: u5,
        opts: Options,
    ) std.mem.Allocator.Error!void {
        // Empty space stops immediately however deep `min_depth` asks for -
        // refining where there is no curve is the cost an adaptive tree exists
        // to avoid.
        const must_split = state == .unresolved or state == .jump;
        const deep_enough = state == .empty or depth >= opts.min_depth;
        if (!must_split and deep_enough) return;
        if (depth >= opts.maxDepth()) {
            if (must_split) {
                self.uncertain += 1;
                try self.uncertain_cells.append(
                    self.gpa,
                    .{ .x = cell.x, .y = cell.y, .jump = state == .jump },
                );
            }
            return;
        }
        try self.splitInto(index, cell, depth, opts);
    }

    /// Give `index` four children and recurse, classifying all four at once.
    fn splitInto(self: *Tree, index: u32, cell: Cell, depth: u5, opts: Options) std.mem.Allocator.Error!void {
        const first: u32 = @intCast(self.nodes.items.len);
        try self.nodes.appendNTimes(self.gpa, .{}, 4);
        self.nodes.items[index].first_child = first;

        const half = cell.size / 2;
        const mx = cell.x + half;
        const my = cell.y + half;
        const v = self.valuesAt(
            .{ mx, mx, cell.x, cell.x + cell.size, mx, mx, mx, mx },
            .{ cell.y, cell.y + cell.size, my, my, my, my, my, my },
        );
        try self.grid.append(self.gpa, .{ v[0], v[1], v[2], v[3], v[4] });

        const children = [4]Cell{
            cell.child(0, 0), cell.child(1, 0),
            cell.child(0, 1), cell.child(1, 1),
        };
        const states = self.classify(children);
        for (children, states, 0..) |kid, state, k| {
            try self.subdivide(first + @as(u32, @intCast(k)), kid, state, depth + 1, opts);
        }
    }

    fn isLeaf(self: *const Tree, index: u32) bool {
        return self.nodes.items[index].first_child == none;
    }

    /// The node covering `(x, y)` at exactly `size`, or null if a coarser leaf
    /// covers it. A walk from the root: `depth` array reads, nothing hashed.
    fn nodeAt(self: *const Tree, x: u32, y: u32, size: u32) ?u32 {
        if (x >= self.span or y >= self.span) return null;
        var index: u32 = 0;
        var cell: Cell = .{ .x = 0, .y = 0, .size = self.span };
        while (cell.size > size) {
            const first = self.nodes.items[index].first_child;
            if (first == none) return null;
            const half = cell.size / 2;
            const dx: u32 = @intFromBool(x >= cell.x + half);
            const dy: u32 = @intFromBool(y >= cell.y + half);
            index = first + 2 * dy + dx;
            cell = cell.child(dx, dy);
        }
        return index;
    }

    /// The cell across `side`, at the same size. Out of bounds gives null.
    fn acrossSide(self: *const Tree, cell: Cell, side: u2) ?Cell {
        const size = @as(i64, cell.size);
        const delta: [2]i64 = switch (side) {
            0 => .{ 0, -size }, // below
            1 => .{ size, 0 }, // right
            2 => .{ 0, size }, // above
            3 => .{ -size, 0 }, // left
        };
        const nx = @as(i64, cell.x) + delta[0];
        const ny = @as(i64, cell.y) + delta[1];
        if (nx < 0 or ny < 0 or nx >= self.span or ny >= self.span) return null;
        return .{ .x = @intCast(nx), .y = @intCast(ny), .size = cell.size };
    }

    /// Whether the neighbour across `side` is split, so this side is two edges.
    fn neighbourIsFiner(self: *const Tree, cell: Cell, side: u2) bool {
        const neighbour = self.acrossSide(cell, side) orelse return false;
        const index = self.nodeAt(neighbour.x, neighbour.y, neighbour.size) orelse return false;
        return !self.isLeaf(index);
    }

    /// Split leaves until no two neighbours differ by more than one level. The
    /// connection rule below is only proved for cells surrounded by four to
    /// eight edges, which is what this guarantees.
    fn balance(self: *Tree, opts: Options) !void {
        // Splitting a cell can only put its own neighbours out of balance, so
        // those are the only ones worth looking at again. Rescanning the whole
        // tree after each pass instead spends a full sweep to find the handful
        // that changed, and the sweeps outnumber the splits.
        var queue: std.Deque(Cell) = .empty;
        defer queue.deinit(self.gpa);
        try self.collectLeaves(0, .{ .x = 0, .y = 0, .size = self.span }, &queue);

        while (queue.popFront()) |cell| {
            if (cell.size <= 1) continue;
            const index = self.nodeAt(cell.x, cell.y, cell.size) orelse continue;
            if (!self.isLeaf(index)) continue; // already split since queued
            if (!self.hasFinerNeighbour(cell)) continue;

            const depth = @as(u5, @intCast(@ctz(self.span) - @ctz(cell.size)));
            try self.splitInto(index, cell, depth, opts);

            // The cells across this one's sides are now beside something finer.
            for (0..4) |side| {
                const neighbour = self.acrossSide(cell, @intCast(side)) orelse continue;
                try queue.pushBack(self.gpa, neighbour);
            }
        }
    }

    fn collectLeaves(self: *const Tree, index: u32, cell: Cell, out: *std.Deque(Cell)) !void {
        const first = self.nodes.items[index].first_child;
        if (first == none) return out.pushBack(self.gpa, cell);
        for (0..4) |k| {
            const dx: u32 = @intCast(k & 1);
            const dy: u32 = @intCast(k >> 1);
            try self.collectLeaves(first + @as(u32, @intCast(k)), cell.child(dx, dy), out);
        }
    }

    /// True if any neighbour across a side is more than one level finer, which
    /// shows up as a *subdivided* half-size cell abutting the side.
    fn hasFinerNeighbour(self: *const Tree, cell: Cell) bool {
        const half = cell.size / 2;
        if (half == 0) return false;
        const size = @as(i64, cell.size);
        const step = @as(i64, half);
        const x = @as(i64, cell.x);
        const y = @as(i64, cell.y);
        const probes = [8][2]i64{
            .{ x - step, y }, .{ x - step, y + step },
            .{ x + size, y }, .{ x + size, y + step },
            .{ x, y - step }, .{ x + step, y - step },
            .{ x, y + size }, .{ x + step, y + size },
        };
        for (probes) |p| {
            if (p[0] < 0 or p[1] < 0) continue;
            const index = self.nodeAt(@intCast(p[0]), @intCast(p[1]), half) orelse continue;
            if (!self.isLeaf(index)) return true;
        }
        return false;
    }

    // -- reading the curve off -------------------------------------------------

    /// Walk the finished tree, carrying each cell's corner values down. A parent
    /// computes the five new points of its split once, and each child inherits
    /// four of the nine.
    fn emit(self: *Tree, comptime mode: Mode, index: u32, cell: Cell, corners: Corners) std.mem.Allocator.Error!void {
        const first = self.nodes.items[index].first_child;
        if (first == none) return self.emitLeaf(mode, cell, corners);

        //   c2 --- t --- c3     the five new points are the four side midpoints
        //    |     |     |      and the centre; the four corners are known,
        //    l -- ctr -- r      and the five were sampled when `splitInto`
        //    |     |     |      made this node internal
        //   c0 --- b --- c1
        const v = self.grid.items[(first - 1) / 4];
        const b = v[0];
        const t = v[1];
        const l = v[2];
        const r = v[3];
        const ctr = v[4];

        const child_corners = [4]Corners{
            .{ corners[0], b, l, ctr },
            .{ b, corners[1], ctr, r },
            .{ l, ctr, corners[2], t },
            .{ ctr, r, t, corners[3] },
        };
        for (0..4) |k| {
            const dx: u32 = @intCast(k & 1);
            const dy: u32 = @intCast(k >> 1);
            try self.emit(mode, first + @as(u32, @intCast(k)), cell.child(dx, dy), child_corners[k]);
        }
    }

    fn emitLeaf(self: *Tree, comptime mode: Mode, cell: Cell, corners: Corners) !void {
        // A pole is drawn as nothing. The corner signs across a jump differ,
        // but that sign change is the function passing through infinity;
        // fabricating crossings from it would draw the asymptote itself.
        if (cell.size == self.min_cell_size) {
            if (self.uncertainIndex(cell)) |idx| {
                if (self.uncertain_cells.items[idx].jump) return;
            }
        }

        var boundary: [8]Crossing = undefined;
        var count: u8 = 0;

        for (0..4) |s| {
            const side: u2 = @intCast(s);
            // Sides run anticlockwise from the bottom, each traversed so the
            // crossings come out in boundary order.
            const ends: [2]u2 = switch (side) {
                0 => .{ 0, 1 }, // bottom: c0 -> c1
                1 => .{ 1, 3 }, // right:  c1 -> c3
                2 => .{ 3, 2 }, // top:    c3 -> c2
                3 => .{ 2, 0 }, // left:   c2 -> c0
            };
            const from = cell.corner(ends[0]);
            const to = cell.corner(ends[1]);
            const from_value = corners[ends[0]];
            const to_value = corners[ends[1]];

            if (!self.neighbourIsFiner(cell, side)) {
                if (self.crossing(from, from_value, to, to_value, side)) |c| {
                    boundary[count] = c;
                    count += 1;
                }
                continue;
            }

            // A finer neighbour splits this side in two. The midpoint is a
            // corner of that neighbour: the same grid point, so the same value.
            const mid: [2]u32 = .{ (from[0] + to[0]) / 2, (from[1] + to[1]) / 2 };
            const mid_value = self.valueAt(mid);
            const halves = [2][2][2]u32{ .{ from, mid }, .{ mid, to } };
            const values = [2][2]f64{ .{ from_value, mid_value }, .{ mid_value, to_value } };
            for (halves, values) |pair, pair_values| {
                if (self.crossing(pair[0], pair_values[0], pair[1], pair_values[1], side)) |c| {
                    if (count == boundary.len) break;
                    boundary[count] = c;
                    count += 1;
                }
            }
        }

        if (mode == .scan) return self.noteIfAmbiguous(cell, corners, count);
        if (self.join_uncertain) {
            if (self.uncertainIndex(cell)) |cluster_cell| {
                // Inside an uncertain cell the pairing would be a guess, so
                // none is made: the crossings become spokes of the enclosing
                // cluster's junction instead (see `joinClusters`).
                for (boundary[0..count]) |c| {
                    try self.found.append(self.gpa, .{ .edge = c.edge, .point = c.point });
                    try self.spokes.append(self.gpa, .{ .cell = cluster_cell, .edge = c.edge, .point = c.point });
                }
                return;
            }
        }
        try self.connect(boundary[0..count]);
    }

    /// Index of `cell` in the sorted uncertain list, or null.
    fn uncertainIndex(self: *const Tree, cell: Cell) ?u32 {
        return self.uncertainIndexAt(cell.x, cell.y);
    }

    fn uncertainIndexAt(self: *const Tree, x: u32, y: u32) ?u32 {
        const at = std.sort.binarySearch(Unresolved, self.uncertain_cells.items, [2]u32{ x, y }, orderByPosition) orelse return null;
        return @intCast(at);
    }

    /// The (y, x) order of the uncertain list. One definition serves both the
    /// sort and the search, so the two cannot come to disagree.
    fn orderByPosition(target: [2]u32, item: Unresolved) std.math.Order {
        if (target[1] != item.y) return std.math.order(target[1], item.y);
        return std.math.order(target[0], item.x);
    }

    fn sortUncertain(self: *Tree) void {
        std.mem.sortUnstable(Unresolved, self.uncertain_cells.items, {}, struct {
            fn less(_: void, a: Unresolved, b: Unresolved) bool {
                return orderByPosition(.{ a.x, a.y }, b) == .lt;
            }
        }.less);
    }

    /// Contract each connected cluster of uncertain cells to one junction.
    ///
    /// Within the cluster, connectivity is exactly the thing subdivision could
    /// not certify, so under `.join` the whole cluster is treated as a single
    /// point: every arc entering it is connected to every other, which is the
    /// quotient of the unknowable region. A genuine crossing gets its X; the
    /// price, and the reason this is opt-in, is that arcs merely passing
    /// through the same cluster are glued too.
    fn joinClusters(self: *Tree) !void {
        const cells = self.uncertain_cells.items;
        if (cells.len == 0 or self.spokes.items.len == 0) return;
        // Connected components over 4-adjacency, by flood fill on the sorted list.
        const cluster_of = try self.gpa.alloc(u32, cells.len);
        defer self.gpa.free(cluster_of);
        @memset(cluster_of, none);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(self.gpa);

        const step = self.min_cell_size;
        var clusters: u32 = 0;
        for (0..cells.len) |seed| {
            if (cluster_of[seed] != none) continue;
            cluster_of[seed] = clusters;
            try stack.append(self.gpa, @intCast(seed));
            while (stack.pop()) |at| {
                const c = cells[at];
                const neighbours = [4][2]i64{
                    .{ @as(i64, c.x) - step, c.y }, .{ @as(i64, c.x) + step, c.y },
                    .{ c.x, @as(i64, c.y) - step }, .{ c.x, @as(i64, c.y) + step },
                };
                for (neighbours) |nc| {
                    if (nc[0] < 0 or nc[1] < 0) continue;
                    const idx = self.uncertainIndexAt(@intCast(nc[0]), @intCast(nc[1])) orelse continue;
                    if (cluster_of[idx] != none) continue;
                    cluster_of[idx] = clusters;
                    try stack.append(self.gpa, idx);
                }
            }
            clusters += 1;
        }

        // One junction per cluster, at the mean of its distinct spokes.
        const sums = try self.gpa.alloc([3]f64, clusters);
        defer self.gpa.free(sums);
        @memset(sums, .{ 0, 0, 0 });

        // Distinct: an edge interior to the cluster is seen by both of its
        // cells; sort by (cluster, edge) and keep first.
        const Spoke = @TypeOf(self.spokes.items[0]);
        const ctx = struct {
            cluster_of: []const u32,
            fn less(me: @This(), a: Spoke, b: Spoke) bool {
                const ca = me.cluster_of[a.cell];
                const cb = me.cluster_of[b.cell];
                if (ca != cb) return ca < cb;
                return a.edge < b.edge;
            }
        }{ .cluster_of = cluster_of };
        std.mem.sortUnstable(Spoke, self.spokes.items, ctx, @TypeOf(ctx).less);

        var previous: ?struct { cluster: u32, edge: EdgeKey } = null;
        for (self.spokes.items) |spoke| {
            const cluster = cluster_of[spoke.cell];
            if (previous != null and previous.?.cluster == cluster and previous.?.edge == spoke.edge) continue;
            previous = .{ .cluster = cluster, .edge = spoke.edge };
            sums[cluster][0] += spoke.point.x;
            sums[cluster][1] += spoke.point.y;
            sums[cluster][2] += 1;
        }

        previous = null;
        for (self.spokes.items) |spoke| {
            const cluster = cluster_of[spoke.cell];
            if (previous != null and previous.?.cluster == cluster and previous.?.edge == spoke.edge) continue;
            previous = .{ .cluster = cluster, .edge = spoke.edge };
            if (sums[cluster][2] < 2) continue;
            const junction = (@as(u64, 1) << 48) | cluster;
            try self.segments.append(self.gpa, .{ spoke.edge, junction });
        }
        for (0..clusters) |k| {
            if (sums[k][2] < 2) continue;
            try self.found.append(self.gpa, .{
                .edge = (@as(u64, 1) << 48) | @as(u64, @intCast(k)),
                .point = .{ .x = sums[k][0] / sums[k][2], .y = sums[k][1] / sums[k][2] },
            });
        }
    }

    /// A leaf is *ambiguous* (Lin & Yap, paragraph 14) when it satisfies Cxy,
    /// its four corners share a sign, and it still has exactly two vertices.
    /// The two can only sit on one subdivided side, and the curve there may be
    /// one arc or two - the box cannot tell which. Guessing is how the flat
    /// hyperbola of the paper's figure 5 comes out with its two branches joined
    /// into one component; splitting decides it instead. The regression test
    /// "the flat hyperbola stays two components" reproduces exactly that,
    /// and fails if this guard is disabled.
    ///
    /// Reaching this state through the API takes four things at once, which is
    /// why naive fuzzing never finds it: a window making the branch gap's
    /// midline a dyadic cell midline; a hidden band (both branches inside one
    /// cell) longer than the balance cascade radiating from the pinch; a cell
    /// beyond that cascade, coarse itself but with its near side split; and a
    /// relation written so the *interval* derivative is tight - the factored
    /// `(cy+x)(cy-x)` hides Cx behind interval dependency (its product-rule
    /// derivative encloses `[-50, 34]` where the true range is `[-10, -6]`)
    /// and the cells split fine enough to see the branches before ambiguity
    /// can arise. The expanded `c^2 y^2 - x^2` has an exact derivative and
    /// keeps the band coarse.
    fn noteIfAmbiguous(self: *Tree, cell: Cell, corners: Corners, count: u8) !void {
        if (count != 2) return;
        const sign = corners[0] >= 0;
        for (corners[1..]) |value| {
            if ((value >= 0) != sign) return;
        }
        try self.ambiguous.append(self.gpa, cell);
    }

    /// The crossing on the edge from `a` to `b`, if `F` changes sign along it.
    fn crossing(self: *Tree, a: [2]u32, fa: f64, b: [2]u32, fb: f64, side: u2) ?Crossing {
        if (std.math.isNan(fa) or std.math.isNan(fb)) return null;
        if ((fa >= 0) == (fb >= 0)) return null;

        const vertical = a[0] == b[0];
        const lo: [2]u32 = .{ @min(a[0], b[0]), @min(a[1], b[1]) };
        const length = if (vertical) @max(a[1], b[1]) - lo[1] else @max(a[0], b[0]) - lo[0];

        // The paper places the vertex at the midpoint of the edge; interpolating
        // is closer to the curve, and the isotopy argument needs only that the
        // vertex lie somewhere on the edge.
        const t = std.math.clamp((0 - fa) / (fb - fa), 0.0, 1.0);
        const ax = self.xAt(a[0]);
        const ay = self.yAt(a[1]);
        return .{
            .edge = edgeKey(lo, length, vertical),
            .point = .{
                .x = ax + t * (self.xAt(b[0]) - ax),
                .y = ay + t * (self.yAt(b[1]) - ay),
            },
            .side = side,
        };
    }

    /// Join the crossings around one leaf - step 11 of the paper.
    ///
    /// Inside a finished cell the curve is a single monotone arc, so the
    /// boundary carries two crossings, or four when the arc leaves and re-enters
    /// through the same side. In the four case the paper pairs the two sharing a
    /// side each with one of the others. A side's edges are consecutive in
    /// boundary order, so that pair is adjacent, and it is enough to rotate the
    /// cyclic order until the shared pair straddles the middle.
    fn connect(self: *Tree, boundary: []const Crossing) !void {
        for (boundary) |c| try self.found.append(self.gpa, .{ .edge = c.edge, .point = c.point });
        if (boundary.len < 2) return;

        var offset: usize = 0;
        if (boundary.len == 4) {
            for (0..4) |i| {
                if (boundary[i].side == boundary[(i + 1) % 4].side) {
                    offset = (i + 3) % 4;
                    break;
                }
            }
        }

        var k: usize = 0;
        while (k + 1 < boundary.len) : (k += 2) {
            const a = boundary[(k + offset) % boundary.len].edge;
            const b = boundary[(k + 1 + offset) % boundary.len].edge;
            try self.segments.append(self.gpa, .{ a, b });
        }
    }
};

/// Trace `rel`'s curve over `rect`. Caller owns the result.
///
/// A `Rect` and not a `plot.View`: tracing needs the four bounds and nothing
/// else - resolution lives in `Options.min_depth` - and the two front ends are
/// siblings over `relation`, not layers of each other.
pub fn trace(gpa: std.mem.Allocator, rel: *const Relation, rect: Rect, opts: Options) !Curves {
    std.debug.assert(rect.x0 < rect.x1 and rect.y0 < rect.y1);

    var tree = try Tree.init(gpa, rel, rect, opts.maxDepth());
    defer tree.deinit();

    const root: Cell = .{ .x = 0, .y = 0, .size = tree.span };
    try tree.nodes.append(gpa, .{});
    try tree.subdivide(0, root, tree.classifyOne(root), 0, opts);
    try tree.balance(opts);

    var ix: [8]u32 = undefined;
    var iy: [8]u32 = undefined;
    for (0..4) |k| {
        const at = root.corner(@intCast(k));
        ix[k] = at[0];
        iy[k] = at[1];
    }
    for (4..8) |k| {
        ix[k] = root.x;
        iy[k] = root.y;
    }
    const corners = tree.valuesAt(ix, iy);
    tree.min_cell_size = tree.span >> opts.maxDepth();

    // Lin & Yap's CONSTRUCT+ splits ambiguous boxes while it builds the graph,
    // ordering the work by box width so that a split never invalidates a box it
    // has already emitted. Their proof ends by observing that the result equals
    // running the plain construction on the tree that process leaves behind, so
    // splitting to a fixpoint first and constructing once is the same graph with
    // none of the priority queue.
    var round: u8 = 0;
    while (round < 24) : (round += 1) {
        tree.ambiguous.clearRetainingCapacity();
        tree.sortUncertain();
        try tree.emit(.scan, 0, root, corners[0..4].*);
        if (tree.ambiguous.items.len == 0) break;

        var split_any = false;
        for (tree.ambiguous.items) |cell| {
            const depth = @as(u5, @intCast(@ctz(tree.span) - @ctz(cell.size)));
            if (depth >= opts.maxDepth() or cell.size <= 1) {
                // Nowhere left to split: say so rather than guess.
                tree.uncertain += 1;
                continue;
            }
            const index = tree.nodeAt(cell.x, cell.y, cell.size) orelse continue;
            if (!tree.isLeaf(index)) continue;
            try tree.splitInto(index, cell, depth, opts);
            split_any = true;
        }
        if (!split_any) break;
        // A split can leave a neighbour two levels coarser, which the connection
        // rules are not proved for.
        try tree.balance(opts);
    }

    tree.join_uncertain = opts.uncertain == .join;
    tree.sortUncertain();
    try tree.emit(.emit, 0, root, corners[0..4].*);
    if (tree.join_uncertain) try tree.joinClusters();
    return weld(gpa, tree.found.items, tree.segments.items, tree.uncertain);
}

/// Turn per-leaf crossings into a graph. Two leaves sharing an edge appended the
/// same key, so sorting by key and taking each run once both removes the
/// duplicates and numbers what is left - a sort of the crossings in place of a
/// hash lookup per side of every leaf.
fn weld(gpa: std.mem.Allocator, found: []Found, segments: []const [2]EdgeKey, uncertain: u32) !Curves {
    std.mem.sortUnstable(Found, found, {}, lessByEdge);

    var keys: std.ArrayList(EdgeKey) = .empty;
    defer keys.deinit(gpa);
    var points: std.ArrayList(Point) = .empty;
    defer points.deinit(gpa);
    for (found) |entry| {
        if (keys.items.len != 0 and keys.items[keys.items.len - 1] == entry.edge) continue;
        try keys.append(gpa, entry.edge);
        try points.append(gpa, entry.point);
    }

    // Adjacency in CSR form. Vertices are almost all degree <= 2, but a `.join`
    // centre has degree 4, so the shape is general: a chain walk consumes
    // *segments*, and a junction is simply a vertex whose segments outnumber
    // one pass through it.
    const vertex_count = keys.items.len;
    const ends = try gpa.alloc([2]u32, segments.len);
    defer gpa.free(ends);
    const degree = try gpa.alloc(u32, vertex_count);
    defer gpa.free(degree);
    @memset(degree, 0);
    for (segments, 0..) |segment, i| {
        ends[i] = .{ indexOf(keys.items, segment[0]), indexOf(keys.items, segment[1]) };
        degree[ends[i][0]] += 1;
        degree[ends[i][1]] += 1;
    }

    const offsets = try gpa.alloc(u32, vertex_count + 1);
    defer gpa.free(offsets);
    offsets[0] = 0;
    for (0..vertex_count) |v| offsets[v + 1] = offsets[v] + degree[v];

    const adjacent = try gpa.alloc(u32, 2 * segments.len);
    defer gpa.free(adjacent);
    {
        const cursor = try gpa.alloc(u32, vertex_count);
        defer gpa.free(cursor);
        @memset(cursor, 0);
        for (ends, 0..) |e, i| {
            adjacent[offsets[e[0]] + cursor[e[0]]] = @intCast(i);
            cursor[e[0]] += 1;
            adjacent[offsets[e[1]] + cursor[e[1]]] = @intCast(i);
            cursor[e[1]] += 1;
        }
    }

    const used = try gpa.alloc(bool, segments.len);
    defer gpa.free(used);
    @memset(used, false);

    var out_points: std.ArrayList(Point) = .empty;
    errdefer out_points.deinit(gpa);
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(gpa);
    try starts.append(gpa, 0);

    // Open chains first, from odd-degree vertices, so a chain is never entered
    // in the middle and split in two; whatever remains is loops. A loop walk
    // returns to where it began, so first == last holds by construction and the
    // caller can stroke either kind without special-casing.
    for ([2]u8{ 1, 2 }) |pass| {
        for (0..vertex_count) |v0| {
            if (pass == 1 and degree[v0] % 2 == 0) continue;
            while (nextUnused(offsets, adjacent, used, @intCast(v0))) |_| {
                try starts.append(gpa, try walk(gpa, &out_points, points.items, ends, offsets, adjacent, used, @intCast(v0)));
            }
        }
    }

    var curves: Curves = .{
        .points = try out_points.toOwnedSlice(gpa),
        .starts = try starts.toOwnedSlice(gpa),
        .uncertain = uncertain,
    };
    _ = &curves;
    return curves;
}

fn nextUnused(offsets: []const u32, adjacent: []const u32, used: []const bool, v: u32) ?u32 {
    for (adjacent[offsets[v]..offsets[v + 1]]) |seg| {
        if (!used[seg]) return seg;
    }
    return null;
}

/// Consume segments from `v0` until stuck; returns the new end offset.
fn walk(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Point),
    point_of: []const Point,
    ends: []const [2]u32,
    offsets: []const u32,
    adjacent: []const u32,
    used: []bool,
    v0: u32,
) !u32 {
    var current = v0;
    try out.append(gpa, point_of[current]);
    while (nextUnused(offsets, adjacent, used, current)) |seg| {
        used[seg] = true;
        current = if (ends[seg][0] == current) ends[seg][1] else ends[seg][0];
        try out.append(gpa, point_of[current]);
    }
    return @intCast(out.items.len);
}

fn lessByEdge(_: void, a: Found, b: Found) bool {
    return a.edge < b.edge;
}

fn orderEdge(context: EdgeKey, item: EdgeKey) std.math.Order {
    return std.math.order(context, item);
}

fn indexOf(keys: []const EdgeKey, key: EdgeKey) u32 {
    return @intCast(std.sort.binarySearch(EdgeKey, keys, key, orderEdge).?);
}

const testing = std.testing;

fn traceSource(gpa: std.mem.Allocator, source: []const u8, rect: Rect, opts: Options) !Curves {
    const parse = @import("parse.zig");
    var diagnostic: parse.Diagnostic = .{};
    var rel = try parse.relationFrom(gpa, source, &diagnostic);
    defer rel.deinit(gpa);
    return trace(gpa, &rel, rect, opts);
}

fn square(r: f64) Rect {
    return .{ .x0 = -r, .x1 = r, .y0 = -r, .y1 = r };
}

fn isClosed(chain: []const Point) bool {
    return chain.len > 2 and chain[0].x == chain[chain.len - 1].x and chain[0].y == chain[chain.len - 1].y;
}

test "a circle is one closed loop, on the circle" {
    var curves = try traceSource(testing.allocator, "x^2 + y^2 = 0.64", square(1), .{ .min_depth = 7 });
    defer curves.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), curves.uncertain);
    try testing.expectEqual(@as(usize, 1), curves.len());
    const loop = curves.chain(0);
    try testing.expect(isClosed(loop));
    for (loop) |p| try testing.expect(@abs(@sqrt(p.x * p.x + p.y * p.y) - 0.8) < 1e-2);
}

test "disjoint components stay disjoint" {
    var curves = try traceSource(
        testing.allocator,
        "(x^2 + y^2 - 4) * (x^2 + y^2 - 1) = 0",
        square(3),
        .{ .min_depth = 6 },
    );
    defer curves.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), curves.len());
    var radii: [2]f64 = undefined;
    for (0..2) |k| {
        const loop = curves.chain(k);
        try testing.expect(isClosed(loop));
        radii[k] = @sqrt(loop[0].x * loop[0].x + loop[0].y * loop[0].y);
        const target: f64 = if (radii[k] > 1.5) 2 else 1;
        for (loop) |p| try testing.expect(@abs(@sqrt(p.x * p.x + p.y * p.y) - target) < 1e-2);
    }
    try testing.expect(@abs(radii[0] - radii[1]) > 0.5);
}

test "min_depth buys accuracy, and the tree charges only where the curve is" {
    var previous: f64 = 1;
    for ([_]u5{ 4, 5, 6, 7 }) |depth| {
        var curves = try traceSource(testing.allocator, "x^2 + y^2 = 1", square(2), .{ .min_depth = depth });
        defer curves.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), curves.len());

        var worst: f64 = 0;
        for (curves.chain(0)) |p| worst = @max(worst, @abs(@sqrt(p.x * p.x + p.y * p.y) - 1));
        try testing.expect(worst < previous / 3);
        previous = worst;
    }
}

test "a pole is not traced through" {
    var curves = try traceSource(testing.allocator, "y = tan(4*x)", square(1), .{ .min_depth = 6 });
    defer curves.deinit(testing.allocator);

    try testing.expect(curves.len() > 0);
    // Distance to the curve, not the residual: |f| grows with the slope.
    for (0..curves.len()) |k| {
        for (curves.chain(k)) |p| {
            const secant_squared = 1.0 / (@cos(4 * p.x) * @cos(4 * p.x));
            const gradient = @sqrt(1 + 16 * secant_squared * secant_squared);
            try testing.expect(@abs(p.y - @tan(4 * p.x)) / gradient < 1e-2);
        }
    }
}

test "an open curve is an open chain" {
    var curves = try traceSource(testing.allocator, "y = x", square(1), .{ .min_depth = 5 });
    defer curves.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), curves.len());
    const line = curves.chain(0);
    try testing.expect(!isClosed(line));
    for (line) |p| try testing.expect(@abs(p.y - p.x) < 1e-9);
}

test "no curve means no chains" {
    var curves = try traceSource(testing.allocator, "x^2 + y^2 = 100", square(1), .{ .min_depth = 5 });
    defer curves.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), curves.len());
}

test "the tree is adaptive, not a grid in disguise" {
    const parse = @import("parse.zig");
    var diagnostic: parse.Diagnostic = .{};
    var rel = try parse.relationFrom(testing.allocator, "x^2 + y^2 = 1", &diagnostic);
    defer rel.deinit(testing.allocator);

    const opts: Options = .{ .min_depth = 8, .extra_depth = 0 };
    var tree = try Tree.init(testing.allocator, &rel, square(8), opts.maxDepth());
    defer tree.deinit();
    const root: Cell = .{ .x = 0, .y = 0, .size = tree.span };
    try tree.nodes.append(testing.allocator, .{});
    try tree.subdivide(0, root, tree.classifyOne(root), 0, opts);
    try tree.balance(opts);

    // A uniform 256 by 256 grid would be 65536 cells.
    try testing.expect(tree.nodes.items.len < 65536 / 20);
}

test "resolves a curve finer than the coarse grid, without being told where" {
    var curves = try traceSource(
        testing.allocator,
        "(y - 0.01) * (y + 0.01) = 0",
        square(2),
        .{ .min_depth = 7 },
    );
    defer curves.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), curves.len());
    for (0..2) |k| {
        const arc = curves.chain(k);
        const level = arc[0].y;
        try testing.expect(@abs(@abs(level) - 0.01) < 1e-3);
        for (arc) |p| try testing.expect(@abs(p.y - level) < 1e-3);
    }
}

test "a self-intersection is reported rather than silently mangled" {
    var curves = try traceSource(
        testing.allocator,
        "(x^2+y^2)^2 = x^2 - y^2",
        square(1.2),
        .{ .min_depth = 6 },
    );
    defer curves.deinit(testing.allocator);

    try testing.expect(curves.uncertain > 0);
    try testing.expect(curves.len() > 0);
}

test "the flat hyperbola stays two components (Lin & Yap figure 5)" {
    // The one known input that reaches the ambiguous-box guard; with the guard
    // disabled this returns ONE chain, the two branches wrongly joined through
    // cells that hide both. Every ingredient is load-bearing: the window makes
    // y = 0 the midline of the depth-3 cells, the hidden band outruns the
    // balance cascade from the pinch at the origin, and the polynomial is
    // EXPANDED - factored, interval dependency spoils the Cx enclosure and the
    // band splits fine before ambiguity can arise (see `noteIfAmbiguous`).
    var curves = try traceSource(
        testing.allocator,
        "400*y^2 - x^2 = 1",
        .{ .x0 = -5, .x1 = 11, .y0 = -1, .y1 = 15 },
        .{ .min_depth = 3, .extra_depth = 5 },
    );
    defer curves.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), curves.len());
    for (0..2) |k| {
        const branch = curves.chain(k);
        try testing.expect(!isClosed(branch));
        // Entirely on one side of the axis. That is the guarded fact: with the
        // guard off the single wrong chain crosses y = 0. No residual check -
        // vertices are linear interpolations along 2-unit edges of a function
        // with curvature 400, so pointwise accuracy is not what depth-3 cells
        // promise; the topology is.
        const above = branch[0].y > 0;
        for (branch) |p| try testing.expectEqual(above, p.y > 0);
    }
}

test "uncertain policy: join puts a junction at a genuine crossing" {
    // sin(x^2+y^2) - cos(x y) = 2 cos((x^2+y^2-xy)/2 + pi/4) sin((x^2+y^2+xy)/2 - pi/4):
    // the zero set is a union of two ellipse families, so every family-to-family
    // meeting is a REAL intersection - computable exactly from the identity.
    // s = x^2+y^2 = pi/2 + (a+b)pi, p = xy = (b-a)pi with a=0,b=1 gives the
    // crossing used below. Subdivision alone cannot certify it (grad f = 0), so
    // the two policies differ exactly there.
    const crossing_x = 3.2103554079703436;
    const crossing_y = 1.9571089010441704;
    const source = "sin(x^2 + y^2) = cos(x*y)";
    const rect: Rect = .{ .x0 = -8, .x1 = 8, .y0 = -8, .y1 = 8 };
    const cell = 16.0 / 512.0; // min_depth 7 + extra 2

    var avoided = try traceSource(testing.allocator, source, rect, .{ .min_depth = 7 });
    defer avoided.deinit(testing.allocator);
    var joined = try traceSource(testing.allocator, source, rect, .{ .min_depth = 7, .uncertain = .join });
    defer joined.deinit(testing.allocator);

    try testing.expect(avoided.uncertain > 0);
    try testing.expectEqual(avoided.uncertain, joined.uncertain);

    const nearest = struct {
        fn to(curves: *const Curves, x: f64, y: f64) f64 {
            var best: f64 = 1e9;
            for (curves.points) |p| {
                best = @min(best, @sqrt((p.x - x) * (p.x - x) + (p.y - y) * (p.y - y)));
            }
            return best;
        }
    }.to;

    // `.avoid` pulls back from the singular point; `.join` puts a junction
    // vertex essentially on it, and shared by the arcs that meet there.
    const gap_avoided = nearest(&avoided, crossing_x, crossing_y);
    const gap_joined = nearest(&joined, crossing_x, crossing_y);
    try testing.expect(gap_avoided > cell / 4.0);
    try testing.expect(gap_joined < cell / 4.0);
    try testing.expect(gap_joined < gap_avoided);

    // The junction is one point on multiple chains: the X is combinatorially
    // joined, not merely two arcs drawn close.
    var sharing: usize = 0;
    for (0..joined.len()) |k| {
        for (joined.chain(k)) |p| {
            if (@abs(p.x - crossing_x) < cell / 4.0 and @abs(p.y - crossing_y) < cell / 4.0) {
                sharing += 1;
                break;
            }
        }
    }
    try testing.expect(sharing >= 2);
}

test "an asymptote is never drawn" {
    // Four poles of tan cross this window. A cell containing one sees corner
    // signs that differ across the jump, and interpolating that fabricates a
    // 513-point vertical chain straight down the asymptote - which is exactly
    // what this regression looked like before jump cells were refused. The
    // nearest true curve point to any pole is where the branch leaves the
    // window: |x - pole| = pi/2 - arctan(4) = 0.2450.
    var curves = try traceSource(
        testing.allocator,
        "y = tan(x)",
        .{ .x0 = -5, .x1 = 5, .y0 = -4, .y1 = 4 },
        .{ .min_depth = 7 },
    );
    defer curves.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), curves.len());
    // The pole columns are still counted: nothing was certified there.
    try testing.expect(curves.uncertain > 0);

    const half_pi = std.math.pi / 2.0;
    for (curves.points) |p| {
        var nearest: f64 = 1e9;
        for ([_]f64{ -3 * half_pi, -half_pi, half_pi, 3 * half_pi }) |pole| {
            nearest = @min(nearest, @abs(p.x - pole));
        }
        try testing.expect(nearest > 0.2);
    }
}
