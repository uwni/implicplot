//! A parser for relations written the way people write them:
//! `sin(x^2 + y^2) = cos(x*y)`.
//!
//! `relationFrom` is the only way in, and a relation is one string with its
//! comparison inside it. Every caller - the command line, the Typst plugin -
//! hands over the same text, so there is one grammar to learn and `f(x) > 1`
//! and `f(x) - 1 > 0` are the same relation written two ways rather than two
//! interfaces.
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

/// Source longer than this is rejected unread. The plugin is fed by untrusted
/// document input, and no relation anyone writes comes close.
pub const max_source = 1 << 16;

/// How deep the recursive descent may go. Every level of parentheses, function
/// call or repeated sign is one level, and each costs a few stack frames -
/// which on `wasm32-freestanding`, with panics compiled out, would otherwise
/// end in a bare trap rather than a message.
pub const max_depth = 256;

fn failAt(diag: ?*Diagnostic, offset: usize, message: []const u8) Error {
    if (diag) |d| d.* = .{ .offset = offset, .message = message };
    return error.ParseFailed;
}

/// The dedicated minus sign, U+2212 - what math mode renders, so it is what
/// pasting a formula out of a document produces, `1e−5` axis labels included.
const minus_sign = "\u{2212}";

/// Parse `source` into a relation in the normal form `lhs - rhs op 0`.
pub fn relationFrom(gpa: std.mem.Allocator, source: []const u8, diag: ?*Diagnostic) Error!relation.Relation {
    if (source.len > max_source) return failAt(diag, 0, "relation too long");

    // U+2212 is `-` everywhere in this grammar, so it is replaced once here
    // rather than recognised at every site a minus may appear. A diagnostic
    // then indexes the replaced text, and that is the more accurate caret:
    // the caret line is drawn in columns, and dropping the two bytes a
    // terminal never shows puts errors after a `−` on the right column.
    var normalized: []u8 = &.{};
    defer gpa.free(normalized);
    var src = source;
    if (std.mem.indexOf(u8, source, minus_sign) != null) {
        normalized = try gpa.alloc(u8, source.len);
        const swaps = std.mem.replace(u8, source, minus_sign, "-", normalized);
        src = normalized[0 .. source.len - swaps * (minus_sign.len - 1)];
    }

    var builder = expr.Builder.init(gpa);
    defer builder.deinit();

    var p: Parser = .{ .src = src, .b = &builder, .diag = diag };
    const lhs = try p.expression();
    const op = try p.comparison();
    const rhs = try p.expression();
    p.skipSpace();
    if (p.pos != src.len) return p.fail("unexpected trailing input");

    const root = try builder.sub(lhs, rhs);
    return .{ .program = try builder.build(), .root = root, .op = op };
}

/// Every comparison the language has, generated from the enum so that this
/// table and `Op.symbol` cannot come to disagree. `getLongestPrefix` matches
/// the longest key first, so `<=` is never read as a `<` with junk after it.
const comparisons = std.StaticStringMap(relation.Op).initComptime(kvs: {
    const ops = std.enums.values(relation.Op);
    var list: [ops.len]struct { []const u8, relation.Op } = undefined;
    for (ops, &list) |op, *kv| kv.* = .{ op.symbol(), op };
    break :kvs list;
});

/// Spelled out from the enum, so the message cannot list a set of operators
/// the parser does not accept.
const expected_comparison = blk: {
    var message: []const u8 = "expected a comparison, one of";
    for (std.enums.values(relation.Op)) |op| message = message ++ " " ++ op.symbol();
    break :blk message;
};

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    b: *expr.Builder,
    diag: ?*Diagnostic,
    /// Nesting of the recursive descent; see `max_depth`.
    depth: u32 = 0,

    fn fail(self: *Parser, message: []const u8) Error {
        return failAt(self.diag, @min(self.pos, self.src.len), message);
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


    fn comparison(self: *Parser) Error!relation.Op {
        self.skipSpace();
        const found = comparisons.getLongestPrefix(self.src[self.pos..]) orelse
            return self.fail(expected_comparison);
        self.pos += found.key.len;
        if (found.value == .eq) _ = self.eat('='); // tolerate `==`
        return found.value;
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
                '%' => {
                    self.pos += 1;
                    lhs = try self.b.binary(.mod, lhs, try self.unary());
                },
                else => break,
            }
        }
        return lhs;
    }

    /// Every descent into a nested expression - a sign, a parenthesis, a
    /// function argument - passes through here, so counting depth here bounds
    /// the whole recursion.
    fn unary(self: *Parser) Error!expr.Index {
        if (self.depth == max_depth) return self.fail("nested too deeply");
        self.depth += 1;
        defer self.depth -= 1;

        if (self.eat('-')) return self.b.unary(.neg, try self.unary());
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

        const first = try self.expression();
        if (tag.arity() == 1) {
            if (self.peek() == ',') return self.fail("this function takes one argument");
            if (!self.eat(')')) return self.fail("expected ')'");
            return self.b.unary(tag, first);
        }

        if (!self.eat(',')) return self.fail("this function takes two arguments, separated by a comma");
        const second = try self.expression();
        if (!self.eat(')')) return self.fail("expected ')'");
        return self.b.binary(tag, first, second);
    }
};

/// The spellings that are not simply the tag's own name. One list, shared by
/// the lookup map and the generated `function_list`.
const alias_list = [_]struct { []const u8, expr.Tag }{
    .{ "ln", .log },
    .{ "arcsin", .asin },
    .{ "arccos", .acos },
    .{ "arctan", .atan },
};

const aliases = std.StaticStringMap(expr.Tag).initComptime(alias_list);

/// Every function the parser accepts, for usage text, generated from the enum
/// and the alias table the same way `expected_comparison` is: help cannot list
/// a set of functions `functionTag` does not resolve. The hand-written list it
/// replaces had already drifted - it never mentioned arcsin/arccos/arctan.
pub const function_list = blk: {
    var unary_names: []const u8 = "";
    var binary_names: []const u8 = "";
    for (std.enums.values(expr.Tag)) |tag| {
        if (!tag.isCallable()) continue;
        var name: []const u8 = @tagName(tag);
        for (alias_list) |kv| {
            if (kv[1] == tag) name = name ++ "/" ++ kv[0];
        }
        switch (tag.arity()) {
            1 => unary_names = unary_names ++ (if (unary_names.len == 0) "" else " ") ++ name,
            2 => binary_names = binary_names ++ (if (binary_names.len == 0) "" else " ") ++ name ++ "(a,b)",
            else => unreachable,
        }
    }
    break :blk unary_names ++ ", and " ++ binary_names;
};

/// Every callable operator is callable under its own name, so `expr.Tag` is
/// the single source of truth for what the language has: adding an operator
/// there makes it writable, with no table here to keep in step. `Tag.isCallable`
/// is the one place that says which spelling an operator gets.
fn functionTag(name: []const u8) ?expr.Tag {
    if (aliases.get(name)) |tag| return tag;
    const tag = std.meta.stringToEnum(expr.Tag, name) orelse return null;
    return if (tag.isCallable()) tag else null;
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

test "moving a term across the comparison changes nothing" {
    const a = testing.allocator;
    const eval = @import("eval.zig");
    const Interval = @import("interval.zig").Interval(1);

    // `f > 1` and `f - 1 > 0` are the same relation, and normalising both to
    // `f op 0` makes them the same computation rather than merely equivalent
    // ones: the second's `- 0` is the identity `Builder.sub` declines, so the
    // two enclose a box *identically* instead of one of them paying a rounding
    // for the detour. Anything less and the choice of spelling would show up
    // in the picture.
    var moved = try relationFrom(a, "x^2 - 1 > 0", null);
    defer moved.deinit(a);
    var direct = try relationFrom(a, "x^2 > 1", null);
    defer direct.deinit(a);

    try testing.expectEqual(direct.op, moved.op);

    var em: eval.Evaluator(Interval) = try .init(a, &moved.program);
    defer em.deinit(a);
    var ed: eval.Evaluator(Interval) = try .init(a, &direct.program);
    defer ed.deinit(a);

    const xs = Interval.repeat(-0.5, 2.25);
    const ys = Interval.repeat(-1, 1);
    const got = em.eval(moved.root, xs, ys);
    const want = ed.eval(direct.root, xs, ys);
    try testing.expectEqual(want.lo[0], got.lo[0]);
    try testing.expectEqual(want.hi[0], got.hi[0]);

    // The written-out zero is interned before `sub` gets to decline it, so it
    // stays in the array as a leaf nothing refers to: one `splat` in the
    // evaluation loop, and no operand of anything.
    try testing.expectEqual(direct.program.nodes.len + 1, moved.program.nodes.len);
}

test "functions of two arguments" {
    try testing.expectApproxEqAbs(@as(f64, 3), (try evalAt("max(x, y) = 0", 3, 1)).v, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), (try evalAt("min(x, y) = 0", 3, 1)).v, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), (try evalAt("floor(x) = 0", 1.7, 0)).v, 1e-12);
    // Nesting and whitespace around the comma.
    try testing.expectApproxEqAbs(@as(f64, 2), (try evalAt("max(min(x,y) , 2) = 0", 1, 5)).v, 1e-12);
}

test "% is floored modulo, at the precedence of * and /" {
    try testing.expectApproxEqAbs(@as(f64, 1), (try evalAt("x % 3 = 0", 7, 0)).v, 1e-12);
    // Floored: the result takes the sign of the divisor, as in Python.
    try testing.expectApproxEqAbs(@as(f64, -2), (try evalAt("x % -3 = 0", 7, 0)).v, 1e-12);
    // Binds like * and /: tighter than +, left-associative among terms.
    try testing.expectApproxEqAbs(@as(f64, 8), (try evalAt("7 + 3 % 2 = 0", 0, 0)).v, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4), (try evalAt("8 % 3 * 2 = 0", 0, 0)).v, 1e-12);
}

test "the dedicated minus sign U+2212 works wherever - does" {
    // Unary, binary, and exponent positions.
    try testing.expectApproxEqAbs(@as(f64, -3), (try evalAt("\u{2212}x = 0", 3, 0)).v, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1), (try evalAt("1 \u{2212} 2 = 0", 0, 0)).v, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -4), (try evalAt("1 \u{2212} 2 \u{2212} 3 = 0", 0, 0)).v, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.25), (try evalAt("2^\u{2212}2 = 0", 0, 0)).v, 1e-12);

    // A scientific literal the way plotting software labels axes (`1e−5`).
    // The constant is bit-identical to the ASCII spelling: the literal is
    // respelled and re-parsed, never computed in pieces.
    try testing.expectEqual(
        (try evalAt("1.5e-3 = 0", 0, 0)).v,
        (try evalAt("1.5e\u{2212}3 = 0", 0, 0)).v,
    );

    // And a whole relation pasted out of a rendered formula parses.
    try testing.expectApproxEqAbs(
        @as(f64, -2.0 + 1.0 / 9.0),
        (try evalAt("\u{2212}2 + 3^\u{2212}2 = 0", 0, 0)).v,
        1e-12,
    );
}

test "the arity in the enum is the arity the parser enforces" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.ParseFailed, relationFrom(testing.allocator, "max(x) = 0", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "two arguments") != null);

    diag = .{};
    try testing.expectError(error.ParseFailed, relationFrom(testing.allocator, "sin(x, y) = 0", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "one argument") != null);

    // The operators that have an infix spelling do not also get a call
    // spelling, so there is one way to write each of them - `mod` included,
    // which is written `%`.
    for ([_][]const u8{ "add(x, y) = 0", "mul(x, y) = 0", "mod(x, 2) = 0", "powi(x, 2) = 0", "constant(1) = 0" }) |source| {
        diag = .{};
        try testing.expectError(error.ParseFailed, relationFrom(testing.allocator, source, &diag));
        try testing.expectEqualStrings("unknown name", diag.message);
    }
}

test "the function list is generated from the enum and the aliases" {
    inline for (comptime std.enums.values(expr.Tag)) |tag| {
        if (comptime tag.isCallable()) {
            try testing.expect(std.mem.indexOf(u8, function_list, @tagName(tag)) != null);
        }
    }
    inline for (alias_list) |kv| {
        try testing.expect(std.mem.indexOf(u8, function_list, kv[0]) != null);
    }
    try testing.expect(std.mem.indexOf(u8, function_list, "log/ln") != null);
    try testing.expect(std.mem.indexOf(u8, function_list, "min(a,b)") != null);
    // `mod` is spelled `%`, so it must NOT be offered as a function.
    try testing.expect(std.mem.indexOf(u8, function_list, "mod") == null);
}

test "the message listing the comparisons is generated from the enum" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.ParseFailed, relationFrom(testing.allocator, "x + y", &diag));
    try testing.expectEqualStrings(expected_comparison, diag.message);
    try testing.expectEqualStrings("expected a comparison, one of = < <= > >=", expected_comparison);

    // Longest match first: `<=` is one comparison, not `<` followed by junk.
    try testing.expectEqual(relation.Op.le, (try evalAt("x <= y", 0, 0)).op);
    try testing.expectEqualStrings("<=", comparisons.getLongestPrefix("<= 0").?.key);
    try testing.expect(comparisons.getLongestPrefix("~ 0") == null);
}

test "nesting is bounded rather than overflowing the stack" {
    const a = testing.allocator;
    const over = max_depth + 1;

    var diag: Diagnostic = .{};
    const nested = ("(" ** over) ++ "x" ++ (")" ** over) ++ " = 0";
    try testing.expectError(error.ParseFailed, relationFrom(a, nested, &diag));
    try testing.expectEqualStrings("nested too deeply", diag.message);

    // A chain of signs recurses without a parenthesis and is bounded too.
    try testing.expectError(error.ParseFailed, relationFrom(a, ("-" ** over) ++ "x = 0", &diag));

    // One level inside the limit still parses.
    const fine = ("(" ** (max_depth - 1)) ++ "x" ++ (")" ** (max_depth - 1)) ++ " = 0";
    var rel = try relationFrom(a, fine, null);
    rel.deinit(a);
}

test "source longer than the cap is rejected unread" {
    const a = testing.allocator;
    const long = try a.alloc(u8, max_source + 1);
    defer a.free(long);
    @memset(long, 'x');

    var diag: Diagnostic = .{};
    try testing.expectError(error.ParseFailed, relationFrom(a, long, &diag));
    try testing.expectEqualStrings("relation too long", diag.message);
}

test "hash consing survives parsing" {
    var rel = try relationFrom(testing.allocator, "x*y + x*y = x*y", null);
    defer rel.deinit(testing.allocator);
    // x, y, x*y, x*y+x*y, and the normalising subtraction: five nodes.
    try testing.expectEqual(@as(usize, 5), rel.program.nodes.len);
}
