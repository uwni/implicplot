//! Typst plugin front end, speaking the
//! [wasm minimal protocol](https://github.com/typst-community/wasm-minimal-protocol).
//!
//! Two exports, both taking the relation as *source text* and parsing it here:
//!
//!   * `plot(relation, options)` returns **one byte per pixel**, row-major from
//!     the top: an 8 by 8 plot comes back as 64 bytes of 0 or 1. Not an image -
//!     the document decides what to draw with it.
//!   * `contour(relation, options)` returns the curve as polylines, for
//!     stroking rather than filling. It reads only `lhs - rhs`, since tracing
//!     asks where that vanishes.
//!
//! The relation is one string, `"sin(x^2 + y^2) = cos(x*y)"`, parsed by the
//! same `parse.zig` the command line uses. Nothing numeric crosses this
//! boundary but the view: no operator has a number the two sides must agree
//! on, and there is no encoder in the document to keep in step.

const std = @import("std");
const irp = @import("implicit_plot");

const gpa = std.heap.wasm_allocator;

pub const panic = std.debug.no_panic;

extern "typst_env" fn wasm_minimal_protocol_send_result_to_host(ptr: [*]const u8, len: usize) void;
extern "typst_env" fn wasm_minimal_protocol_write_args_to_buffer(ptr: [*]u8) void;

fn sendResultToHost(bytes: []const u8) void {
    wasm_minimal_protocol_send_result_to_host(bytes.ptr, bytes.len);
}

const Retval = enum(i32) { success, failure };

/// On failure the protocol expects the result buffer to hold a UTF-8 message,
/// which Typst reports at the call site.
fn fail(message: []const u8) Retval {
    sendResultToHost(message);
    return .failure;
}

/// Where a `ParseFailed` happened, so that the failure message can be the same
/// caret report the command line prints instead of an error name.
///
/// `source` points into the argument buffer, so that buffer has to outlive the
/// call that failed: it is allocated in the export, not in the `Impl` below.
const Failure = struct {
    diagnostic: irp.parse.Diagnostic = .{},
    /// The text `diagnostic.offset` indexes into.
    source: []const u8 = "",

    fn report(self: Failure, err: anyerror) Retval {
        if (err != error.ParseFailed) return fail(@errorName(err));
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        self.diagnostic.report(&out.writer, self.source) catch return fail("out of memory");
        sendResultToHost(out.writer.buffered());
        return .failure;
    }
};

/// The `options` argument: little-endian, 42 bytes.
///
/// A packed struct would describe this more directly, but its in-memory layout
/// is not the wire layout on every target, and getting that wrong is silent.
const Options = struct {
    const size = 4 + 4 + 8 * 4 + 1 + 1;

    view: irp.View,
    /// `plot`: how far a single undecided pixel may be subdivided. `contour`:
    /// how far below `n`'s resolution an unresolved cell may be split.
    depth: u8,
    /// `contour` only: what to draw in cells whose topology could not be
    /// certified. 0 keeps the arcs apart; 1 contracts each uncertain cluster
    /// to a junction, joining everything that meets it - for relations the
    /// caller knows genuinely self-intersect.
    join_uncertain: bool,

    fn parse(bytes: []const u8) !Options {
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

    fn validate(self: Options) !void {
        if (self.view.width == 0 or self.view.height == 0) return error.EmptyImage;
        if (!(self.view.x_min < self.view.x_max)) return error.EmptyXRange;
        if (!(self.view.y_min < self.view.y_max)) return error.EmptyYRange;
    }

    fn pixels(self: Options) u64 {
        return @as(u64, self.view.width) * self.view.height;
    }

    /// A grid of `width` by `height` cells has one more point along each axis.
    fn samples(self: Options) u64 {
        return (@as(u64, self.view.width) + 1) * (@as(u64, self.view.height) + 1);
    }
};

/// The result is one byte per pixel and a document is not a good place to
/// allocate tens of megabytes.
const max_pixels = 1 << 22;

/// `contour` samples a grid of f64, so it gets a tighter cap.
const max_samples = 1 << 20;

/// Which pixels the relation may touch, as one byte each.
export fn plot(relation_len: usize, options_len: usize) Retval {
    const args = gpa.alloc(u8, relation_len + options_len) catch return fail("out of memory");
    defer gpa.free(args);
    wasm_minimal_protocol_write_args_to_buffer(args.ptr);

    var failure: Failure = .{ .source = args[0..relation_len] };
    plotImpl(args[0..relation_len], args[relation_len..], &failure) catch |err|
        return failure.report(err);
    return .success;
}

/// The curve as polylines, for stroking rather than filling.
///
/// The response is little-endian:
///
/// ```text
///   u32           number of chains
///   u32           cells whose topology is not guaranteed (a singularity)
///   u32 * chains  points in each chain
///   f64 * 2 * n   x, y of every point, chains back to back
/// ```
///
/// `width` and `height` are the tracing grid, not pixels.
export fn contour(relation_len: usize, options_len: usize) Retval {
    const args = gpa.alloc(u8, relation_len + options_len) catch return fail("out of memory");
    defer gpa.free(args);
    wasm_minimal_protocol_write_args_to_buffer(args.ptr);

    var failure: Failure = .{ .source = args[0..relation_len] };
    contourImpl(args[0..relation_len], args[relation_len..], &failure) catch |err|
        return failure.report(err);
    return .success;
}

fn plotImpl(source: []const u8, options_bytes: []const u8, failure: *Failure) !void {
    const options = try Options.parse(options_bytes);
    try options.validate();
    if (options.pixels() > max_pixels) return error.ImageTooLarge;

    var relation = try irp.parse.relationFrom(gpa, source, &failure.diagnostic);
    defer relation.deinit(gpa);

    // Freestanding wasm has no threads, so there is nowhere to run strips:
    // `null` renders inline rather than making us stand up an `Io`.
    var raster = try irp.render(gpa, null, &relation, .{
        .view = options.view,
        .subpixel_depth = options.depth,
    });
    defer raster.deinit(gpa);

    const pixels = try gpa.alloc(u8, @as(usize, options.view.width) * options.view.height);
    defer gpa.free(pixels);
    var i: usize = 0;
    var y: u32 = 0;
    while (y < raster.height) : (y += 1) {
        var x: u32 = 0;
        while (x < raster.width) : (x += 1) {
            pixels[i] = @intFromBool(raster.isSet(x, y));
            i += 1;
        }
    }

    sendResultToHost(pixels);
}

fn contourImpl(source: []const u8, options_bytes: []const u8, failure: *Failure) !void {
    const options = try Options.parse(options_bytes);
    try options.validate();
    if (options.samples() > max_samples) return error.GridTooLarge;

    // Whatever comparison the relation was written with, tracing answers where
    // `lhs - rhs` vanishes: `relation.op` is simply never read below.
    var relation = try irp.parse.relationFrom(gpa, source, &failure.diagnostic);
    defer relation.deinit(gpa);

    // `width` is a resolution request, not a grid: the tree splits at least
    // that far where the curve runs, and stops at once where it does not.
    const across = @max(options.view.width, options.view.height);
    var curves = try irp.contour.trace(gpa, &relation, options.view, .{
        .min_depth = @intCast(@min(16, std.math.log2_int_ceil(u32, @max(2, across)))),
        .extra_depth = @intCast(@min(options.depth, 10)),
        .uncertain = if (options.join_uncertain) .join else .avoid,
    });
    defer curves.deinit(gpa);

    const header = (2 + curves.len()) * @sizeOf(u32);
    const out = try gpa.alloc(u8, header + curves.points.len * 2 * @sizeOf(f64));
    defer gpa.free(out);

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

    sendResultToHost(out);
}
