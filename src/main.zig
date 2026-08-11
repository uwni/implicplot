//! Command line front end.
//!
//! `main` takes `std.process.Init`, so Zig 0.16 hands us the process arena, a
//! general purpose allocator with leak checking in debug builds, and an `Io`
//! implementation already wired to a thread pool - none of which has to be
//! constructed, torn down, or leak-checked by hand.
//!
//! Argument parsing is zig-clap's: the option table below is the single
//! statement of the interface, and the help text, the parser and the struct
//! of results are all derived from it.

const std = @import("std");
const clap = @import("clap");
const irp = @import("implicit_plot");

const default_source = "sin(x^2 + y^2) = cos(x*y)";

const params = clap.parseParamsComptime(
    \\-o, --out <path>     PNG to write, or "-" for none (default plot.png)
    \\-s, --size <WxH>     image size in pixels (default 1024x1024)
    \\-x, --xrange <a:b>   horizontal range (default -10:10)
    \\-y, --yrange <a:b>   vertical range (default -10:10)
    \\-d, --depth <n>      sub-pixel refinement depth (default 8)
    \\-j, --tasks <n>      parallel row strips (default 8 per CPU)
    \\-a, --ascii          also print the plot as ASCII art
    \\-h, --help           show this message
    \\<relation>...
    \\
);

const Size = struct { width: u32, height: u32 };

fn parseSize(in: []const u8) error{InvalidSize}!Size {
    const pair = std.mem.cutScalar(u8, in, 'x') orelse return error.InvalidSize;
    return .{
        .width = std.fmt.parseInt(u32, pair[0], 10) catch return error.InvalidSize,
        .height = std.fmt.parseInt(u32, pair[1], 10) catch return error.InvalidSize,
    };
}

fn parseRange(in: []const u8) error{InvalidRange}![2]f64 {
    const pair = std.mem.cutScalar(u8, in, ':') orelse return error.InvalidRange;
    return .{
        std.fmt.parseFloat(f64, pair[0]) catch return error.InvalidRange,
        std.fmt.parseFloat(f64, pair[1]) catch return error.InvalidRange,
    };
}

const value_parsers = .{
    .path = clap.parsers.string,
    .WxH = parseSize,
    .@"a:b" = parseRange,
    .n = clap.parsers.int(u32, 10),
    .relation = clap.parsers.string,
};

const preamble =
    \\usage: implicit-plot [options] ["<relation>"]
    \\
    \\Draws the set of points satisfying a relation, using interval arithmetic.
    \\The relation may use x, y, + - * / ^, parentheses, the constants pi, tau
    \\and e, and these functions:
    \\
++ "  " ++ irp.parse.function_list ++ "\n" ++
    \\
    \\Multiplication is never implicit: write 2*x, not 2x. A relation starting
    \\with a minus goes after "--".
    \\
    \\options:
    \\
;

const examples =
    \\
    \\examples:
    \\  implicit-plot "sin(x^2 + y^2) = cos(x*y)"
    \\  implicit-plot -s 200x80 -a -o - "y = tan(x)"
    \\  implicit-plot -x -6:6 -y -4:4 "sin(x^2 - y^2) < sin(x + y) + cos(x*y)"
    \\
;

const Cli = struct {
    source: []const u8 = default_source,
    out: ?[]const u8 = "plot.png",
    ascii: bool = false,
    view: irp.View = .{ .width = 1024, .height = 1024 },
    depth: u8 = 8,
    tasks: u32 = 0,
    help: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};

    var diag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &params, value_parsers, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        diag.reportToFile(io, .stderr(), err) catch {};
        std.process.exit(1);
    };
    defer res.deinit();

    const cli = cliFrom(res.args, res.positionals[0]);
    if (cli.help) {
        try stdout.writeAll(preamble);
        try clap.help(stdout, clap.Help, &params, .{
            .description_on_new_line = false,
            .description_indent = 3,
            .spacing_between_parameters = 0,
        });
        try stdout.writeAll(examples);
        return;
    }

    var diagnostic: irp.parse.Diagnostic = .{};
    var relation = irp.parse.relationFrom(gpa, cli.source, &diagnostic) catch |err| switch (err) {
        error.ParseFailed => {
            var buffer: [1024]u8 = undefined;
            var stderr_file = std.Io.File.stderr().writer(io, &buffer);
            try diagnostic.report(&stderr_file.interface, cli.source);
            try stderr_file.interface.flush();
            std.process.exit(1);
        },
        else => |e| return e,
    };
    defer relation.deinit(gpa);

    try stdout.print("{s}\n  {d} x {d} px over x in [{d}, {d}], y in [{d}, {d}]\n", .{
        cli.source,
        cli.view.width,
        cli.view.height,
        cli.view.x_min,
        cli.view.x_max,
        cli.view.y_min,
        cli.view.y_max,
    });
    try stdout.flush();

    const progress = std.Progress.start(io, .{ .root_name = "plot" });
    defer progress.end();

    const started: std.Io.Timestamp = .now(io, .awake);
    var image = try irp.render(gpa, io, &relation, .{
        .view = cli.view,
        .subpixel_depth = cli.depth,
        .tasks = cli.tasks,
        .progress = progress,
    });
    defer image.deinit(gpa);
    const elapsed = started.untilNow(io, .awake);

    if (cli.ascii) try image.writeAscii(stdout);

    if (cli.out) |path| {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buffer: [8192]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        try irp.png.write(gpa, &file_writer.interface, image);
        try file_writer.interface.flush();
        try stdout.print("  wrote {s}\n", .{path});
    }

    try stdout.print("  {d} of {d} pixels lit in {f}\n", .{
        image.count(),
        @as(u64, cli.view.width) * cli.view.height,
        elapsed,
    });
}

/// clap's results, checked and folded into one struct with the defaults
/// applied. The checks fatal out rather than return an error: they are user
/// mistakes, and the message is the whole point.
fn cliFrom(args: anytype, relations: []const []const u8) Cli {
    var cli: Cli = .{};
    cli.help = args.help != 0;
    cli.ascii = args.ascii != 0;

    if (args.out) |path| cli.out = if (std.mem.eql(u8, path, "-")) null else path;
    if (args.size) |size| {
        if (size.width == 0 or size.height == 0) std.process.fatal("--size must be positive", .{});
        cli.view.width = size.width;
        cli.view.height = size.height;
    }
    if (args.xrange) |range| {
        cli.view.x_min = range[0];
        cli.view.x_max = range[1];
    }
    if (args.yrange) |range| {
        cli.view.y_min = range[0];
        cli.view.y_max = range[1];
    }
    if (args.depth) |depth| cli.depth = @intCast(@min(depth, 24));
    if (args.tasks) |tasks| cli.tasks = tasks;

    // clap stores surplus positionals over the one declared into the same
    // slot, so the count is the only witness that two relations were given.
    if (relations.len > 1) std.process.fatal("only one relation may be given", .{});
    if (relations.len == 1) cli.source = relations[0];

    if (cli.view.x_min >= cli.view.x_max) std.process.fatal("--xrange must be increasing", .{});
    if (cli.view.y_min >= cli.view.y_max) std.process.fatal("--yrange must be increasing", .{});
    return cli;
}

const testing = std.testing;

/// The tests drive the same params, parsers and folding `main` uses, through
/// clap's slice iterator (which, unlike `clap.parse`, does not skip argv[0]).
fn parseSlice(args: []const []const u8) !Cli {
    var iter = clap.args.SliceIterator{ .args = args };
    var res = try clap.parseEx(clap.Help, &params, value_parsers, &iter, .{ .allocator = testing.allocator });
    defer res.deinit();
    return cliFrom(res.args, res.positionals[0]);
}

test "argument parsing" {
    const cli = try parseSlice(&.{ "-s", "320x200", "-x", "-6:6", "--depth", "4", "-a", "y = x^2" });
    try testing.expectEqual(@as(u32, 320), cli.view.width);
    try testing.expectEqual(@as(u32, 200), cli.view.height);
    try testing.expectEqual(@as(f64, -6), cli.view.x_min);
    try testing.expectEqual(@as(f64, 6), cli.view.x_max);
    try testing.expectEqual(@as(u8, 4), cli.depth);
    try testing.expect(cli.ascii);
    try testing.expectEqualStrings("y = x^2", cli.source);
    try testing.expectEqualStrings("plot.png", cli.out.?);
}

test "a relation starting with a minus goes after --" {
    const cli = try parseSlice(&.{ "-x", "-1:1", "--", "-x" });
    try testing.expectEqualStrings("-x", cli.source);
    try testing.expectEqual(@as(f64, -1), cli.view.x_min);
}

test "defaults and -o -" {
    const cli = try parseSlice(&.{ "-o", "-" });
    try testing.expectEqual(@as(?[]const u8, null), cli.out);
    try testing.expectEqualStrings(default_source, cli.source);
    try testing.expectEqual(@as(u32, 1024), cli.view.width);
}

test "malformed values are parse errors, not crashes" {
    try testing.expectError(error.InvalidSize, parseSlice(&.{ "-s", "320" }));
    try testing.expectError(error.InvalidRange, parseSlice(&.{ "-x", "6" }));
}
