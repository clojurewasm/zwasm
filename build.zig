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
    // Bundled into a single value so call sites use one short
    // `createSanitizedModule(b, sanitize_opts, .{...})` per module
    // instead of `createModule + applySanitize` boilerplate (D-016
    // discharge).
    const sanitize_opts: SanitizeOpts = .{ .c = sanitize_c, .thread = sanitize_thread };
    // Repro task name for `zig build run-repro -Dtask=<name>` per
    // ADR-0015 §Decision Part 4. Discovers
    // `private/dbg/<task>/repro.zig` and links it against the
    // zwasm-lib module. Step is silent when -Dtask is unset.
    const repro_task = b.option([]const u8, "task", "Repro task name (private/dbg/<task>/repro.zig)");

    // ADR-0028 / D-022: Diagnostic M3-a trace ringbuffer compile-time
    // gate. Default false so release builds emit zero trace code in
    // hot paths (per ROADMAP §A12). Enable on debug / audit runs via
    // `-Dtrace-ringbuffer=true`.
    const trace_ringbuffer = b.option(bool, "trace-ringbuffer", "Compile in Diagnostic M3-a trace ringbuffer (default: false)") orelse false;

    // ADR-0115 §3 — `-Dgc=true|false` zero-overhead compile-time
    // gate. `false` (default for Phase 10 v0.1 since WasmGC ops
    // aren't dispatched yet) means GC heap allocator + collector
    // vtable + root walk all skip at runtime; future cycles add
    // the dispatch-side comptime check that strips op_gc handlers
    // via DCE when `enable_gc=false` (WAMR-equivalent nuclear
    // strip per ADR-0115 §3). `true` opts the feature in once
    // op_gc lands. Pairs with `Module.needs_gc_heap` parse-time
    // predicate — the runtime gate at instantiate already
    // skips heap materialisation when needs_gc_heap=false, so
    // `enable_gc=false` is the additional source-level strip for
    // module-construction code paths.
    const enable_gc = b.option(bool, "gc", "Enable WasmGC heap+collector compile-in (default: false; per ADR-0115 §3)") orelse false;

    const options = b.addOptions();
    options.addOption(WasmLevel, "wasm_level", wasm_level);
    options.addOption(WasiLevel, "wasi_level", wasi_level);
    options.addOption(EngineMode, "engine_mode", engine_mode);
    options.addOption(bool, "trace_ringbuffer", trace_ringbuffer);
    options.addOption(bool, "enable_gc", enable_gc);

    // Build_options as a single shared module so both `core` and
    // `exe_mod` (and any other consumer) reference the same Module.
    // ADR-0028 requires `src/diagnostic/trace.zig` to import
    // `build_options`; the previous double-`addOptions` shape made
    // the auto-generated file the root of two modules ("build_options"
    // and "build_options0") and broke compilation when both root
    // modules (core + exe_mod) appeared in the same `zig build test`
    // run. Sharing a single Module via `b.addModule` deduplicates.
    const build_options_mod = options.createModule();

    // ============================================================
    // `core` module — the shared library Module per ADR-0024 D-1.
    // Rooted at `src/zwasm.zig` so transitive `@import("../X")`
    // chains stay inside `src/` (the subtree restriction Zig 0.16
    // enforces). Used as `.root_module` by:
    //   - libzwasm.a (static lib)
    //   - test runners (spec / wast / realworld / wasi / etc.)
    //   - the CLI exe's root_module imports it by name (Bun-style
    //     self-import + Ghostty-style multi-artifact reuse)
    // ADR-0024 D-2 carves out `src/zwasm.zig` as the single
    // re-export hub and test loader.
    // ============================================================
    const core = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("src/zwasm.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_opt,
        // §9.3 / 3.3: the C API binding's Engine carries
        // `std.heap.c_allocator`, which requires libc linkage.
        // Linking unconditionally is fine — zwasm v2 is a libc-
        // adjacent runtime (wasm-c-api consumers are C hosts).
        .link_libc = true,
    });
    core.addImport("build_options", build_options_mod);
    // §9.3 / 3.1: `include/` carries the vendored C API headers
    // (wasm.h pinned via ADR-0004). Adding the path here lets
    // src/api/* modules `@cImport(@cInclude("wasm.h"))` resolve.
    core.addIncludePath(b.path("include"));
    // ADR-0024 D-3: self-import. Every leaf in `src/` can write
    // `@import("zwasm").<zone>.<symbol>` to reach the central
    // re-export hub regardless of nesting depth.
    core.addImport("zwasm", core);

    // CLI exe — separate thin module rooted at `src/cli/main.zig`
    // (per ADR-0024 D-4) so `pub fn main` lives in the CLI zone
    // and doesn't collide with C hosts' `int main` when they link
    // against libzwasm.a.
    const exe_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_opt,
        .link_libc = true,
    });
    exe_mod.addImport("build_options", build_options_mod);
    exe_mod.addIncludePath(b.path("include"));
    exe_mod.addImport("zwasm", core);

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
    // Unit tests run against the `core` module directly — that's
    // where the test loader lives (per ADR-0024 D-2). The CLI
    // exe's tests come along too via the inline `test "..."`
    // blocks in `src/cli/main.zig`.
    const core_tests = b.addTest(.{ .root_module = core });
    const run_core_tests = b.addRunArtifact(core_tests);
    const cli_tests = b.addTest(.{ .root_module = exe_mod });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    // Close-plan §6 (j) D-153 / direct-implementation route
    // (2026-05-21). spectest is the standard Wasm host module
    // (canonical: `WebAssembly/spec/interpreter/host/spectest.ml`,
    // 56 OCaml lines). Both v1 zwasm and wazero ship it as a
    // regular `.wat` that the spec runner auto-registers; we
    // adopt the same model.
    //
    // Pipeline:
    //   test/spec/spectest.wat (committed source)
    //     → wat2wasm (Nix-managed; flake.nix lists wabt)
    //     → spectest.wasm (in build cache; never committed)
    //     → WriteFiles bundles {spectest.wasm, spectest_module.zig}
    //     → createModule wraps it; `@embedFile("spectest.wasm")`
    //       resolves at compile time of the runner exe
    //
    // Differential rebuild: Zig tracks the .wat input file's
    // hash; unchanged .wat → cached .wasm reused. CI-grade
    // reproducibility per user request 2026-05-21.
    const spectest_wat2wasm = b.addSystemCommand(&.{"wat2wasm"});
    spectest_wat2wasm.addFileArg(b.path("test/spec/spectest.wat"));
    spectest_wat2wasm.addArg("-o");
    const spectest_wasm_path = spectest_wat2wasm.addOutputFileArg("spectest.wasm");
    const spectest_wf = b.addWriteFiles();
    _ = spectest_wf.addCopyFile(spectest_wasm_path, "spectest.wasm");
    const spectest_embed_src = spectest_wf.add("spectest_module.zig",
        \\//! Auto-generated by build.zig: wraps the compiled
        \\//! spectest.wasm (from test/spec/spectest.wat) as a
        \\//! byte slice importable via @import("spectest_module").
        \\pub const bytes: []const u8 = @embedFile("spectest.wasm");
        \\
    );
    const spectest_wasm_mod = b.createModule(.{
        .root_source_file = spectest_embed_src,
    });

    // §9.9-III (c)-2.3 D-142 fix (B) attendant: the
    // `RegisteredExporter` unit tests in
    // `test/spec/spec_assert_runner_base.zig` were authored
    // alongside the γ-1/γ-2/γ-3/γ-3.b chunks but never wired
    // into `zig build test` (they exist inside a
    // `pub fn`-providing module consumed by the three runner
    // exes; exe wiring doesn't run `test "..."` blocks). Wire
    // them now so the D-142 absent-backing assertion + the
    // γ-tests guard the exporter shape going forward.
    const spec_assert_base_test_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/spec_assert_runner_base.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_assert_base_test_mod.addImport("zwasm", core);
    spec_assert_base_test_mod.addImport("spectest_module", spectest_wasm_mod);
    const spec_assert_base_tests = b.addTest(.{ .root_module = spec_assert_base_test_mod });
    const run_spec_assert_base_tests = b.addRunArtifact(spec_assert_base_tests);
    const test_step = b.step("test", "Run unit tests");

    // §10 / 10.T-4: emit_test golden bless workflow entry point.
    // Skeleton — auto-bless impl is deferred per design plan §4.7
    // until first cluster hits ≥ 10 pending mismatches. Today
    // routes through `scripts/bless_emit_tests.sh` which reports
    // sidecar status.
    const bless_step = b.step("bless", "Apply pending emit_test golden mismatches (10.T-4 skeleton; impl deferred per design plan §4.7)");
    const bless_cmd = b.addSystemCommand(&.{ "bash", "scripts/bless_emit_tests.sh" });
    bless_step.dependOn(&bless_cmd.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_spec_assert_base_tests.step);

    // `zig build test-spec` — drive the frontend over the vendored
    // Wasm spec corpus (Phase 1 / §9.1 / 1.8: parser smoke; 1.9
    // upgrades to full decode + validate + lower).
    //
    // Per ADR-0024 D-1, every test runner reuses the same `core`
    // module via `addImport("zwasm", core)`. The `zwasm_lib_mod`
    // alias below points at `core` so existing test-runner wiring
    // (`spec_runner_mod.addImport("zwasm", zwasm_lib_mod)`) works
    // without having to thread `core` through every callsite.
    const zwasm_lib_mod = core;
    const spec_runner_mod = createSanitizedModule(b, sanitize_opts, .{
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

    // `zig build test-edge-cases` — sub-7.5b-iii fixture runner.
    // Iterates `test/edge_cases/p7/` and runs each .wasm through
    // the ARM64 JIT, comparing against the sibling .expect.
    const edge_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/edge_cases/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    edge_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const edge_runner_exe = b.addExecutable(.{
        .name = "zwasm-edge-runner",
        .root_module = edge_runner_mod,
    });
    // `has_side_effects = true` forces each fixture-runner to re-run
    // every invocation. The runner walks its corpus dir at RUNTIME, but
    // the dir path is a plain `addArg` string — NOT a tracked build
    // input — so without this flag zig caches the run-artifact on the
    // exe hash and SKIPS re-running when only fixture files change
    // (no src/exe delta). That silently gave fixture-only additions
    // FALSE coverage (they passed when run directly but the gate served
    // a stale cached result). Tests must always execute; the runner is
    // fast (~seconds for the whole corpus).
    const run_edge_p7 = b.addRunArtifact(edge_runner_exe);
    run_edge_p7.addArg(b.pathFromRoot("test/edge_cases/p7"));
    run_edge_p7.has_side_effects = true;
    const run_edge_p9 = b.addRunArtifact(edge_runner_exe);
    run_edge_p9.addArg(b.pathFromRoot("test/edge_cases/p9"));
    run_edge_p9.has_side_effects = true;
    const run_edge_p10 = b.addRunArtifact(edge_runner_exe);
    run_edge_p10.addArg(b.pathFromRoot("test/edge_cases/p10"));
    run_edge_p10.has_side_effects = true;
    // Realworld p10 result-check (10.TC-JIT IT-5): the same JIT
    // edge-runner walks `test/realworld/p10/**`, result-checking any
    // toolchain-compiled `.wasm` with a sibling `.expect`
    // (clang_musttail → return_call D-205; clang_wasm64 → memory64 D-209).
    const run_edge_realworld_p10 = b.addRunArtifact(edge_runner_exe);
    run_edge_realworld_p10.addArg(b.pathFromRoot("test/realworld/p10"));
    run_edge_realworld_p10.has_side_effects = true;
    const test_edge_step = b.step("test-edge-cases", "Run edge-case fixture runner (all hosts post §9.9 / 9.9-j-2b)");
    test_edge_step.dependOn(&run_edge_p7.step);
    test_edge_step.dependOn(&run_edge_p9.step);
    test_edge_step.dependOn(&run_edge_p10.step);
    test_edge_step.dependOn(&run_edge_realworld_p10.step);

    // `zig build test-spec-jit-compile` — §9.7 / 7.5 first
    // sub-chunk. Walks spec corpora and reports whether each
    // fixture compiles end-to-end through the JIT pipeline
    // (parse + validate + lower + regalloc + ARM64 emit). Mac
    // aarch64 only (linker tied to host arch).
    const jit_compile_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/jit_compile_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    jit_compile_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const jit_compile_runner_exe = b.addExecutable(.{
        .name = "zwasm-spec-jit-compile",
        .root_module = jit_compile_runner_mod,
    });
    const run_jit_compile = b.addRunArtifact(jit_compile_runner_exe);
    run_jit_compile.addArg(b.pathFromRoot("test/spec/smoke"));
    run_jit_compile.addArg(b.pathFromRoot("test/spec/wasm-1.0"));
    const test_jit_compile_step = b.step("test-spec-jit-compile", "JIT-compile spec corpus (Mac aarch64 only; §9.7 / 7.5)");
    test_jit_compile_step.dependOn(&run_jit_compile.step);

    // `zig build test-spec-assert` — §9.7 / 7.5-spec-assertion-driver-a.
    // Walks corpus produced by `scripts/regen_spec_1_0_assert.sh`,
    // JIT-compiles each `module` and runs each `assert_return`
    // through the typed entry helpers (callI32NoArgs / callI32_i32),
    // reporting pass / fail / skipped counts. Wired into test-all
    // on all hosts at §9.7 / 7.8 close (D-045 chunks 1-14
    // discharged; gate green Mac + Linux + Windows).
    const spec_assert_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/spec_assert_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    spec_assert_runner_mod.addImport("zwasm", zwasm_lib_mod);
    spec_assert_runner_mod.addImport("spectest_module", spectest_wasm_mod);
    const spec_assert_runner_exe = b.addExecutable(.{
        .name = "zwasm-spec-assert",
        .root_module = spec_assert_runner_mod,
    });
    const run_spec_assert = b.addRunArtifact(spec_assert_runner_exe);
    run_spec_assert.addArg(b.pathFromRoot("test/spec/wasm-1.0-assert"));
    const test_spec_assert_step = b.step("test-spec-assert", "Run JIT spec assertion runner (all hosts; gate-green at §9.7 / 7.8 close)");
    test_spec_assert_step.dependOn(&run_spec_assert.step);

    // `zig build test-spec-simd` — §9.9 per ADR-0045. SIMD spec
    // assertion runner (parallel to spec_assert_runner). §9.9-a
    // foundation: runner skeleton + build.zig wiring + manifest
    // format spec. NOT YET aggregated into test-all (deferred to
    // §9.9-e per ADR-0045 Consequences §). Manifest population
    // begins at §9.9-b.
    const simd_assert_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/simd_assert_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    simd_assert_runner_mod.addImport("zwasm", zwasm_lib_mod);
    simd_assert_runner_mod.addImport("spectest_module", spectest_wasm_mod);
    const simd_assert_runner_exe = b.addExecutable(.{
        .name = "zwasm-spec-simd",
        .root_module = simd_assert_runner_mod,
    });
    const run_simd_assert = b.addRunArtifact(simd_assert_runner_exe);
    run_simd_assert.addArg(b.pathFromRoot("test/spec/wasm-2.0-simd-assert"));
    const test_spec_simd_step = b.step("test-spec-simd", "Run SIMD spec assertion runner (§9.9 per ADR-0045; foundation: 0 manifests until §9.9-b)");
    test_spec_simd_step.dependOn(&run_simd_assert.step);

    // `zig build test-spec-wasm-2.0-assert` — §9.9 / 9.9-l-1b per
    // ADR-0057. Wasm 2.0 non-SIMD scalar spec assertion runner;
    // parallel to spec_assert_runner (wasm-1.0) and simd_assert_runner
    // (SIMD). All three runners consume `spec_assert_runner_base`
    // and differ only in their RunnerCallbacks literal. Corpus
    // (`test/spec/wasm-2.0-assert/`) lands in a follow-up chunk
    // (k-1 — curated sign-ext / sat-trunc / multi-value /
    // call_indirect wast vendor); until then the runner reports
    // "corpus not found; 0 manifests" and exits clean so test-all
    // stays green.
    // §9.9 / 9.9-l-1b-d093-d67 (D-134 probe): force the spec_assert
    // non-simd runner to compile single-threaded. The d-65
    // investigation surfaced a cross-thread `siglongjmp` hypothesis
    // (our `sigsegvHandler` installs OK + fires on intentional null
    // deref, but does NOT fire on the real OrbStack SEGV — strong
    // evidence the SEGV is delivered to a worker thread context our
    // handler cannot service). Building with `-fsingle-threaded`
    // makes `std.Io.Threaded.init` return `.init_single_threaded`
    // (per `~/Documents/OSS/zig/lib/std/Io/Threaded.zig:127`), so no
    // `Io.Threaded` worker threads can spawn at all. The spec_assert
    // runner walks corpora + invokes JIT bodies purely sequentially
    // — no `async` / `concurrent` use — so single-threaded is the
    // correct execution shape regardless. If the OrbStack SEGV
    // persists post-d-67, cross-thread is ruled out and the
    // hypothesis space narrows to (i) libc-context SEGV (RIP
    // captured in libc.so.6 region per d-65 valgrind) or (ii) Zig's
    // own `handleSegfaultPosix` chain still firing despite our own
    // sigaction (D-134 candidate path (d) — toolchain PR #25227).
    const non_simd_assert_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/spec_assert_runner_non_simd.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = true,
    });
    non_simd_assert_runner_mod.addImport("zwasm", zwasm_lib_mod);
    non_simd_assert_runner_mod.addImport("spectest_module", spectest_wasm_mod);
    // D-148 workaround: force LLVM backend for this binary. The
    // self-hosted x86_64 backend miscompiles `callconv(.c)` calls
    // with 9 FP scalar args + MEMORY-class return (`callLargesig`
    // in entry.zig hits it; large-sig spec fixture is the only
    // affected test). See Codeberg ziglang/zig#35343 (also #35329
    // for the related aggregate-arg miscompile). Mac aarch64
    // already defaults to LLVM, so the override only changes
    // x86_64 hosts in Debug. Revert once upstream lands the fix.
    const non_simd_assert_runner_exe = b.addExecutable(.{
        .name = "zwasm-spec-wasm-2-0-assert",
        .root_module = non_simd_assert_runner_mod,
        .use_llvm = true,
    });
    // D-165 cycle 9 diag: install to zig-out/bin/ so D165_DUMP_JIT
    // dumps + ad-hoc isolated runs against custom manifest dirs can
    // use a stable path (`zig-out/bin/zwasm-spec-wasm-2-0-assert(.exe)`)
    // instead of hunting for the latest .zig-cache/o/*/*.exe hash.
    b.installArtifact(non_simd_assert_runner_exe);
    const run_non_simd_assert = b.addRunArtifact(non_simd_assert_runner_exe);
    run_non_simd_assert.addArg(b.pathFromRoot("test/spec/wasm-2.0-assert"));
    const test_spec_wasm_2_0_assert_step = b.step("test-spec-wasm-2.0-assert", "Run Wasm 2.0 non-SIMD scalar spec assertion runner (§9.9 / 9.9-l-1b per ADR-0057; corpus lands at k-1)");
    test_spec_wasm_2_0_assert_step.dependOn(&run_non_simd_assert.step);

    // `zig build test-spec-wasm-3.0-assert` — §10 / 10.T-2b. Wasm 3.0
    // assertion runner skeleton; enumerates the baked manifests under
    // `test/spec/wasm-3.0-assert/<proposal>/<name>/manifest.txt` and
    // reports per-proposal directive counts. JIT-execute + assertion
    // matching lands cycle-by-cycle as impl rows 10.M / 10.R / 10.TC /
    // 10.E / 10.G adopt the spec_assert_runner_base callbacks pattern.
    const wasm_3_0_assert_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/spec_assert_runner_wasm_3_0.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_3_0_assert_runner_mod.addImport("zwasm", core);
    const wasm_3_0_assert_runner_exe = b.addExecutable(.{
        .name = "zwasm-spec-wasm-3-0-assert",
        .root_module = wasm_3_0_assert_runner_mod,
    });
    const run_wasm_3_0_assert = b.addRunArtifact(wasm_3_0_assert_runner_exe);
    run_wasm_3_0_assert.addArg(b.pathFromRoot("test/spec/wasm-3.0-assert"));
    const test_spec_wasm_3_0_assert_step = b.step("test-spec-wasm-3.0-assert", "Run Wasm 3.0 spec assertion runner skeleton (§10 / 10.T-2b; 5 sub-corpora enumerated)");
    test_spec_wasm_3_0_assert_step.dependOn(&run_wasm_3_0_assert.step);

    // In-source test of the runner skeleton (covers PROPOSALS list).
    const wasm_3_0_assert_unit_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/spec_assert_runner_wasm_3_0.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_3_0_assert_unit_mod.addImport("zwasm", core);
    const wasm_3_0_assert_unit_tests = b.addTest(.{ .root_module = wasm_3_0_assert_unit_mod });
    const run_wasm_3_0_assert_unit = b.addRunArtifact(wasm_3_0_assert_unit_tests);
    test_step.dependOn(&run_wasm_3_0_assert_unit.step);

    // §10 / 10.E spec corpus runner foundation — manifest parser
    // tests. Lands ahead of the dispatcher integration so future
    // cycles can wire parsed Directives through cli_run.runWasmCaptured
    // against a structured input shape.
    const wasm_3_0_manifest_unit_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/spec/wasm_3_0_manifest.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_3_0_manifest_unit_mod.addImport("zwasm", core);
    const wasm_3_0_manifest_unit_tests = b.addTest(.{ .root_module = wasm_3_0_manifest_unit_mod });
    const run_wasm_3_0_manifest_unit = b.addRunArtifact(wasm_3_0_manifest_unit_tests);
    test_step.dependOn(&run_wasm_3_0_manifest_unit.step);

    // §10 / 10.T-3: gc_stress + eh_frequency runner skeletons.
    // Impl-body lands when 10.G / 10.E activate (collector vtable +
    // FP-walk unwind in place). Until then the runners report
    // SKIP-P10-{GC,EH}-GAP and exit 0; their in-source unit tests
    // verify the matrix shapes per ADR-0115/0116 + ADR-0114.
    const gc_stress_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/runners/gc_stress_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gc_stress_runner_tests = b.addTest(.{ .root_module = gc_stress_runner_mod });
    const run_gc_stress_runner_tests = b.addRunArtifact(gc_stress_runner_tests);
    test_step.dependOn(&run_gc_stress_runner_tests.step);

    const eh_frequency_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/runners/eh_frequency_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const eh_frequency_runner_tests = b.addTest(.{ .root_module = eh_frequency_runner_mod });
    const run_eh_frequency_runner_tests = b.addRunArtifact(eh_frequency_runner_tests);
    test_step.dependOn(&run_eh_frequency_runner_tests.step);

    // `zig build test-spec-wasm-2.0` — wast-directive runner
    // (Phase 2 / §9.2 / 2.7). Reads each subdir's manifest.txt
    // and processes module / assert_invalid / assert_malformed
    // (binary) commands.
    const wast_runner_mod = createSanitizedModule(b, sanitize_opts, .{
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
    const wast_runtime_runner_mod = createSanitizedModule(b, sanitize_opts, .{
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
    const realworld_runner_mod = createSanitizedModule(b, sanitize_opts, .{
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
    // has_side_effects: the corpus dir is a plain `addArg` string (NOT a
    // tracked input), so without this the run-artifact is cached on the exe
    // hash and SKIPPED when only `.wasm` fixtures change → false coverage
    // (same gap as the run_edge_* steps, fixed cyc216; these realworld/wasm
    // runners were missed then). See lesson
    // `2026-05-30-edge-runner-fixture-cache-false-coverage`.
    run_realworld.has_side_effects = true;
    const test_realworld_step = b.step("test-realworld", "Run the realworld parse smoke");
    test_realworld_step.dependOn(&run_realworld.step);

    // `zig build test-realworld-run` — Phase 6 / §9.6 / 6.1
    // chunk b. Drives each fixture through `cli_run.runWasm`
    // end-to-end (engine → store → WASI → instantiate → entry
    // → wasm_func_call). Outcome categories: PASS / SKIP-WASI /
    // SKIP-NOENTRY / FAIL. The gate trips only on FAIL —
    // SKIP-WASI counts but is orthogonal to interp-op coverage.
    const realworld_run_runner_mod = createSanitizedModule(b, sanitize_opts, .{
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
    run_realworld_run.has_side_effects = true; // fixture-only changes must re-run (cyc216 gap)
    const test_realworld_run_step = b.step("test-realworld-run", "Run each realworld fixture end-to-end via cli_run.runWasm");
    test_realworld_run_step.dependOn(&run_realworld_run.step);

    // `zig build test-realworld-run-jit` — §9.7 / 7.9 chunk a
    // baseline. Walks the same corpus and drives each fixture
    // through `engine.runner.compileWasm` (the JIT pipeline).
    // Reports compile-side coverage: COMPILE-PASS / COMPILE-IMPORTS
    // / COMPILE-OP / COMPILE-VAL / FAIL-OTHER. Chunks 7.9-b/c/d
    // turn COMPILE-PASS into RUN-PASS by adding host-import
    // dispatch + JitRuntime memory init + WASI stub handlers.
    const realworld_run_jit_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/realworld/run_runner_jit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    realworld_run_jit_mod.addImport("zwasm", zwasm_lib_mod);
    const realworld_run_jit_exe = b.addExecutable(.{
        .name = "zwasm-realworld-run-jit-runner",
        .root_module = realworld_run_jit_mod,
    });
    const run_realworld_run_jit = b.addRunArtifact(realworld_run_jit_exe);
    run_realworld_run_jit.addArg(b.pathFromRoot("test/realworld/wasm"));
    run_realworld_run_jit.has_side_effects = true; // fixture-only changes must re-run (cyc216 gap)
    const test_realworld_run_jit_step = b.step("test-realworld-run-jit", "JIT-compile each realworld fixture (§9.7 / 7.9 baseline)");
    test_realworld_run_jit_step.dependOn(&run_realworld_run_jit.step);

    // `zig build test-realworld-diff` — Phase 6 / §9.6 / 6.F.
    // Spawns `wasmtime run <fixture>` per fixture, captures
    // stdout, compares byte-for-byte against
    // `cli_run.runWasmCaptured`. Gate is 30+ matches; runner
    // SKIPs gracefully when wasmtime is not on PATH (so the
    // build remains green on hosts that lack it).
    const realworld_diff_runner_mod = createSanitizedModule(b, sanitize_opts, .{
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
    run_realworld_diff.has_side_effects = true; // fixture-only changes must re-run (cyc216 gap)
    const test_realworld_diff_step = b.step("test-realworld-diff", "Diff realworld fixtures' stdout against wasmtime");
    test_realworld_diff_step.dependOn(&run_realworld_diff.step);

    // `zig build test-api-zig-facade` — Phase 10 / §10.J / J.6.
    // Walks the realworld corpus driving each fixture through the
    // native Zig facade (`Engine.compile` → `Module.instantiate`).
    // Pairs with `test-realworld-run` (c_api path) so the same
    // fixture set exercises both surfaces. WASI fixtures SKIP per
    // D-176 (defineWasi lands at J.7).
    const zig_facade_runner_mod = createSanitizedModule(b, sanitize_opts, .{
        .root_source_file = b.path("test/api/zig_facade_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zig_facade_runner_mod.addImport("zwasm", zwasm_lib_mod);
    const zig_facade_runner_exe = b.addExecutable(.{
        .name = "zwasm-zig-facade-runner",
        .root_module = zig_facade_runner_mod,
    });
    const run_zig_facade = b.addRunArtifact(zig_facade_runner_exe);
    run_zig_facade.addArg(b.pathFromRoot("test/realworld/wasm"));
    const test_api_zig_facade_step = b.step("test-api-zig-facade", "Run each realworld fixture through the native Zig API (Engine/Module/Instance)");
    test_api_zig_facade_step.dependOn(&run_zig_facade.step);

    // `zig build test-wasi-p1` — Phase 4 / §9.4 / 4.9. Walks
    // `test/wasi/` driving each .wasm fixture through
    // `cli_run.runWasm`, comparing the exit code against the
    // matching `<basename>.expected_exit` file.
    const wasi_runner_mod = createSanitizedModule(b, sanitize_opts, .{
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
    // `libzwasm.a` from the shared `core` module (rooted at
    // `src/zwasm.zig` per ADR-0024 D-1), compiles
    // `examples/c_host/hello.c` against `include/wasm.h`, links
    // the two, and runs the resulting executable. The C host
    // exits 0 on success (printed result == 42).
    const c_api_lib = b.addLibrary(.{
        .name = "zwasm",
        .linkage = .static,
        .root_module = core,
    });

    const c_host_mod = createSanitizedModule(b, sanitize_opts, .{
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
    test_all_step.dependOn(&run_core_tests.step);
    test_all_step.dependOn(&run_cli_tests.step);
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
    // §10 / 10.T-2b: wasm-3.0 assertion runner skeleton — enumerates
    // baked manifests, exits clean. Adopts JIT-execute as impl rows
    // 10.M / 10.R / 10.TC / 10.E / 10.G land.
    test_all_step.dependOn(&run_wasm_3_0_assert.step);
    test_all_step.dependOn(&run_wasmtime_misc_basic.step);
    test_all_step.dependOn(&run_wast_runtime_smoke.step);
    test_all_step.dependOn(&run_c_host.step);
    test_all_step.dependOn(&run_wasi_p1.step);
    // §9.7 / 7.8 row close (D-045 chunks 1-14 fully discharged):
    // wire test-spec-assert into test-all on ALL hosts. Three-host
    // exit-criterion measurement at row close:
    //   Mac aarch64       : 212 passed, 0 failed, 20 skipped
    //   OrbStack Linux    : 212 passed, 0 failed, 20 skipped
    //   windowsmini Win   : 212 passed, 0 failed, 20 skipped
    // skip-adr-text-format = 20, skip-impl = 0 per ADR-0029.
    test_all_step.dependOn(&run_spec_assert.step);
    // §9.9 / 9.9-h-13 (post-D-078 (c) close): wire `test-spec-simd`
    // into `test-all` on ALL hosts. Both Mac aarch64 + OrbStack
    // Linux x86_64 are now at 0 FAIL on the SIMD spec corpus
    // (11270/0 each post-§9.9-h-12), so this aggregation no
    // longer breaks the gate. Preventive — surfaces silent
    // x86_64 SIMD regressions in the autonomous `/continue` loop
    // (per `LOOP.md` "Parallel test gate" 2-host subset).
    // windowsmini reconciliation runs at phase boundary
    // separately per ADR-0049.
    test_all_step.dependOn(&run_simd_assert.step);
    // §9.9 / 9.9-l-1b (per ADR-0057): wire the new
    // non-SIMD wasm-2.0 scalar assertion runner. The curated
    // corpus lands in a follow-up (k-1); the runner gracefully
    // reports "0 manifests" against the missing directory so this
    // dependOn doesn't break test-all on a clean checkout.
    test_all_step.dependOn(&run_non_simd_assert.step);
    // §9.9 / 9.9-j-2 (per ADR-0056 §9.9 scope extension): wire two
    // runners that were "documented exit criterion measurement
    // points" but never CI-gated.
    //
    // test-realworld-run-jit reports RUN-PASS / FAIL
    // classifications; its 40+ RUN-PASS floor is §9.7 / 7.9-a's
    // exit criterion.
    //
    // test-wasmtime-misc-runtime (today 266/0/0 with panics
    // resolved) is the only runtime-asserting runner for non-SIMD
    // wasm-2.0 features — ADR-0056's discovery #1 ("non-SIMD spec
    // coverage is fake green") surfaces it as the bridge until
    // 9.9-l-1 lands the non-SIMD spec_assert_runner. The block at
    // line 333-343 above (NOT in test-all) is now historical; the
    // panic gap referenced there has closed.
    //
    // §9.9 / 9.9-m-5 (per ADR-0056): test-edge-cases wired into
    // test-all on all hosts. D-087 (x86_64 trunc trap), D-088
    // (x86_64 div_s/rem_s overflow trap), and D-089 (Linux
    // ld.so dl-fini assertion) all discharged together by
    // extending the `uses_runtime_ptr` whitelist (emit.zig) to
    // include div / rem / trunc_trap ops — these emit trap-stub
    // fixups that write `[r15 + trap_flag_off]`, which requires
    // R15 to hold the runtime ptr. Without R15 initialised, the
    // trap store hits a garbage address; trap_flag stays 0 (runner
    // sees value-return instead of trap) AND adjacent memory
    // corruption manifests as the dl-fini assertion at process
    // exit. Single-cause cohort: 8 fixtures pass + assertion gone.
    // Mac 35/0 + OrbStack 35/0 post-fix.
    test_all_step.dependOn(&run_edge_p7.step);
    test_all_step.dependOn(&run_edge_p9.step);
    test_all_step.dependOn(&run_edge_p10.step);
    test_all_step.dependOn(&run_edge_realworld_p10.step);
    test_all_step.dependOn(&run_realworld_run_jit.step);
    test_all_step.dependOn(&run_wasmtime_misc_runtime.step);
    test_all_step.dependOn(&run_zig_facade.step);

    // `zig build run-repro -Dtask=<name>` — discover
    // `private/dbg/<task>/repro.zig`, link it against the zwasm
    // library, and run it. Per ADR-0015 §Decision Part 4 / §9.6 /
    // 6.K.7. Silent (non-failing) when -Dtask is unset, so
    // `zig build` itself stays unaffected; running the step
    // without -Dtask prints the usage hint.
    const repro_step = b.step("run-repro", "Run private/dbg/<task>/repro.zig (-Dtask=<name>)");
    if (repro_task) |task| {
        const repro_path = b.fmt("private/dbg/{s}/repro.zig", .{task});
        const repro_mod = createSanitizedModule(b, sanitize_opts, .{
            .root_source_file = b.path(repro_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        repro_mod.addImport("zwasm", zwasm_lib_mod);
        const repro_exe = b.addExecutable(.{
            .name = b.fmt("zwasm-repro-{s}", .{task}),
            .root_module = repro_mod,
        });
        const run_repro = b.addRunArtifact(repro_exe);
        repro_step.dependOn(&run_repro.step);
    } else {
        const print_usage = b.addSystemCommand(&.{
            "/bin/sh",                                                                                     "-c",
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

/// Bundle of sanitizer settings derived from `-Dsanitize`.
/// Constructed once in `build()` and reused at each
/// `createSanitizedModule` call site (D-016 discharge).
pub const SanitizeOpts = struct {
    c: ?std.zig.SanitizeC,
    thread: ?bool,
};

/// Create a `*std.Build.Module` and apply the active sanitizer
/// settings in one call. Replaces the prior
/// `b.createModule + applySanitize` two-step pattern that
/// appeared at 17 call sites across this file.
///
/// Per ADR-0015 §Decision Part 2 / §9.6 / 6.K.7: `.full` enables
/// LLVM AddressSanitizer + UBSan; `sanitize_thread` enables
/// ThreadSanitizer. Mac aarch64 + Linux x86_64 only — on Windows
/// both fields are null and this is a pure `createModule`
/// passthrough.
fn createSanitizedModule(
    b: *std.Build,
    sopts: SanitizeOpts,
    mod_opts: std.Build.Module.CreateOptions,
) *std.Build.Module {
    const mod = b.createModule(mod_opts);
    if (sopts.c) |s| mod.sanitize_c = s;
    if (sopts.thread) |t| mod.sanitize_thread = t;
    return mod;
}
