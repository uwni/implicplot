//! A PNG encoder for exactly the image this program produces: two colours,
//! one bit per pixel.
//!
//! Colour type 3 (indexed) at bit depth 1 has a scanline format identical to
//! `raster.Raster`'s rows, so encoding is a filter byte plus a `memcpy` per
//! row, and the output of a 2048x2048 plot is a few tens of kilobytes.
//!
//! The JavaScript original reached for a canvas library to do this; here it is
//! a hundred lines over `std.compress.flate` and `std.hash.crc`.

const std = @import("std");
const flate = std.compress.flate;
const Raster = @import("raster.zig").Raster;

pub const Palette = struct {
    background: [3]u8 = .{ 0xff, 0xff, 0xff },
    foreground: [3]u8 = .{ 0x00, 0x78, 0xd4 },
};

const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    var crc = std.hash.crc.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeAll(kind);
    try w.writeAll(data);
    try w.writeInt(u32, crc.final(), .big);
}

pub fn write(gpa: std.mem.Allocator, w: *std.Io.Writer, raster: Raster, palette: Palette) !void {
    try w.writeAll(&signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], raster.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], raster.height, .big);
    ihdr[8] = 1; // bit depth
    ihdr[9] = 3; // colour type: indexed
    ihdr[10] = 0; // compression: deflate
    ihdr[11] = 0; // filter: adaptive
    ihdr[12] = 0; // interlace: none
    try chunk(w, "IHDR", &ihdr);

    try chunk(w, "PLTE", &(palette.background ++ palette.foreground));

    const idat = try deflateScanlines(gpa, raster);
    defer gpa.free(idat);
    try chunk(w, "IDAT", idat);

    try chunk(w, "IEND", "");
}

fn deflateScanlines(gpa: std.mem.Allocator, raster: Raster) ![]u8 {
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    errdefer out.deinit();

    var compress = try flate.Compress.init(&out.writer, window, .zlib, .level_6);
    var y: u32 = 0;
    while (y < raster.height) : (y += 1) {
        try compress.writer.writeByte(0); // filter type: none
        try compress.writer.writeAll(raster.row(y));
    }
    try compress.finish();

    return out.toOwnedSlice();
}

const testing = std.testing;

const Header = struct { width: u32, height: u32, depth: u8, color: u8, chunks: usize };

/// Walks the chunk structure, verifying every CRC, and returns the IHDR.
fn parseAndVerify(bytes: []const u8) !Header {
    try testing.expectEqualSlices(u8, &signature, bytes[0..8]);
    var i: usize = 8;
    var out: Header = undefined;
    out.chunks = 0;
    var saw_end = false;
    while (i < bytes.len) {
        const len = std.mem.readInt(u32, bytes[i..][0..4], .big);
        const kind = bytes[i + 4 ..][0..4];
        const data = bytes[i + 8 ..][0..len];
        const want = std.mem.readInt(u32, bytes[i + 8 + len ..][0..4], .big);

        var crc = std.hash.crc.Crc32.init();
        crc.update(kind);
        crc.update(data);
        try testing.expectEqual(want, crc.final());

        if (std.mem.eql(u8, kind, "IHDR")) {
            out.width = std.mem.readInt(u32, data[0..4], .big);
            out.height = std.mem.readInt(u32, data[4..8], .big);
            out.depth = data[8];
            out.color = data[9];
        }
        if (std.mem.eql(u8, kind, "IEND")) saw_end = true;
        out.chunks += 1;
        i += 12 + len;
    }
    try testing.expect(saw_end);
    try testing.expectEqual(bytes.len, i);
    return out;
}

test "encodes a structurally valid indexed 1-bit png" {
    var raster = try Raster.init(testing.allocator, 61, 23);
    defer raster.deinit(testing.allocator);
    raster.fill(4, 3, 60, 20);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(testing.allocator, &out.writer, raster, .{});

    const bytes = out.writer.buffered();
    const header = try parseAndVerify(bytes);
    try testing.expectEqual(@as(u32, 61), header.width);
    try testing.expectEqual(@as(u32, 23), header.height);
    try testing.expectEqual(@as(u8, 1), header.depth);
    try testing.expectEqual(@as(u8, 3), header.color);
    try testing.expectEqual(@as(usize, 4), header.chunks); // IHDR PLTE IDAT IEND
}

test "scanlines survive a zlib round trip" {
    var raster = try Raster.init(testing.allocator, 40, 8);
    defer raster.deinit(testing.allocator);
    raster.fill(1, 1, 39, 7);

    const idat = try deflateScanlines(testing.allocator, raster);
    defer testing.allocator.free(idat);

    var reader: std.Io.Reader = .fixed(idat);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&reader, .zlib, &window);
    const plain = try decompress.reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(plain);

    try testing.expectEqual(@as(usize, raster.height * (raster.stride + 1)), plain.len);
    var y: u32 = 0;
    while (y < raster.height) : (y += 1) {
        const line = plain[y * (raster.stride + 1) ..][0 .. raster.stride + 1];
        try testing.expectEqual(@as(u8, 0), line[0]);
        try testing.expectEqualSlices(u8, raster.row(y), line[1..]);
    }
}
