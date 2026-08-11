const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library. `src/root.zig` is the only entry point consumers see; the
    // executable below imports it by name rather than reaching into the source
    // files directly, so the module wiring actually carries weight.
    const mod = b.addModule("implicit_plot", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const clap = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "implicit-plot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "implicit_plot", .module = mod },
                .{ .name = "clap", .module = clap.module("clap") },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Render a relation (zig build run -- --help)").dependOn(&run.step);

    // One test binary per module: the library's tests live under `root.zig`,
    // which re-exports every file, and the executable's cover argument parsing.
    const test_step = b.step("test", "Run all tests");
    for ([_]*std.Build.Module{ mod, exe.root_module }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    addTypstPlugin(b);
}

/// A Typst plugin, built for `wasm32-freestanding` against the same library.
///
/// It is a second target rather than a second package: a module carries its
/// target, so the library source is instantiated once more here, but nothing
/// else is duplicated - no second `build.zig.zon`, no path dependency, and the
/// wire format lives in `src/wire.zig`, where the host test suite above pins
/// it with golden bytes.
fn addTypstPlugin(b: *std.Build) void {
    // Deliberately WITHOUT simd128, although Typst 0.14+ supports it: Typst
    // executes plugins in an interpreter (wasmi), where every v128 instruction
    // is software-emulated and costs more to dispatch than the scalar ops it
    // replaces. Measured on the same wasm and the same call, the SIMD build
    // takes 1.37x as long under Typst and the same time under a JIT (V8:
    // 70ms either way, at native speed - so the vector code is only ballast
    // in the one runtime this artifact is built for).
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.lime1 },
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .bulk_memory, .reference_types }),
    });
    // The host default (Debug) produces a plugin too slow and too large to be
    // useful, and plotting is compute-bound, so this gets its own knob.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "wasm-optimize",
        "Optimize mode for the Typst plugin (default ReleaseFast)",
    ) orelse .ReleaseFast;

    const lib = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const plugin = b.addExecutable(.{
        .name = "implicit_plot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/typst_plugin.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "implicit_plot", .module = lib }},
            .strip = true,
            .omit_frame_pointer = true,
            .unwind_tables = .none,
        }),
    });
    plugin.entry = .disabled;
    plugin.rdynamic = true;

    const install = b.addInstallArtifact(plugin, .{
        .dest_dir = .{ .override = .{ .custom = "../typst" } },
    });
    b.step("wasm", "Build the Typst plugin into typst/").dependOn(&install.step);
}
