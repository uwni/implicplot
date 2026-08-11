//! The expression store.
//!
//! An expression is a flat array of nodes in topological order: a node's
//! operands are always at *lower* indices. That single invariant is what lets
//! `eval.zig` evaluate a whole program with one forward loop and no recursion,
//! and it is what makes sharing free - a node reached from two parents is still
//! evaluated exactly once.
//!
//! The original stored the same flat array but walked it recursively from the
//! root, so a shared subexpression was recomputed once per reference. For
//! `sin(x^2+y^2) = cos(x*y)` that is a constant factor; for a deep expression
//! built by an ergonomic API it is exponential.
//!
//! `Builder` maintains the invariant and hash-conses every node, so `b.x()`
//! twice is one node and any repeated subexpression is shared.
//!
//! It deliberately does *not* fold constants. Folding evaluates in plain
//! floating point and stores the result as a `.constant`, which destroys the two
//! things the interval domain exists to track: `sqrt(-1)` would become a NaN
//! constant that reports itself as defined everywhere, and `1/3` would become a
//! degenerate interval that does not contain one third. Both are unsound in the
//! direction that matters - they make the plotter confident. The nodes saved are
//! a handful per program, against an evaluator that already visits each node
//! once, so there was nothing to buy.

const std = @import("std");

/// The operator set, and the whole of the language: every unary tag is
/// callable in source under its own name, so `parse.zig` needs no table of
/// its own and adding an operator here makes it writable at once.
///
/// The tags are unnumbered because nothing outside this program identifies an
/// operator by number - not even the Typst plugin, which is handed source text
/// and parses it.
pub const Tag = enum(u8) {
    // leaves
    constant,
    x,
    y,
    // unary
    neg,
    abs,
    sin,
    cos,
    tan,
    exp,
    sqrt,
    log,
    asin,
    acos,
    atan,
    floor,
    ceil,
    /// unary, with the integer exponent stored in `Node.b`
    powi,
    // binary
    add,
    sub,
    mul,
    div,
    mod,
    min,
    max,

    pub fn arity(tag: Tag) u2 {
        return switch (tag) {
            .constant, .x, .y => 0,
            .neg, .abs, .sin, .cos, .tan, .exp, .sqrt, .log => 1,
            .asin, .acos, .atan, .floor, .ceil, .powi => 1,
            .add, .sub, .mul, .div, .mod, .min, .max => 2,
        };
    }

    /// Whether `name(...)` is how this operator is written. The ones that are
    /// not are the leaves, the four with infix spellings, and `powi`, whose
    /// second operand is an integer literal rather than an expression.
    ///
    /// An exhaustive switch rather than a list: adding a tag above stops the
    /// compiler here until someone says how it is spelled.
    pub fn isCallable(tag: Tag) bool {
        return switch (tag) {
            .constant, .x, .y, .powi, .add, .sub, .mul, .div => false,
            .neg, .abs, .sin, .cos, .tan, .exp, .sqrt, .log => true,
            .asin, .acos, .atan, .floor, .ceil, .mod, .min, .max => true,
        };
    }
};

/// 24 bytes. The original node was 48: it used `?usize` operands, which spend
/// 16 bytes each to encode an absence that `Tag.arity` already determines.
pub const Node = struct {
    /// Only meaningful for `.constant`.
    value: f64 = 0,
    /// First operand, for arity >= 1.
    a: u32 = 0,
    /// Second operand for arity 2; the exponent (bitcast) for `.powi`.
    b: u32 = 0,
    tag: Tag,

    pub fn exponent(node: Node) i32 {
        std.debug.assert(node.tag == .powi);
        return @bitCast(node.b);
    }
};

pub const Index = u32;

/// An owned, immutable program. Node `nodes.len - 1` is not necessarily the
/// root; roots are named by `Index`.
pub const Program = struct {
    nodes: []const Node,

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        gpa.free(self.nodes);
        self.* = undefined;
    }
};

pub const Builder = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    interned: std.AutoHashMapUnmanaged(Key, Index) = .empty,

    const Key = struct { tag: Tag, a: Index, b: Index, bits: u64 };

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Builder) void {
        self.nodes.deinit(self.gpa);
        self.interned.deinit(self.gpa);
        self.* = undefined;
    }

    /// Hands the node array over to a `Program` and resets the builder.
    pub fn build(self: *Builder) !Program {
        const nodes = try self.nodes.toOwnedSlice(self.gpa);
        self.interned.clearRetainingCapacity();
        return .{ .nodes = nodes };
    }

    fn intern(self: *Builder, node: Node) !Index {
        const key: Key = .{ .tag = node.tag, .a = node.a, .b = node.b, .bits = @bitCast(node.value) };
        const gop = try self.interned.getOrPut(self.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        const idx: Index = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, node);
        gop.value_ptr.* = idx;
        return idx;
    }

    pub fn constant(self: *Builder, v: f64) !Index {
        return self.intern(.{ .tag = .constant, .value = v });
    }

    pub fn x(self: *Builder) !Index {
        return self.intern(.{ .tag = .x });
    }

    pub fn y(self: *Builder) !Index {
        return self.intern(.{ .tag = .y });
    }

    pub fn unary(self: *Builder, tag: Tag, a: Index) !Index {
        std.debug.assert(tag.arity() == 1 and tag != .powi);
        return self.intern(.{ .tag = tag, .a = a });
    }

    pub fn binary(self: *Builder, tag: Tag, a: Index, b: Index) !Index {
        std.debug.assert(tag.arity() == 2);
        return self.intern(.{ .tag = tag, .a = a, .b = b });
    }

    /// `x^1` is `x` exactly - no rounding, no change of domain - so collapsing
    /// it is free. Nothing else is folded: see the note above `Builder`.
    pub fn powi(self: *Builder, a: Index, n: i32) !Index {
        if (n == 1) return a;
        return self.intern(.{ .tag = .powi, .a = a, .b = @bitCast(n) });
    }

    // Convenience wrappers, so callers building expressions in Zig read close
    // to the mathematics.
    pub fn add(self: *Builder, a: Index, b: Index) !Index {
        return self.binary(.add, a, b);
    }
    /// `a - 0` is `a` exactly, on every endpoint and in every domain, so
    /// collapsing it is free in the same way `x^1` is. It is worth doing
    /// because normalising `lhs op rhs` to `lhs - rhs op 0` means a relation
    /// already written against zero - which is most of them - would otherwise
    /// carry a subtraction that widens its enclosure by an ulp for nothing.
    ///
    /// Only `+0`. `a - (-0)` is `a + 0`, which is `+0` rather than `-0` when
    /// `a` is `-0` - the one input where dropping the subtraction would change
    /// the value. The parser cannot reach it, because a leading minus becomes
    /// a `neg` node rather than a negative literal, but that is a fact about
    /// `parse.zig`; an identity that holds unconditionally is one nobody has to
    /// re-derive from another file.
    pub fn sub(self: *Builder, a: Index, b: Index) !Index {
        const rhs = self.nodes.items[b];
        if (rhs.tag == .constant and rhs.value == 0 and !std.math.signbit(rhs.value)) return a;
        return self.binary(.sub, a, b);
    }
    pub fn mul(self: *Builder, a: Index, b: Index) !Index {
        return self.binary(.mul, a, b);
    }
    pub fn div(self: *Builder, a: Index, b: Index) !Index {
        return self.binary(.div, a, b);
    }
    pub fn call(self: *Builder, tag: Tag, a: Index) !Index {
        return self.unary(tag, a);
    }
};

const testing = std.testing;

test "operands always precede their parent" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const xi = try b.x();
    const yi = try b.y();
    const s = try b.add(try b.powi(xi, 2), try b.powi(yi, 2));
    const root = try b.call(.sin, s);

    var program = try b.build();
    defer program.deinit(testing.allocator);

    for (program.nodes, 0..) |node, i| {
        switch (node.tag.arity()) {
            0 => {},
            1 => try testing.expect(node.a < i),
            2 => {
                try testing.expect(node.a < i);
                try testing.expect(node.b < i);
            },
            else => unreachable,
        }
    }
    try testing.expectEqual(@as(usize, program.nodes.len - 1), root);
}

test "hash consing shares repeated subexpressions" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const x1 = try b.x();
    const x2 = try b.x();
    try testing.expectEqual(x1, x2);

    const a = try b.mul(x1, try b.y());
    const c = try b.mul(try b.x(), try b.y());
    try testing.expectEqual(a, c);
    try testing.expectEqual(@as(usize, 3), b.nodes.items.len); // x, y, x*y
}

test "constants are not folded, so definedness survives to the interval domain" {
    const Interval = @import("interval.zig").Interval(1);
    const Evaluator = @import("eval.zig").Evaluator;

    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const root = try b.call(.sqrt, try b.constant(-1));
    try testing.expectEqual(Tag.sqrt, b.nodes.items[root].tag);

    var program = try b.build();
    defer program.deinit(testing.allocator);
    var e: Evaluator(Interval) = try .init(testing.allocator, &program);
    defer e.deinit(testing.allocator);

    // Folded through plain floats this would be a NaN constant claiming to be
    // defined everywhere; evaluated as a node it is correctly nowhere defined.
    const v = e.eval(root, Interval.repeat(0, 0), Interval.repeat(0, 0));
    try testing.expectEqual(@import("interval.zig").Decoration.ill, v.decoration(0));
}

test "x^1 collapses to x" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const xi = try b.x();
    try testing.expectEqual(xi, try b.powi(xi, 1));
}

test "subtracting zero collapses, subtracting minus zero does not" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const xi = try b.x();

    try testing.expectEqual(xi, try b.sub(xi, try b.constant(0)));

    // -0 is a different constant, and `a - (-0)` is not `a` for a = -0.
    const minus_zero = try b.sub(xi, try b.constant(-0.0));
    try testing.expectEqual(Tag.sub, b.nodes.items[minus_zero].tag);

    // Nothing else folds: `0 - x` is still a subtraction.
    const flipped = try b.sub(try b.constant(0), xi);
    try testing.expectEqual(Tag.sub, b.nodes.items[flipped].tag);
}
