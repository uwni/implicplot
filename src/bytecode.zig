//! The wire format the Typst plugin speaks: a relation as a stream of opcodes.
//!
//! A program is postfix. Each instruction is one opcode byte, optionally
//! followed by an immediate operand, and pushes exactly one value:
//!
//! ```text
//!   opcode          immediate            stack
//!   constant   0    f64, 8 bytes LE      push
//!   x          1    -                    push
//!   y          2    -                    push
//!   neg .. atan     -                    pop 1, push 1
//!   powi      14    i32, 4 bytes LE      pop 1, push 1
//!   add .. div      -                    pop 2, push 1
//! ```
//!
//! `sin(x^2 + y^2) - cos(x*y)` is
//! `x powi 2  y powi 2  add  sin  x  y  mul  cos  sub`.
//!
//! Postfix is not a third representation of an expression - it *is* the node
//! array of `expr.zig`, read out in order. Each instruction appends one node,
//! and the operand stack holds node indices, so decoding is a single pass with
//! no tree to build and the topological invariant holds by construction.
//!
//! Clients do not need this file's numbers hard-coded: `writeTable` emits the
//! whole table, generated from the enums themselves, and the Typst side reads
//! it at load time.

const std = @import("std");
const expr = @import("expr.zig");
const interval = @import("interval.zig");
const relation = @import("relation.zig");

pub const Error = error{
    /// An instruction ran off the end of the stream.
    Truncated,
    /// The opcode byte is not an operator.
    UnknownOpcode,
    /// An operator asked for more operands than had been pushed.
    StackUnderflow,
    /// The program did not end with exactly one value on the stack.
    NotOneResult,
    /// The relation opcode is not a comparison.
    UnknownRelation,
    ProgramTooLarge,
} || std.mem.Allocator.Error;

/// Programs this large are certainly a mistake, and the plugin is fed by
/// untrusted document input.
pub const max_instructions = 1 << 16;

/// How many bytes of immediate operand an opcode carries.
pub fn immediateSize(tag: expr.Tag) u8 {
    return switch (tag) {
        .constant => @sizeOf(f64),
        .powi => @sizeOf(i32),
        else => 0,
    };
}

/// Decode a postfix program into a relation `f op 0`.
pub fn decode(gpa: std.mem.Allocator, code: []const u8, op: interval.Op) Error!relation.Relation {
    var builder = expr.Builder.init(gpa);
    defer builder.deinit();

    // One instruction is at least one byte, so the stream length bounds the
    // stack.
    var stack: std.ArrayList(expr.Index) = .empty;
    defer stack.deinit(gpa);
    try stack.ensureTotalCapacity(gpa, @min(code.len, max_instructions) + 1);

    var pos: usize = 0;
    var count: usize = 0;
    while (pos < code.len) : (count += 1) {
        if (count == max_instructions) return error.ProgramTooLarge;

        const tag = std.enums.fromInt(expr.Tag, code[pos]) orelse return error.UnknownOpcode;
        pos += 1;
        const immediate = immediateSize(tag);
        if (code.len - pos < immediate) return error.Truncated;

        if (stack.items.len < tag.arity()) return error.StackUnderflow;
        const operands = stack.items[stack.items.len - tag.arity() ..];

        const node = switch (tag) {
            .constant => try builder.constant(@bitCast(std.mem.readInt(u64, code[pos..][0..8], .little))),
            .x => try builder.x(),
            .y => try builder.y(),
            .powi => try builder.powi(operands[0], std.mem.readInt(i32, code[pos..][0..4], .little)),
            else => switch (tag.arity()) {
                1 => try builder.unary(tag, operands[0]),
                2 => try builder.binary(tag, operands[0], operands[1]),
                else => unreachable,
            },
        };

        pos += immediate;
        stack.shrinkRetainingCapacity(stack.items.len - tag.arity());
        stack.appendAssumeCapacity(node);
    }

    if (stack.items.len != 1) return error.NotOneResult;
    return .{ .program = try builder.build(), .root = stack.items[0], .op = op };
}

/// Emit the opcode table, generated from the enums, so that a client never has
/// to keep a copy of these numbers in step by hand.
///
/// ```text
///   op  <name> <opcode> <arity> <immediate bytes>
///   rel <name> <opcode>
/// ```
pub fn writeTable(w: *std.Io.Writer) std.Io.Writer.Error!void {
    inline for (@typeInfo(expr.Tag).@"enum".fields) |field| {
        const tag: expr.Tag = @enumFromInt(field.value);
        try w.print("op {s} {d} {d} {d}\n", .{ field.name, field.value, tag.arity(), immediateSize(tag) });
    }
    inline for (@typeInfo(interval.Op).@"enum".fields) |field| {
        try w.print("rel {s} {d}\n", .{ field.name, field.value });
    }
}

const testing = std.testing;

// The tests below spell the byte streams out rather than round-tripping through
// an encoder written here: an encoder that shares this file's assumptions would
// certify them instead of checking them.

test "a postfix program decodes to the expected expression" {
    const eval = @import("eval.zig");
    const Real = @import("real.zig").Real;

    // x powi 2 | y powi 2 | add | sin | x | y | mul | cos | sub
    const code = [_]u8{
        1, // x
        14, 2, 0, 0, 0, // powi 2
        2, // y
        14, 2, 0, 0, 0, // powi 2
        15, // add
        5, // sin
        1, // x
        2, // y
        17, // mul
        6, // cos
        16, // sub
    };

    var rel = try decode(testing.allocator, &code, .eq);
    defer rel.deinit(testing.allocator);
    try testing.expectEqual(interval.Op.eq, rel.op);

    var e: eval.Evaluator(Real(1)) = try .init(testing.allocator, &rel.program);
    defer e.deinit(testing.allocator);

    for ([_][2]f64{ .{ 0.3, -1.2 }, .{ 2.0, 0.5 }, .{ -1.0, -1.0 } }) |point| {
        const x = point[0];
        const y = point[1];
        const want = @sin(x * x + y * y) - @cos(x * y);
        const got = e.eval(rel.root, Real(1).splat(x), Real(1).splat(y)).v[0];
        try testing.expectApproxEqAbs(want, got, 1e-12);
    }
}

test "constants carry an eight byte immediate" {
    const eval = @import("eval.zig");
    const Real = @import("real.zig").Real;

    var code: [10]u8 = undefined;
    code[0] = 0; // constant
    std.mem.writeInt(u64, code[1..9], @bitCast(@as(f64, -2.5)), .little);
    code[9] = 3; // neg

    var rel = try decode(testing.allocator, &code, .lt);
    defer rel.deinit(testing.allocator);
    var e: eval.Evaluator(Real(1)) = try .init(testing.allocator, &rel.program);
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 2.5), e.eval(rel.root, Real(1).splat(0), Real(1).splat(0)).v[0]);
}

test "malformed programs are rejected, not misread" {
    const a = testing.allocator;
    try testing.expectError(error.UnknownOpcode, decode(a, &.{200}, .eq));
    try testing.expectError(error.Truncated, decode(a, &.{ 0, 1, 2 }, .eq)); // constant, short immediate
    try testing.expectError(error.Truncated, decode(a, &.{ 1, 14, 0 }, .eq)); // powi, short immediate
    try testing.expectError(error.StackUnderflow, decode(a, &.{15}, .eq)); // add with nothing pushed
    try testing.expectError(error.StackUnderflow, decode(a, &.{ 1, 15 }, .eq)); // add with one operand
    try testing.expectError(error.NotOneResult, decode(a, &.{ 1, 2 }, .eq)); // two values left
    try testing.expectError(error.NotOneResult, decode(a, &.{}, .eq)); // nothing at all
}

test "the emitted table matches the enums" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeTable(&out.writer);
    const table = out.writer.buffered();

    // Spot-check the numbers the format promises to keep stable.
    try testing.expect(std.mem.indexOf(u8, table, "op constant 0 0 8\n") != null);
    try testing.expect(std.mem.indexOf(u8, table, "op x 1 0 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, table, "op powi 14 1 4\n") != null);
    try testing.expect(std.mem.indexOf(u8, table, "op div 18 2 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, table, "rel eq 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, table, "rel ge 4\n") != null);

    // Every operator appears exactly once.
    var lines = std.mem.tokenizeScalar(u8, table, '\n');
    var operators: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "op ")) operators += 1;
    }
    try testing.expectEqual(@typeInfo(expr.Tag).@"enum".fields.len, operators);
}
