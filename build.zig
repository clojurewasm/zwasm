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
    //
    // Zig's `b.addTest` injects `std.testing.allocator` (a
    // leak-detecting `std.heap.GeneralPurposeAllocator`-backed
    // allocator) into every test. Any allocation that escapes a
    // test without a matching free prints `error(gpa): memory
    // address ... leaked` and fails the run. So `zig build test`
    // IS the leak-check gate per §9.2 / 2.5 — no separate
    // `--leak-check` step is needed.
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    // `zig build test-spec` — drive the frontend over the vendored
    // Wasm spec corpus (Phase 1 / §9.1 / 1.8: parser smoke; 1.9
    // upgrades to full decode + validate + lower).
    const zwasm_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    zwasm_lib_mod.addOptions("build_options", options);
    const spec_runner_mod = b.createModule(.{
        .root_source_file = b.path("test/spec/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const spec_runner_exe = b.addExecutable(.{
        .name = "zwasm-spec-runner",
        .root_module = spec_runner_mod,
    });
    const run_spec_smoke = b.addRunArtifact(spec_runner_exe);
    run_spec_smoke.addArg(b.pathFromRoot("test/spec/smoke"));
    const run_spec_mvp = b.addRunArtifact(spec_runner_exe);
    run_spec_mvp.addArg(b.pathFromRoot("test/spec/wasm-1.0"));
    const test_spec_step = b.step("test-spec", "Run the Wasm spec test runner");
    test_spec_step.dependOn(&run_spec_smoke.step);
    test_spec_step.dependOn(&run_spec_mvp.step);

    // `zig build test-spec-wasm-2.0` — wast-directive runner
    // (Phase 2 / §9.2 / 2.7). Reads each subdir's manifest.txt
    // and processes module / assert_invalid / assert_malformed
    // (binary) commands.
    const wast_runner_mod = b.createModule(.{
        .root_source_file = b.path("test/spec/wast_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    wast_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const wast_runner_exe = b.addExecutable(.{
        .name = "zwasm-wast-runner",
        .root_module = wast_runner_mod,
    });
    const run_wast_2_0 = b.addRunArtifact(wast_runner_exe);
    run_wast_2_0.addArg(b.pathFromRoot("test/spec/wasm-2.0"));
    const test_spec_2_0_step = b.step("test-spec-wasm-2.0", "Run the Wasm 2.0 wast-directive runner");
    test_spec_2_0_step.dependOn(&run_wast_2_0.step);

    // `zig build test-realworld` — parse-smoke a vendored set of
    // toolchain-produced .wasm fixtures (Phase 2 / §9.2 / 2.6).
    const realworld_runner_mod = b.createModule(.{
        .root_source_file = b.path("test/realworld/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    realworld_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const realworld_runner_exe = b.addExecutable(.{
        .name = "zwasm-realworld-runner",
        .root_module = realworld_runner_mod,
    });
    const run_realworld = b.addRunArtifact(realworld_runner_exe);
    run_realworld.addArg(b.pathFromRoot("test/realworld/wasm"));
    const test_realworld_step = b.step("test-realworld", "Run the realworld parse smoke");
    test_realworld_step.dependOn(&run_realworld.step);

    // `zig build test-all` — aggregate all enabled test layers.
    // Phase 0: only `test`. Phase 1+ adds spec / e2e / realworld /
    // c_api / fuzz steps as they land. Each layer registers itself
    // here so the user's invocation surface stays stable.
    const test_all_step = b.step("test-all", "Run all enabled test layers");
    test_all_step.dependOn(&run_exe_tests.step);
    test_all_step.dependOn(&run_spec_smoke.step);
    test_all_step.dependOn(&run_spec_mvp.step);
    test_all_step.dependOn(&run_realworld.step);
    test_all_step.dependOn(&run_wast_2_0.step);
}

pub const WasmLevel = enum { v1_0, v2_0, v3_0 };
pub const WasiLevel = enum { none, p1, p2, both };
pub const EngineMode = enum { interp, jit, both };
