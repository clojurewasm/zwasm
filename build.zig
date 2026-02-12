const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const enable_wat = b.option(bool, "wat", "Enable WAT text format parser (default: true)") orelse true;

    const options = b.addOptions();
    options.addOption(bool, "enable_wat", enable_wat);

    // Library module (for use as dependency and test root)
    const mod = b.addModule("zwasm", .{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", options);

    // Tests
    const tests = b.addTest(.{
        .root_module = mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // CLI executable (zwasm run/inspect/validate)
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addOptions("build_options", options);
    const cli = b.addExecutable(.{
        .name = "zwasm",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    // Example executables
    const examples = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "example_basic", .src = "examples/basic.zig" },
        .{ .name = "example_memory", .src = "examples/memory.zig" },
        .{ .name = "example_inspect", .src = "examples/inspect.zig" },
    };
    for (examples) |ex| {
        const ex_mod = b.createModule(.{
            .root_source_file = b.path(ex.src),
            .target = target,
            .optimize = optimize,
        });
        ex_mod.addImport("zwasm", mod);
        const ex_exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = ex_mod,
        });
        b.installArtifact(ex_exe);
    }

    // E2E test runner executable
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("test/e2e/e2e_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addImport("zwasm", mod);
    const e2e = b.addExecutable(.{
        .name = "e2e_runner",
        .root_module = e2e_mod,
    });
    b.installArtifact(e2e);

    // Benchmark executable
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/fib_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("zwasm", mod);
    const bench = b.addExecutable(.{
        .name = "fib_bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench);
}
