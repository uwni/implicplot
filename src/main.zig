//! Command line front end.
//!
//! `main` takes `std.process.Init`, so Zig 0.16 hands us the process arena, a
//! general purpose allocator with leak checking in debug builds, and an `Io`
//! implementation already wired to a thread pool - none of which has to be
//! constructed, torn down, or leak-checked by hand.

const std = @import("std");
const irp = @import("implicit_plot");

const default_source = "sin(x^2 + y^2) = cos(x*y)";

const usage =
    \\usage: implicit-plot [options] ["<relation>"]
    \\
    \\Draws the set of points satisfying a relation, using interval arithmetic.
    \\The relation may use x, y, + - * / ^, parentheses, the constants pi, tau
    \\and e, and the functions sin cos tan exp sqrt log/ln abs asin acos atan.
    \\
    \\options:
    \\  -o, --out <path>     PNG to write, or "-" for none        (default plot.png)
    \\  -s, --size <WxH>     image size in pixels                 (default 1024x1024)
    \\  -x, --xrange <a:b>   horizontal range                     (default -10:10)
    \\  -y, --yrange <a:b>   vertical range                       (default -10:10)
    \\  -d, --depth <n>      sub-pixel refinement depth           (default 8)
    \\  -j, --tasks <n>      parallel row strips                  (default 8 per CPU)
    \\  -a, --ascii          also print the plot as ASCII art
    \\  -h, --help           show this message
    \\  --                   everything after this is the relation
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

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const cli = try parseArgs(argv);
    if (cli.help) {
        try stdout.writeAll(usage);
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
        try irp.png.write(gpa, &file_writer.interface, image, .{});
        try file_writer.interface.flush();
        try stdout.print("  wrote {s}\n", .{path});
    }

    try stdout.print("  {d} of {d} pixels lit in {f}\n", .{
        image.count(),
        @as(u64, cli.view.width) * cli.view.height,
        elapsed,
    });
}

fn parseArgs(argv: []const [:0]const u8) !Cli {
    var cli: Cli = .{};
    var saw_source = false;
    var only_operands = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!only_operands and std.mem.eql(u8, arg, "--")) {
            only_operands = true;
            continue;
        }
        if (only_operands) {
            if (saw_source) std.process.fatal("only one relation may be given", .{});
            cli.source = arg;
            saw_source = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            cli.help = true;
            return cli;
        }
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--ascii")) {
            cli.ascii = true;
            continue;
        }
        if (looksLikeOption(arg)) {
            // Identify the option *before* consuming a value, so that a typo
            // is reported as a typo rather than as a missing argument.
            const option = options.get(arg) orelse std.process.fatal("unknown option {s}\n\n{s}", .{ arg, usage });
            i += 1;
            if (i == argv.len) std.process.fatal("{s} needs a value", .{arg});
            const value = argv[i];
            switch (option) {
                .out => cli.out = if (std.mem.eql(u8, value, "-")) null else value,
                .size => {
                    const size = splitPair(value, 'x') orelse std.process.fatal("--size wants WxH, got {s}", .{value});
                    cli.view.width = parseUnsigned(size[0], "--size");
                    cli.view.height = parseUnsigned(size[1], "--size");
                    if (cli.view.width == 0 or cli.view.height == 0) std.process.fatal("--size must be positive", .{});
                },
                .xrange => {
                    const range = splitPair(value, ':') orelse std.process.fatal("--xrange wants a:b, got {s}", .{value});
                    cli.view.x_min = parseFloat(range[0], "--xrange");
                    cli.view.x_max = parseFloat(range[1], "--xrange");
                },
                .yrange => {
                    const range = splitPair(value, ':') orelse std.process.fatal("--yrange wants a:b, got {s}", .{value});
                    cli.view.y_min = parseFloat(range[0], "--yrange");
                    cli.view.y_max = parseFloat(range[1], "--yrange");
                },
                .depth => cli.depth = @intCast(@min(parseUnsigned(value, "--depth"), 24)),
                .tasks => cli.tasks = parseUnsigned(value, "--tasks"),
            }
            continue;
        }

        if (saw_source) std.process.fatal("only one relation may be given", .{});
        cli.source = arg;
        saw_source = true;
    }

    if (cli.view.x_min >= cli.view.x_max) std.process.fatal("--xrange must be increasing", .{});
    if (cli.view.y_min >= cli.view.y_max) std.process.fatal("--yrange must be increasing", .{});
    return cli;
}

const Option = enum { out, size, xrange, yrange, depth, tasks };

const options = std.StaticStringMap(Option).initComptime(.{
    .{ "-o", .out },     .{ "--out", .out },
    .{ "-s", .size },    .{ "--size", .size },
    .{ "-x", .xrange },  .{ "--xrange", .xrange },
    .{ "-y", .yrange },  .{ "--yrange", .yrange },
    .{ "-d", .depth },   .{ "--depth", .depth },
    .{ "-j", .tasks },   .{ "--tasks", .tasks },
});

/// A leading `-` starts an option unless the argument is a negative number, so
/// that `-x -6:6` works. A relation that starts with a minus goes after `--`,
/// which is the convention every POSIX tool already taught the user.
fn looksLikeOption(arg: []const u8) bool {
    return arg.len >= 2 and arg[0] == '-' and !std.ascii.isDigit(arg[1]) and arg[1] != '.';
}

fn splitPair(value: []const u8, separator: u8) ?[2][]const u8 {
    const at = std.mem.indexOfScalar(u8, value, separator) orelse return null;
    return .{ value[0..at], value[at + 1 ..] };
}

fn parseUnsigned(text: []const u8, what: []const u8) u32 {
    return std.fmt.parseInt(u32, text, 10) catch
        std.process.fatal("{s} wants a whole number, got {s}", .{ what, text });
}

fn parseFloat(text: []const u8, what: []const u8) f64 {
    return std.fmt.parseFloat(f64, text) catch
        std.process.fatal("{s} wants a number, got {s}", .{ what, text });
}

const testing = std.testing;

test "argument parsing" {
    const argv = [_][:0]const u8{ "prog", "-s", "320x200", "-x", "-6:6", "--depth", "4", "-a", "y = x^2" };
    const cli = try parseArgs(&argv);
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
    const explicit = [_][:0]const u8{ "prog", "-x", "-1:1", "--", "-x" };
    const cli = try parseArgs(&explicit);
    try testing.expectEqualStrings("-x", cli.source);
    try testing.expectEqual(@as(f64, -1), cli.view.x_min);
}

test "defaults and -o -" {
    const argv = [_][:0]const u8{ "prog", "-o", "-" };
    const cli = try parseArgs(&argv);
    try testing.expectEqual(@as(?[]const u8, null), cli.out);
    try testing.expectEqualStrings(default_source, cli.source);
    try testing.expectEqual(@as(u32, 1024), cli.view.width);
}
