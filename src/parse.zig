//! A parser for relations written the way people write them:
//! `sin(x^2 + y^2) = cos(x*y)`.
//!
//! The original could only be driven from Zig, by hand-assembling nodes in
//! `main`, which is why its `main` had a hard-coded expression and its command
//! line took no arguments at all.

const std = @import("std");
const expr = @import("expr.zig");
const relation = @import("relation.zig");

pub const Diagnostic = struct {
    /// Byte offset in the source where the problem was found.
    offset: usize = 0,
    message: []const u8 = "",

    /// Render `source` with a caret under the offending byte.
    pub fn report(self: Diagnostic, w: *std.Io.Writer, source: []const u8) !void {
        try w.print("{s}\n  {s}\n  ", .{ self.message, source });
        try w.splatByteAll(' ', self.offset);
        try w.writeAll("^\n");
    }
};

pub const Error = error{ParseFailed} || std.mem.Allocator.Error;

/// Parse `source` into a relation in the normal form `lhs - rhs op 0`.
pub fn relationFrom(gpa: std.mem.Allocator, source: []const u8, diag: ?*Diagnostic) Error!relation.Relation {
    var builder = expr.Builder.init(gpa);
    defer builder.deinit();

    var p: Parser = .{ .src = source, .b = &builder, .diag = diag };
    const lhs = try p.expression();
    const op = try p.relationOp();
    const rhs = try p.expression();
    p.skipSpace();
    if (p.pos != source.len) return p.fail("unexpected trailing input");

    const root = try builder.sub(lhs, rhs);
    return .{ .program = try builder.build(), .root = root, .op = op };
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    b: *expr.Builder,
    diag: ?*Diagnostic,

    fn fail(self: *Parser, message: []const u8) Error {
        if (self.diag) |d| d.* = .{ .offset = @min(self.pos, self.src.len), .message = message };
        return error.ParseFailed;
    }

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos])) self.pos += 1;
    }

    fn peek(self: *Parser) ?u8 {
        self.skipSpace();
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn eat(self: *Parser, c: u8) bool {
        if (self.peek() == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn relationOp(self: *Parser) Error!relation.Op {
        const c = self.peek() orelse return self.fail("expected one of = < <= > >=");
        self.pos += 1;
        switch (c) {
            '=' => {
                _ = self.eat('='); // tolerate `==`
                return .eq;
            },
            '<' => return if (self.eat('=')) .le else .lt,
            '>' => return if (self.eat('=')) .ge else .gt,
            else => {
                self.pos -= 1;
                return self.fail("expected one of = < <= > >=");
            },
        }
    }

    fn expression(self: *Parser) Error!expr.Index {
        var lhs = try self.term();
        while (self.peek()) |c| {
            switch (c) {
                '+' => {
                    self.pos += 1;
                    lhs = try self.b.add(lhs, try self.term());
                },
                '-' => {
                    self.pos += 1;
                    lhs = try self.b.sub(lhs, try self.term());
                },
                else => break,
            }
        }
        return lhs;
    }

    fn term(self: *Parser) Error!expr.Index {
        var lhs = try self.unary();
        while (self.peek()) |c| {
            switch (c) {
                '*' => {
                    self.pos += 1;
                    lhs = try self.b.mul(lhs, try self.unary());
                },
                '/' => {
                    self.pos += 1;
                    lhs = try self.b.div(lhs, try self.unary());
                },
                else => break,
            }
        }
        return lhs;
    }

    fn unary(self: *Parser) Error!expr.Index {
        if (self.eat('-')) return self.b.call(.neg, try self.unary());
        if (self.eat('+')) return self.unary();
        return self.power();
    }

    /// `^` binds tighter than unary minus, so `-x^2` is `-(x^2)`.
    fn power(self: *Parser) Error!expr.Index {
        const base = try self.atom();
        if (!self.eat('^')) return base;
        return self.b.powi(base, try self.integer());
    }

    fn integer(self: *Parser) Error!i32 {
        const negative = self.eat('-');
        if (!negative) _ = self.eat('+');
        self.skipSpace();
        const start = self.pos;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        if (self.pos == start) return self.fail("exponents must be integer literals");
        const magnitude = std.fmt.parseInt(i32, self.src[start..self.pos], 10) catch
            return self.fail("exponent out of range");
        return if (negative) -magnitude else magnitude;
    }

    fn atom(self: *Parser) Error!expr.Index {
        const c = self.peek() orelse return self.fail("unexpected end of input");

        if (c == '(') {
            self.pos += 1;
            const inner = try self.expression();
            if (!self.eat(')')) return self.fail("expected ')'");
            return inner;
        }
        if (std.ascii.isDigit(c) or c == '.') return self.number();
        if (std.ascii.isAlphabetic(c) or c == '_') return self.identifier();
        return self.fail("expected a number, a variable, or a function");
    }

    fn number(self: *Parser) Error!expr.Index {
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const ch = self.src[self.pos];
            if (std.ascii.isDigit(ch) or ch == '.') continue;
            if ((ch == 'e' or ch == 'E') and self.pos > start) {
                // Only consume the `e` if it really introduces an exponent.
                const next = if (self.pos + 1 < self.src.len) self.src[self.pos + 1] else 0;
                const after = if (self.pos + 2 < self.src.len) self.src[self.pos + 2] else 0;
                if (std.ascii.isDigit(next) or ((next == '+' or next == '-') and std.ascii.isDigit(after))) {
                    self.pos += 1;
                    continue;
                }
            }
            break;
        }
        const value = std.fmt.parseFloat(f64, self.src[start..self.pos]) catch
            return self.fail("malformed number");
        return self.b.constant(value);
    }

    fn identifier(self: *Parser) Error!expr.Index {
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const ch = self.src[self.pos];
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') break;
        }
        const name = self.src[start..self.pos];

        if (std.mem.eql(u8, name, "x")) return self.b.x();
        if (std.mem.eql(u8, name, "y")) return self.b.y();
        if (std.mem.eql(u8, name, "pi")) return self.b.constant(std.math.pi);
        if (std.mem.eql(u8, name, "tau")) return self.b.constant(std.math.tau);
        if (std.mem.eql(u8, name, "e")) return self.b.constant(std.math.e);

        const tag = functionTag(name) orelse {
            self.pos = start;
            return self.fail("unknown name");
        };
        if (!self.eat('(')) {
            self.pos = start;
            return self.fail("expected '(' after a function name");
        }
        const arg = try self.expression();
        if (!self.eat(')')) return self.fail("expected ')'");
        return self.b.call(tag, arg);
    }
};

/// The spellings that are not simply the tag's own name.
const aliases = std.StaticStringMap(expr.Tag).initComptime(.{
    .{ "ln", .log },
    .{ "arcsin", .asin },
    .{ "arccos", .acos },
    .{ "arctan", .atan },
});

/// Every unary operator is callable under its own name, so `expr.Tag` is the
/// single source of truth for what the language has: adding an operator there
/// makes it parseable, with no table here to keep in step.
fn functionTag(name: []const u8) ?expr.Tag {
    if (aliases.get(name)) |tag| return tag;
    const tag = std.meta.stringToEnum(expr.Tag, name) orelse return null;
    // `powi` needs an exponent rather than an argument, and nothing of another
    // arity is written `name(arg)`.
    return if (tag.arity() == 1 and tag != .powi) tag else null;
}

const testing = std.testing;

fn evalAt(source: []const u8, x: f64, y: f64) !struct { v: f64, op: relation.Op } {
    const eval = @import("eval.zig");
    const Real = @import("real.zig").Real;
    var rel = try relationFrom(testing.allocator, source, null);
    defer rel.deinit(testing.allocator);
    var e: eval.Evaluator(Real(1)) = try .init(testing.allocator, &rel.program);
    defer e.deinit(testing.allocator);
    return .{ .v = e.eval(rel.root, Real(1).splat(x), Real(1).splat(y)).v[0], .op = rel.op };
}

test "precedence and associativity" {
    try testing.expectApproxEqAbs(@as(f64, 7), (try evalAt("1 + 2*3 = 0", 0, 0)).v, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1), (try evalAt("1 - 2 = 0", 0, 0)).v, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 9), (try evalAt("(1+2)^2 = 0", 0, 0)).v, 1e-12);
    // -x^2 is -(x^2), not (-x)^2
    try testing.expectApproxEqAbs(@as(f64, -9), (try evalAt("-x^2 = 0", 3, 0)).v, 1e-12);
    // subtraction is left associative
    try testing.expectApproxEqAbs(@as(f64, -4), (try evalAt("1 - 2 - 3 = 0", 0, 0)).v, 1e-12);
    // division is left associative
    try testing.expectApproxEqAbs(@as(f64, 2), (try evalAt("8 / 2 / 2 = 0", 0, 0)).v, 1e-12);
}

test "relation operators" {
    try testing.expectEqual(relation.Op.eq, (try evalAt("x = y", 0, 0)).op);
    try testing.expectEqual(relation.Op.eq, (try evalAt("x == y", 0, 0)).op);
    try testing.expectEqual(relation.Op.lt, (try evalAt("x < y", 0, 0)).op);
    try testing.expectEqual(relation.Op.le, (try evalAt("x <= y", 0, 0)).op);
    try testing.expectEqual(relation.Op.gt, (try evalAt("x > y", 0, 0)).op);
    try testing.expectEqual(relation.Op.ge, (try evalAt("x >= y", 0, 0)).op);
}

test "functions, constants and scientific notation" {
    const r = try evalAt("sin(x^2 + y^2) = cos(x*y)", 0.7, -1.3);
    try testing.expectApproxEqAbs(@sin(0.49 + 1.69) - @cos(-0.91), r.v, 1e-12);

    try testing.expectApproxEqAbs(@as(f64, 0), (try evalAt("sin(pi) = 0", 0, 0)).v, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1), (try evalAt("ln(e) = 0", 0, 0)).v, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1.5e3), (try evalAt("1.5e3 = 0", 0, 0)).v, 1e-9);
    // A bare `e` next to an operator is Euler's number, not an exponent marker.
    try testing.expectApproxEqAbs(std.math.e + 1, (try evalAt("e + 1 = 0", 0, 0)).v, 1e-12);
}

test "the relation is normalised to f op 0" {
    var rel = try relationFrom(testing.allocator, "x + 1 = y", null);
    defer rel.deinit(testing.allocator);
    const eval = @import("eval.zig");
    const Real = @import("real.zig").Real;
    var e: eval.Evaluator(Real(1)) = try .init(testing.allocator, &rel.program);
    defer e.deinit(testing.allocator);
    // f(2, 3) = (2 + 1) - 3 = 0
    try testing.expectEqual(@as(f64, 0), e.eval(rel.root, Real(1).splat(2), Real(1).splat(3)).v[0]);
}

test "errors carry a position" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.ParseFailed, relationFrom(testing.allocator, "x + = y", &diag));
    try testing.expectEqual(@as(usize, 4), diag.offset);

    try testing.expectError(error.ParseFailed, relationFrom(testing.allocator, "sin(x", &diag));
    try testing.expectError(error.ParseFailed, relationFrom(testing.allocator, "x + y", &diag));
    try testing.expectError(error.ParseFailed, relationFrom(testing.allocator, "wat(x) = y", &diag));
    try testing.expectError(error.ParseFailed, relationFrom(testing.allocator, "x = y extra", &diag));
    try testing.expectError(error.ParseFailed, relationFrom(testing.allocator, "x^y = 0", &diag));
}

test "hash consing survives parsing" {
    var rel = try relationFrom(testing.allocator, "x*y + x*y = x*y", null);
    defer rel.deinit(testing.allocator);
    // x, y, x*y, x*y+x*y, and the normalising subtraction: five nodes.
    try testing.expectEqual(@as(usize, 5), rel.program.nodes.len);
}
