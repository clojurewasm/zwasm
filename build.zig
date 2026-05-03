const std = @import("std");
// TODO(adr-0009): drop zlinter dep when Zig ships @deprecated()
// builtin + -fdeprecated flag (ziglang/zig#22822, accepted on
// urgent milestone, expected 0.17+). Tracked in
// .dev/proposal_watch.md.
const zlinter = @import("zlinter");

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
        // §9.3 / 3.3: the C API binding's Engine carries
        // `std.heap.c_allocator`, which requires libc linkage.
        // Linking unconditionally is fine — zwasm v2 is a libc-
        // adjacent runtime (wasm-c-api consumers are C hosts).
        .link_libc = true,
    });
    exe_mod.addOptions("build_options", options);

    // §9.3 / 3.1: `include/` carries the vendored C API headers
    // (wasm.h pinned via ADR-0004). Adding the path here lets
    // src/c_api/* modules `@cImport(@cInclude("wasm.h"))` once
    // the binding work lands in §9.3 / 3.2 onward.
    exe_mod.addIncludePath(b.path("include"));

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
    // leak-detecting `std.heap.DebugAllocator`-backed
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

    // `zig build test-wasmtime-misc-basic` — Phase 6 / §9.6 / 6.B
    // (per ADR-0012). Drives the wast_runner against the
    // wasmtime misc_testsuite BATCH1 fixtures vendored under
    // `test/wasmtime_misc/wast/basic/` (migrated in 6.B from the
    // now-dissolved `test/v1_carry_over/`). Initial set is
    // parse + validate only; runtime-asserting coverage lands
    // when 6.D re-drives the same corpus through the
    // wast_runtime_runner.
    const run_wasmtime_misc_basic = b.addRunArtifact(wast_runner_exe);
    run_wasmtime_misc_basic.addArg(b.pathFromRoot("test/wasmtime_misc/wast"));
    const test_wasmtime_misc_basic_step = b.step("test-wasmtime-misc-basic", "Run the wasmtime misc_testsuite BATCH1 corpus (parse + validate)");
    test_wasmtime_misc_basic_step.dependOn(&run_wasmtime_misc_basic.step);

    // `zig build test-runtime-runner-smoke` — Phase 6 / §9.6 / 6.A
    // (per ADR-0013). Drives the runtime-asserting WAST runner
    // against the in-tree smoke fixture (`test/runners/fixtures/`).
    // Smoke gate exercises module + assert_return + assert_trap +
    // valid; the full wasmtime_misc corpus wires in 6.D.
    const wast_runtime_runner_mod = b.createModule(.{
        .root_source_file = b.path("test/runners/wast_runtime_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wast_runtime_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const wast_runtime_runner_exe = b.addExecutable(.{
        .name = "zwasm-wast-runtime-runner",
        .root_module = wast_runtime_runner_mod,
    });
    const run_wast_runtime_smoke = b.addRunArtifact(wast_runtime_runner_exe);
    run_wast_runtime_smoke.addArg(b.pathFromRoot("test/runners/fixtures"));
    const test_runtime_runner_smoke_step = b.step("test-runtime-runner-smoke", "Run the runtime-asserting WAST runner against the smoke fixture");
    test_runtime_runner_smoke_step.dependOn(&run_wast_runtime_smoke.step);

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

    // `zig build test-realworld-run` — Phase 6 / §9.6 / 6.1
    // chunk b. Drives each fixture through `cli_run.runWasm`
    // end-to-end (engine → store → WASI → instantiate → entry
    // → wasm_func_call). Outcome categories: PASS / SKIP-WASI /
    // SKIP-NOENTRY / FAIL. The gate trips only on FAIL —
    // SKIP-WASI counts but is orthogonal to interp-op coverage.
    const realworld_run_runner_mod = b.createModule(.{
        .root_source_file = b.path("test/realworld/run_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    realworld_run_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const realworld_run_runner_exe = b.addExecutable(.{
        .name = "zwasm-realworld-run-runner",
        .root_module = realworld_run_runner_mod,
    });
    const run_realworld_run = b.addRunArtifact(realworld_run_runner_exe);
    run_realworld_run.addArg(b.pathFromRoot("test/realworld/wasm"));
    const test_realworld_run_step = b.step("test-realworld-run", "Run each realworld fixture end-to-end via cli_run.runWasm");
    test_realworld_run_step.dependOn(&run_realworld_run.step);

    // `zig build test-realworld-diff` — Phase 6 / §9.6 / 6.2.
    // Spawns `wasmtime run <fixture>` per fixture, captures
    // stdout, compares byte-for-byte against
    // `cli_run.runWasmCaptured`. Gate is 30+ matches; runner
    // SKIPs gracefully when wasmtime is not on PATH (so the
    // build remains green on hosts that lack it).
    const realworld_diff_runner_mod = b.createModule(.{
        .root_source_file = b.path("test/realworld/diff_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    realworld_diff_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const realworld_diff_runner_exe = b.addExecutable(.{
        .name = "zwasm-realworld-diff-runner",
        .root_module = realworld_diff_runner_mod,
    });
    const run_realworld_diff = b.addRunArtifact(realworld_diff_runner_exe);
    run_realworld_diff.addArg(b.pathFromRoot("test/realworld/wasm"));
    const test_realworld_diff_step = b.step("test-realworld-diff", "Diff realworld fixtures' stdout against wasmtime");
    test_realworld_diff_step.dependOn(&run_realworld_diff.step);

    // `zig build test-wasi-p1` — Phase 4 / §9.4 / 4.9. Walks
    // `test/wasi/` driving each .wasm fixture through
    // `cli_run.runWasm`, comparing the exit code against the
    // matching `<basename>.expected_exit` file.
    const wasi_runner_mod = b.createModule(.{
        .root_source_file = b.path("test/wasi/runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    wasi_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const wasi_runner_exe = b.addExecutable(.{
        .name = "zwasm-wasi-runner",
        .root_module = wasi_runner_mod,
    });
    const run_wasi_p1 = b.addRunArtifact(wasi_runner_exe);
    run_wasi_p1.addArg(b.pathFromRoot("test/wasi"));
    const test_wasi_p1_step = b.step("test-wasi-p1", "Run the WASI 0.1 fixture suite");
    test_wasi_p1_step.dependOn(&run_wasi_p1.step);

    // `zig build test-c-api` — Phase 3 / §9.3 / 3.9. Builds
    // `libzwasm.a` from `src/c_api/lib.zig`, compiles
    // `examples/c_host/hello.c` against `include/wasm.h`, links
    // the two, and runs the resulting executable. The C host
    // exits 0 on success (printed result == 42), non-zero on any
    // teardown / dispatch failure — `addRunArtifact` propagates
    // that to the `test-c-api` step.
    const c_api_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api_lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api_lib_mod.addOptions("build_options", options);
    c_api_lib_mod.addIncludePath(b.path("include"));
    const c_api_lib = b.addLibrary(.{
        .name = "zwasm",
        .linkage = .static,
        .root_module = c_api_lib_mod,
    });

    const c_host_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_host_mod.addCSourceFile(.{
        .file = b.path("examples/c_host/hello.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    c_host_mod.addIncludePath(b.path("include"));
    c_host_mod.linkLibrary(c_api_lib);

    const c_host_exe = b.addExecutable(.{
        .name = "zwasm-c-host-hello",
        .root_module = c_host_mod,
    });

    const run_c_host = b.addRunArtifact(c_host_exe);
    run_c_host.expectExitCode(0);
    const test_c_api_step = b.step("test-c-api", "Build libzwasm.a + the C host example, run the example");
    test_c_api_step.dependOn(&run_c_host.step);

    // `zig build test-all` — aggregate all enabled test layers.
    // Phase 0: only `test`. Phase 1+ adds spec / e2e / realworld /
    // c_api / fuzz steps as they land. Each layer registers itself
    // here so the user's invocation surface stays stable.
    const test_all_step = b.step("test-all", "Run all enabled test layers");
    test_all_step.dependOn(&run_exe_tests.step);
    test_all_step.dependOn(&run_spec_smoke.step);
    test_all_step.dependOn(&run_spec_mvp.step);
    test_all_step.dependOn(&run_realworld.step);
    test_all_step.dependOn(&run_realworld_run.step);
    // `run_realworld_diff` is intentionally NOT wired into
    // `test-all` until §9.6 / 6.2 can honestly hit its 30+
    // match gate — see handover. Today's corpus has v2 trapping
    // on 39/50 fixtures before stdout is emitted, so wiring
    // would break the build everywhere wasmtime is on PATH.
    // Run it explicitly via `zig build test-realworld-diff`
    // when working on closing the gap.
    test_all_step.dependOn(&run_wast_2_0.step);
    test_all_step.dependOn(&run_wasmtime_misc_basic.step);
    test_all_step.dependOn(&run_wast_runtime_smoke.step);
    test_all_step.dependOn(&run_c_host.step);
    test_all_step.dependOn(&run_wasi_p1.step);

    // `zig build lint` — zlinter rule chain (ADR-0009 + Phase B
    // expansion). See `private/zlinter-builtins-survey-2026-05-03.md`
    // for per-rule rationale and the spike-time finding counts.
    // Mac-host gate; not part of test-all (avoids fetching zlinter
    // on the Linux/Windows runners). Run with `--max-warnings 0`
    // for strict CI semantics.
    const lint_step = b.step("lint", "Lint source code (zlinter).");
    lint_step.dependOn(blk: {
        var builder = zlinter.builder(b, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{});
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        builder.addRule(.{ .builtin = .no_empty_block }, .{});
        builder.addRule(.{ .builtin = .require_exhaustive_enum_switch }, .{});
        builder.addRule(.{ .builtin = .no_unused }, .{});
        break :blk builder.build();
    });
}

pub const WasmLevel = enum { v1_0, v2_0, v3_0 };
pub const WasiLevel = enum { none, p1, p2, both };
pub const EngineMode = enum { interp, jit, both };
