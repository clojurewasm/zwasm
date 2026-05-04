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

    // ADR-0015 §Decision Part 2 (§9.6 / 6.K.7): -Dsanitize=address
    // wires LLVM AddressSanitizer + UBSan via Zig 0.16's
    // `module.sanitize_c = .full`. -Dsanitize=thread enables
    // ThreadSanitizer. Both Mac aarch64 + Linux x86_64 only —
    // Windows ucrt skipped because clang ASan/Win32 needs an MSVC
    // redist that doesn't ship through the Nix dev shell.
    // Adopted as a weekly OrbStack lane, not per-commit (~2× slower).
    const sanitize = b.option(SanitizeMode, "sanitize", "Sanitizer (off / address / thread). Mac+Linux only.") orelse .off;
    const is_windows = target.result.os.tag == .windows;
    const sanitize_c: ?std.zig.SanitizeC = if (is_windows) null else switch (sanitize) {
        .off => null,
        .address => .full,
        .thread => null,
    };
    const sanitize_thread: ?bool = if (is_windows) null else switch (sanitize) {
        .off, .address => null,
        .thread => true,
    };
    // Repro task name for `zig build run-repro -Dtask=<name>` per
    // ADR-0015 §Decision Part 4. Discovers
    // `private/dbg/<task>/repro.zig` and links it against the
    // zwasm-lib module. Step is silent when -Dtask is unset.
    const repro_task = b.option([]const u8, "task", "Repro task name (private/dbg/<task>/repro.zig)");

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
    applySanitize(exe_mod, sanitize_c, sanitize_thread);

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
    applySanitize(zwasm_lib_mod, sanitize_c, sanitize_thread);
    const spec_runner_mod = b.createModule(.{
        .root_source_file = b.path("test/spec/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_runner_mod.addImport("zwasm", zwasm_lib_mod);
    applySanitize(spec_runner_mod, sanitize_c, sanitize_thread);
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
    applySanitize(wast_runner_mod, sanitize_c, sanitize_thread);
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
    applySanitize(wast_runtime_runner_mod, sanitize_c, sanitize_thread);
    const wast_runtime_runner_exe = b.addExecutable(.{
        .name = "zwasm-wast-runtime-runner",
        .root_module = wast_runtime_runner_mod,
    });
    const run_wast_runtime_smoke = b.addRunArtifact(wast_runtime_runner_exe);
    run_wast_runtime_smoke.addArg(b.pathFromRoot("test/runners/fixtures"));
    const test_runtime_runner_smoke_step = b.step("test-runtime-runner-smoke", "Run the runtime-asserting WAST runner against the smoke fixture");
    test_runtime_runner_smoke_step.dependOn(&run_wast_runtime_smoke.step);

    // `zig build test-wasmtime-misc-runtime` — Phase 6 / §9.6 / 6.D
    // (per ADR-0012). Drives the runtime-asserting runner against
    // the same wasmtime_misc corpus as test-wasmtime-misc-basic, but
    // consuming `manifest_runtime.txt` (assert_return / assert_trap /
    // module / register / invoke) instead of the parse-only
    // `manifest.txt`. Surfaces v2 interp behaviour gaps that the
    // parse runner cannot see.
    //
    // **Not wired into `test-all` aggregate**. The current corpus
    // panics inside `interp.popOperand`'s assert when a fixture
    // exercises an operand-stack discipline bug (one of the 39
    // trap-mid-execution patterns ADR-0011 surfaced). 6.E (interp
    // behaviour bug investigation) addresses these; once the
    // underlying gaps close, this step joins `test-all`.
    // Until then, run standalone for triage:
    //   zig build test-wasmtime-misc-runtime
    const run_wasmtime_misc_runtime = b.addRunArtifact(wast_runtime_runner_exe);
    run_wasmtime_misc_runtime.addArg(b.pathFromRoot("test/wasmtime_misc/wast"));
    const test_wasmtime_misc_runtime_step = b.step("test-wasmtime-misc-runtime", "Run the runtime-asserting WAST runner against the wasmtime_misc corpus (NOT in test-all; surfaces 6.E targets)");
    test_wasmtime_misc_runtime_step.dependOn(&run_wasmtime_misc_runtime.step);

    // `zig build test-realworld` — parse-smoke a vendored set of
    // toolchain-produced .wasm fixtures (Phase 2 / §9.2 / 2.6).
    const realworld_runner_mod = b.createModule(.{
        .root_source_file = b.path("test/realworld/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    realworld_runner_mod.addImport("zwasm", zwasm_lib_mod);
    applySanitize(realworld_runner_mod, sanitize_c, sanitize_thread);
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
    applySanitize(realworld_run_runner_mod, sanitize_c, sanitize_thread);
    const realworld_run_runner_exe = b.addExecutable(.{
        .name = "zwasm-realworld-run-runner",
        .root_module = realworld_run_runner_mod,
    });
    const run_realworld_run = b.addRunArtifact(realworld_run_runner_exe);
    run_realworld_run.addArg(b.pathFromRoot("test/realworld/wasm"));
    const test_realworld_run_step = b.step("test-realworld-run", "Run each realworld fixture end-to-end via cli_run.runWasm");
    test_realworld_run_step.dependOn(&run_realworld_run.step);

    // `zig build test-realworld-diff` — Phase 6 / §9.6 / 6.F.
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
    applySanitize(realworld_diff_runner_mod, sanitize_c, sanitize_thread);
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
    applySanitize(wasi_runner_mod, sanitize_c, sanitize_thread);
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
    applySanitize(c_api_lib_mod, sanitize_c, sanitize_thread);
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
    applySanitize(c_host_mod, sanitize_c, sanitize_thread);

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
    // `run_realworld_diff` was wired in at §9.6 / 6.F (39/50
    // matched, 0 mismatched). The remaining 11 SKIP-V2-* are
    // Go fixtures gated on the validator's typing-rule gap
    // (§9.6 outstanding spec gap "10 SKIP-VALIDATOR realworld
    // fixtures") — they are SKIP, not FAIL, so the runner
    // exits zero. Hosts without `wasmtime` on PATH degrade to
    // SKIP-WASMTIME-FAIL gracefully and do not break the gate.
    test_all_step.dependOn(&run_realworld_diff.step);
    test_all_step.dependOn(&run_wast_2_0.step);
    test_all_step.dependOn(&run_wasmtime_misc_basic.step);
    test_all_step.dependOn(&run_wast_runtime_smoke.step);
    test_all_step.dependOn(&run_c_host.step);
    test_all_step.dependOn(&run_wasi_p1.step);

    // `zig build run-repro -Dtask=<name>` — discover
    // `private/dbg/<task>/repro.zig`, link it against the zwasm
    // library, and run it. Per ADR-0015 §Decision Part 4 / §9.6 /
    // 6.K.7. Silent (non-failing) when -Dtask is unset, so
    // `zig build` itself stays unaffected; running the step
    // without -Dtask prints the usage hint.
    const repro_step = b.step("run-repro", "Run private/dbg/<task>/repro.zig (-Dtask=<name>)");
    if (repro_task) |task| {
        const repro_path = b.fmt("private/dbg/{s}/repro.zig", .{task});
        const repro_mod = b.createModule(.{
            .root_source_file = b.path(repro_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        repro_mod.addImport("zwasm", zwasm_lib_mod);
        applySanitize(repro_mod, sanitize_c, sanitize_thread);
        const repro_exe = b.addExecutable(.{
            .name = b.fmt("zwasm-repro-{s}", .{task}),
            .root_module = repro_mod,
        });
        const run_repro = b.addRunArtifact(repro_exe);
        repro_step.dependOn(&run_repro.step);
    } else {
        const print_usage = b.addSystemCommand(&.{
            "/bin/sh", "-c",
            "echo 'usage: zig build run-repro -Dtask=<name>  (private/dbg/<name>/repro.zig)' >&2; exit 2",
        });
        repro_step.dependOn(&print_usage.step);
    }

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
pub const SanitizeMode = enum { off, address, thread };

/// Apply the `-Dsanitize` selection to a freshly-created module.
/// Per ADR-0015 §Decision Part 2 / §9.6 / 6.K.7: `.full` enables
/// LLVM AddressSanitizer + UBSan; `sanitize_thread` enables
/// ThreadSanitizer. Mac aarch64 + Linux x86_64 only — Windows
/// ucrt skipped (caller passes nulls).
fn applySanitize(
    mod: *std.Build.Module,
    sanitize_c: ?std.zig.SanitizeC,
    sanitize_thread: ?bool,
) void {
    if (sanitize_c) |s| mod.sanitize_c = s;
    if (sanitize_thread) |t| mod.sanitize_thread = t;
}
