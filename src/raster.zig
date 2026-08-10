//! A 1-bit-per-pixel raster with byte-aligned rows.
//!
//! Two properties are load-bearing:
//!
//!   * **Rows never share a byte.** Workers own disjoint row ranges, so they
//!     can write concurrently without atomics and without false sharing at the
//!     granularity that matters for correctness. A packed bitmap without row
//!     padding would let two workers read-modify-write the same byte.
//!   * **A row is already a PNG scanline.** `png.zig` emits colour type 3 at
//!     bit depth 1, whose scanline format is exactly this, so the image is
//!     written without a conversion pass.

const std = @import("std");

pub const Raster = struct {
    width: u32,
    height: u32,
    /// Bytes per row, `ceil(width / 8)`.
    stride: u32,
    bits: []u8,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) !Raster {
        const stride = (width + 7) / 8;
        const bits = try gpa.alloc(u8, @as(usize, stride) * height);
        @memset(bits, 0);
        return .{ .width = width, .height = height, .stride = stride, .bits = bits };
    }

    pub fn deinit(self: *Raster, gpa: std.mem.Allocator) void {
        gpa.free(self.bits);
        self.* = undefined;
    }

    pub fn row(self: Raster, y: u32) []u8 {
        const start = @as(usize, self.stride) * y;
        return self.bits[start..][0..self.stride];
    }

    pub fn isSet(self: Raster, x: u32, y: u32) bool {
        return self.row(y)[x >> 3] & (@as(u8, 0x80) >> @intCast(x & 7)) != 0;
    }

    pub fn set(self: Raster, x: u32, y: u32) void {
        self.row(y)[x >> 3] |= @as(u8, 0x80) >> @intCast(x & 7);
    }

    /// Set pixels `[x0, x1)` of row `y` with byte-wide masks rather than one
    /// shift per pixel.
    pub fn fillRow(self: Raster, y: u32, x0: u32, x1: u32) void {
        if (x1 <= x0) return;
        std.debug.assert(x1 <= self.width);
        const r = self.row(y);
        const first = x0 >> 3;
        const last = (x1 - 1) >> 3;
        const head: u8 = @as(u8, 0xFF) >> @intCast(x0 & 7);
        const tail: u8 = @as(u8, 0xFF) << @intCast(7 - ((x1 - 1) & 7));
        if (first == last) {
            r[first] |= head & tail;
        } else {
            r[first] |= head;
            if (last > first + 1) @memset(r[first + 1 .. last], 0xFF);
            r[last] |= tail;
        }
    }

    /// Set the half-open pixel rectangle `[x0, x1) x [y0, y1)`.
    pub fn fill(self: Raster, x0: u32, y0: u32, x1: u32, y1: u32) void {
        var y = y0;
        while (y < y1) : (y += 1) self.fillRow(y, x0, x1);
    }

    pub fn count(self: Raster) usize {
        var total: usize = 0;
        for (self.bits) |byte| total += @popCount(byte);
        return total;
    }

    /// Render as ASCII art. Rows are emitted top-first, matching the raster.
    pub fn writeAscii(self: Raster, w: *std.Io.Writer) !void {
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) try w.writeByte(if (self.isSet(x, y)) '#' else '.');
            try w.writeByte('\n');
        }
    }
};

const testing = std.testing;

test "fill covers exactly the requested rectangle" {
    var r = try Raster.init(testing.allocator, 37, 11);
    defer r.deinit(testing.allocator);

    r.fill(3, 2, 30, 9);
    var y: u32 = 0;
    while (y < r.height) : (y += 1) {
        var x: u32 = 0;
        while (x < r.width) : (x += 1) {
            const want = x >= 3 and x < 30 and y >= 2 and y < 9;
            try testing.expectEqual(want, r.isSet(x, y));
        }
    }
    try testing.expectEqual(@as(usize, 27 * 7), r.count());
}

test "single-byte and cross-byte spans" {
    var r = try Raster.init(testing.allocator, 24, 1);
    defer r.deinit(testing.allocator);
    r.fillRow(0, 2, 5);
    try testing.expectEqual(@as(u8, 0b00111000), r.row(0)[0]);
    r.fillRow(0, 7, 17);
    try testing.expectEqual(@as(u8, 0b00111001), r.row(0)[0]);
    try testing.expectEqual(@as(u8, 0xFF), r.row(0)[1]);
    try testing.expectEqual(@as(u8, 0b10000000), r.row(0)[2]);
    try testing.expectEqual(@as(usize, 3 + 10), r.count());
}

test "padding bits past the width stay clear" {
    var r = try Raster.init(testing.allocator, 5, 2);
    defer r.deinit(testing.allocator);
    r.fill(0, 0, 5, 2);
    try testing.expectEqual(@as(u8, 0b11111000), r.row(0)[0]);
    try testing.expectEqual(@as(usize, 10), r.count());
}

test "rows of a raster never share a byte" {
    var r = try Raster.init(testing.allocator, 9, 4);
    defer r.deinit(testing.allocator);
    // Row 0 spills into a second byte; row 1 must start in a fresh one.
    try testing.expectEqual(@as(u32, 2), r.stride);
    r.fill(0, 1, 9, 2);
    try testing.expectEqual(@as(u8, 0), r.row(0)[0]);
    try testing.expectEqual(@as(u8, 0), r.row(0)[1]);
    try testing.expectEqual(@as(u8, 0xFF), r.row(1)[0]);
}
