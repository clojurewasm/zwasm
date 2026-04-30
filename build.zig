const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ROADMAP §4.6 — coarse, orthogonal feature flags.
    //   -Dwasm     : Wasm spec level (3.0 default)
    //   -Dwasi     : WASI version inclusion
    //   -Dengine   : engine selection (interp / jit / both)
    //   -Dstrip    : strip debug info from the CLI binary
    //
    // Per-proposal feature gating happens via dispatch-table
    // registration (ROADMAP §4.5 / A12), not pervasive build-time
    // `if` branches.
    const wasm_level = b.option(WasmLevel, "wasm", "Wasm spec level (default 3.0)") orelse .v3_0;
    const wasi_level = b.option(WasiLevel, "wasi", "WASI version inclusion (default p1)") orelse .p1;
    const engine_mode = b.option(EngineMode, "engine", "Engine selection (default both)") orelse .both;
    const enable_strip = b.option(bool, "strip", "Strip debug info from the CLI binary") orelse false;
    const strip_opt: ?bool = if (enable_strip) true else null;

    const options = b.addOptions();
    options.addOption(WasmLevel, "wasm_level", wasm_level);
    options.addOption(WasiLevel, "wasi_level", wasi_level);
    options.addOption(EngineMode, "engine_mode", engine_mode);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_opt,
    });
    exe_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "zwasm",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // `zig build run -- <args>` runs the CLI.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the zwasm executable");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — unit tests inline in src/.
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    // `zig build test-all` — aggregate all enabled test layers.
    // Phase 0: only `test`. Phase 1+ adds spec / e2e / realworld /
    // c_api / fuzz steps as they land. Each layer registers itself
    // here so the user's invocation surface stays stable.
    const test_all_step = b.step("test-all", "Run all enabled test layers");
    test_all_step.dependOn(&run_exe_tests.step);
}

pub const WasmLevel = enum { v1_0, v2_0, v3_0 };
pub const WasiLevel = enum { none, p1, p2, both };
pub const EngineMode = enum { interp, jit, both };
