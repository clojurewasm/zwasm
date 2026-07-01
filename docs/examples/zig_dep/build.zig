//! Build script for the external-consumer example. Pulls the public
//! `zwasm` module from the path-dep (`b.dependency("zwasm").module("zwasm")`)
//! and links it into a tiny host exe. Run with `zig build run` from this
//! directory (or via `scripts/check_zig_consumer.sh` from the repo root).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zw = b.dependency("zwasm", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "zwasm-zig-dep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zwasm", zw.module("zwasm"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run", "Build + run the external zwasm consumer (exits 0 on add(2,40)==42)");
    run_step.dependOn(&run.step);
}
