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

/// The options header and the response layouts live in `wire.zig`, inside the
/// library, where the host test suite pins them with golden bytes - this file
/// cannot host tests, since its exports reference the `typst_env` externs.
const Options = irp.wire.Options;

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

/// The curve as polylines, for stroking rather than filling. The response
/// layout is `wire.encodeCurves`'s; `width` and `height` are the tracing
/// grid, not pixels.
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
    var curves = try irp.contour.trace(gpa, &relation, .{
        .x0 = options.view.x_min,
        .x1 = options.view.x_max,
        .y0 = options.view.y_min,
        .y1 = options.view.y_max,
    }, .{
        .min_depth = @intCast(@min(16, std.math.log2_int_ceil(u32, @max(2, across)))),
        .extra_depth = @intCast(@min(options.depth, irp.wire.max_contour_refine)),
        .uncertain = if (options.join_uncertain) .join else .avoid,
    });
    defer curves.deinit(gpa);

    const out = try irp.wire.encodeCurves(gpa, curves);
    defer gpa.free(out);
    sendResultToHost(out);
}
