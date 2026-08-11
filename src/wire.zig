//! The Typst plugin's wire format, as pure code the host test suite runs.
//!
//! Two layouts cross the wasm boundary: the 42-byte little-endian options
//! header both exports take, and the contour response. `typst/plot.typ`
//! mirrors both in Typst, and this file is the side it mirrors. The length
//! check in `Options.parse` catches an added or removed field, but only the
//! golden-byte tests below notice a reordering: two swapped f64 fields keep
//! the length at 42 and mis-plot silently.
//!
//! `typst_plugin.zig` cannot host these itself - its exports reference the
//! `typst_env` externs, so it only compiles for the plugin target - which is
//! why the codec lives here, inside the library `zig build test` covers.

const std = @import("std");
const plot = @import("plot.zig");
const contour = @import("contour.zig");

/// The most `contour`'s refinement byte may ask for; deeper is clamped, and
/// `plot.typ` asserts the same bound before sending. (`plot`'s depth byte
/// uses the full 0..255.)
pub const max_contour_refine = 10;

/// The `options` argument: little-endian, 42 bytes.
///
/// A packed struct would describe this more directly, but its in-memory layout
/// is not the wire layout on every target, and getting that wrong is silent.
pub const Options = struct {
    pub const size = 4 + 4 + 8 * 4 + 1 + 1;

    view: plot.View,
    /// `plot`: how far a single undecided pixel may be subdivided. `contour`:
    /// how far below `n`'s resolution an unresolved cell may be split.
    depth: u8,
    /// `contour` only: what to draw in cells whose topology could not be
    /// certified. 0 keeps the arcs apart; 1 contracts each uncertain cluster
    /// to a junction, joining everything that meets it - for relations the
    /// caller knows genuinely self-intersect.
    join_uncertain: bool,

    pub fn parse(bytes: []const u8) !Options {
        if (bytes.len != size) return error.BadOptionsLength;
        return .{
            .view = .{
                .width = std.mem.readInt(u32, bytes[0..4], .little),
                .height = std.mem.readInt(u32, bytes[4..8], .little),
                .x_min = readFloat(bytes[8..16]),
                .x_max = readFloat(bytes[16..24]),
                .y_min = readFloat(bytes[24..32]),
                .y_max = readFloat(bytes[32..40]),
            },
            .depth = bytes[40],
            .join_uncertain = switch (bytes[41]) {
                0 => false,
                1 => true,
                else => return error.UnknownUncertainPolicy,
            },
        };
    }

    fn readFloat(bytes: *const [8]u8) f64 {
        return @bitCast(std.mem.readInt(u64, bytes, .little));
    }

    pub fn validate(self: Options) !void {
        if (self.view.width == 0 or self.view.height == 0) return error.EmptyImage;
        if (!(self.view.x_min < self.view.x_max)) return error.EmptyXRange;
        if (!(self.view.y_min < self.view.y_max)) return error.EmptyYRange;
    }

    pub fn pixels(self: Options) u64 {
        return @as(u64, self.view.width) * self.view.height;
    }

    /// A grid of `width` by `height` cells has one more point along each axis.
    pub fn samples(self: Options) u64 {
        return (@as(u64, self.view.width) + 1) * (@as(u64, self.view.height) + 1);
    }
};

/// The contour response, little-endian; caller owns the bytes:
///
/// ```text
///   u32           number of chains
///   u32           cells whose topology is not guaranteed (a singularity)
///   u32 * chains  points in each chain
///   f64 * 2 * n   x, y of every point, chains back to back
/// ```
pub fn encodeCurves(gpa: std.mem.Allocator, curves: contour.Curves) ![]u8 {
    const header = (2 + curves.len()) * @sizeOf(u32);
    const out = try gpa.alloc(u8, header + curves.points.len * 2 * @sizeOf(f64));
    errdefer gpa.free(out);

    std.mem.writeInt(u32, out[0..4], @intCast(curves.len()), .little);
    std.mem.writeInt(u32, out[4..8], curves.uncertain, .little);
    for (0..curves.len()) |k| {
        const length: u32 = curves.starts[k + 1] - curves.starts[k];
        std.mem.writeInt(u32, out[8 + k * 4 ..][0..4], length, .little);
    }

    var written = header;
    for (curves.points) |point| {
        std.mem.writeInt(u64, out[written..][0..8], @bitCast(point.x), .little);
        std.mem.writeInt(u64, out[written + 8 ..][0..8], @bitCast(point.y), .little);
        written += 16;
    }
    return out;
}

const testing = std.testing;

test "the options header decodes the pinned layout" {
    // Hand-written bytes, not round-tripped through the encoder: this is the
    // one place field order and endianness are stated as data, so `plot.typ`
    // drifting from `Options.parse` fails here rather than mis-plotting.
    const bytes = [Options.size]u8{
        3, 0, 0, 0, // width
        5, 0, 0, 0, // height
        0, 0, 0, 0, 0, 0, 0xf8, 0xbf, // x_min = -1.5
        0, 0, 0, 0, 0, 0, 0x04, 0x40, // x_max = 2.5
        0, 0, 0, 0, 0, 0, 0xd0, 0xbf, // y_min = -0.25
        0, 0, 0, 0, 0, 0, 0x10, 0x40, // y_max = 4.0
        7, // depth
        1, // uncertain policy: join
    };
    const options = try Options.parse(&bytes);
    try options.validate();
    try testing.expectEqual(@as(u32, 3), options.view.width);
    try testing.expectEqual(@as(u32, 5), options.view.height);
    try testing.expectEqual(@as(f64, -1.5), options.view.x_min);
    try testing.expectEqual(@as(f64, 2.5), options.view.x_max);
    try testing.expectEqual(@as(f64, -0.25), options.view.y_min);
    try testing.expectEqual(@as(f64, 4.0), options.view.y_max);
    try testing.expectEqual(@as(u8, 7), options.depth);
    try testing.expect(options.join_uncertain);
    try testing.expectEqual(@as(u64, 15), options.pixels());
    try testing.expectEqual(@as(u64, 24), options.samples());
}

test "options parsing rejects what the layout cannot mean" {
    try testing.expectError(error.BadOptionsLength, Options.parse(&[_]u8{0} ** (Options.size - 1)));
    try testing.expectError(error.BadOptionsLength, Options.parse(&[_]u8{0} ** (Options.size + 1)));

    var bytes = [_]u8{0} ** Options.size;
    bytes[41] = 2;
    try testing.expectError(error.UnknownUncertainPolicy, Options.parse(&bytes));
}

test "the contour response encodes the pinned layout" {
    var points = [_]contour.Point{ .{ .x = 1.5, .y = -2.5 }, .{ .x = 0, .y = 1 } };
    var starts = [_]u32{ 0, 1, 2 };
    const curves: contour.Curves = .{ .points = &points, .starts = &starts, .uncertain = 9 };

    const out = try encodeCurves(testing.allocator, curves);
    defer testing.allocator.free(out);

    const expected = [_]u8{
        2, 0, 0, 0, // two chains
        9, 0, 0, 0, // uncertain cells
        1, 0, 0, 0, // first chain: one point
        1, 0, 0, 0, // second chain: one point
        0, 0, 0, 0, 0, 0, 0xf8, 0x3f, // x = 1.5
        0, 0, 0, 0, 0, 0, 0x04, 0xc0, // y = -2.5
        0, 0, 0, 0, 0, 0, 0, 0, // x = 0
        0, 0, 0, 0, 0, 0, 0xf0, 0x3f, // y = 1
    };
    try testing.expectEqualSlices(u8, &expected, out);
}
