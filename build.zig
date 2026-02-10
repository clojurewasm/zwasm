const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (for use as dependency and test root)
    const mod = b.addModule("zwasm", .{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
    });

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
    const cli = b.addExecutable(.{
        .name = "zwasm",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

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
