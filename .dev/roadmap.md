# zwasm Roadmap

Independent Zig-native WebAssembly runtime — library and CLI tool.
Benchmark target: **wasmtime**. Optimization target: ARM64 Mac first.

**Library Consumer Guarantee**: ClojureWasm depends on zwasm main via GitHub URL.
All development on feature branches; merge to main requires Merge Gate.

## Completed (v1.2.0)

Stages 0-46 complete. Details: `roadmap-archive.md`.

- Wasm 3.0: all 9 proposals (581+ opcodes). WASI P1 46/46. WAT parser.
- JIT: Register IR + ARM64/x86_64. Spec: 62,263/62,263 (100%, 0 skip).
- E2E: 792/792 (0 leak). Real-world: 50/50. Fuzz: 10K+ iterations, 0 crashes.
- Size: 1.20MB stripped / 4.48MB RSS. Mac + Ubuntu x86_64.

## Future Phases (zwasm only)

Integrated roadmap (zwasm + CW): `private/future/03_zwasm_clojurewasm_roadmap_ja.md`
CW-specific phases (2, 4, 6, 7, 9, 14, 16, 17) are in that document only.

### Phase 1: Guard Pages + Module Cache — COMPLETE

Performance impact: highest of remaining items. Improvements propagate to CW.

**1.1 Virtual Memory Guard Pages — COMPLETE**

Already implemented: guard.zig (mmap/mprotect/signal handler), memory.zig (initGuarded),
store.zig (auto-use when JIT supported), jit.zig/x86.zig (bounds check elimination),
cli.zig (signal handler install).

**1.2 Module Cache / AOT Serialize — COMPLETE (D124)**

- `cache.zig`: serialize predecoded IR to `~/.cache/zwasm/<hash>.zwcache`
- `zwasm run --cache` option + `zwasm compile` command
- Cache invalidation: SHA-256 hash + version field
- All tests pass (spec 62,263/62,263, E2E 792/792, real-world 50/50)

**Gate**: PASSED. zwasm v1.3.0 candidate.

### Phase 3: CI Automation + Documentation — COMPLETE

**3.1 CI Automation**

- `.github/tool-versions`: centralized WASM_TOOLS, WASMTIME, WASI_SDK versions
- `spec-bump.yml`: weekly spec testsuite auto-bump (Monday 04:00 UTC)
- `wasm-tools-bump.yml`: monthly wasm-tools version update (1st, 05:00 UTC)
- `spectec-monitor.yml`: weekly SpecTec change detection (Monday 06:00 UTC)
- `nightly.yml`: re-enabled as weekly (Wednesday 03:00 UTC)
- D125 decision record, `.dev/proposal-watch.md`

**3.2 Documentation**

- `ARCHITECTURE.md`: pipeline diagram + 28-file map + test suites
- `docs/data-structures.md`: key types by pipeline stage
- `//!` doc comments on fuzz harness files
- `Affected files:` references on all D100-D125 decisions

**Gate**: PASSED.

### Phase 5: C API + Conditional Compilation — COMPLETE

**5.1 C API (D126)**

- `src/c_api.zig`: 25 exported `zwasm_*` functions via C ABI
  - Module lifecycle: `new`, `new_wasi`, `new_wasi_configured`, `new_with_imports`, `delete`, `validate`
  - Invocation: `invoke`, `invoke_start`
  - Memory: `memory_data`, `memory_size`, `memory_read`, `memory_write`
  - Exports: `export_count`, `export_name`, `export_param_count`, `export_result_count`
  - WASI config: `wasi_config_new/delete/set_argv/set_env/preopen_dir`
  - Host imports: `import_new/delete/add_fn`
  - Error: `last_error_message`
- `include/zwasm.h`: single C header
- `libzwasm.so` / `.dylib` / `.a` build targets (`zig build lib`)
- C tests (`test/c_api/test_basic.c`), C example, Python ctypes example

**5.2 Conditional Compilation (D127)**

- Feature flags: `-Djit=false`, `-Dcomponent=false`, `-Dwat=false`
  (SIMD/GC/threads flags defined but not yet guarded — low savings)
- Minimal build: ~940KB stripped (24% reduction from full)
- CI `size-matrix` job: 5 build variants

**Gate**: PASSED.

### Phase 8: Real-World Coverage + WAT Parity — COMPLETE

**8.1 Real-World Coverage: 50 programs**

- TinyGo (4), C (9), C++ (1), Go (2), Rust (4) + existing (30) = 50
- Stress tests: deep recursion, large memory, many functions
- W30 JIT bug: five codegen fixes (guard recovery, instrDefinesRd,
  callee-saved liveness, x86 emitCall, emitInlineSelfCall ordering)
- Deferred: SQLite + Lua (complex wasm, future work)

**8.2 WAT Spec Parity: 100%**

- WAT roundtrip: 62,259/62,259 (100%)
- 708 conv-fail = wasm-tools can't convert malformed .wasm (expected)

**Gate**: PASSED. Mac + Ubuntu compat 50/50, spec 62,263/62,263, E2E 792/792.

### Phase 10: Quality / Stabilization (zwasm portion, 1 day)

- Full test suite re-verification (Mac + Ubuntu)
- Benchmark regression check
- Size guard confirmation (≤ 1.5MB)
- Merge Gate pass

**Gate**: All test suites pass. No regressions.

### Phase 11: Allocator Injection + Embedding (D128, 2 days)

Host-driven memory management for embedding scenarios.
Design reference: `.dev/references/allocator-injection-plan.md`.

**11.1 CW Finalizer (ClojureWasm side)**

- Add `deinit()` call in CW GC sweep for `wasm_module` tagged Values
- Fixes memory leak: zwasm internal memory released when CW GC collects wrapper
- Keep `smp_allocator` (non-GC) — do NOT inject CW GC allocator into zwasm

**11.2 C API Config + Allocator Callback Injection**

- `zwasm_config_t` with `set_allocator(alloc_fn, free_fn, ctx)`
- `zwasm_module_new_configured(bytes, len, config)` — NULL config = default GPA
- Wrap C function pointers as `std.mem.Allocator` (vtable adapter)
- Test: counting allocator verifying all allocs freed on module delete

**11.3 Documentation**

- ARCHITECTURE.md: allocator flow diagram + embedding section
- `docs/embedding.md`: Zig/C/Python/Go embedding guide, GC host pattern
- Book chapter (merges with Phase 18.1)

**Gate**: PASSED. Mac + Ubuntu all tests pass. v1.5.0 tagged.

### Phase 13: SIMD JIT (D130)

Largest technical challenge. Long-lived branch: `phase13/simd-jit`.
Research: `.dev/references/simd-jit-research.md`.
Rules: `.claude/rules/simd-jit.md`.

Each step implements ARM64 + x86 simultaneously. 252 opcodes total.
Real-world benefit arrives only after near-full coverage (D3 finding).

**13.0 Foundation: Float register class + infrastructure**

- Add `RegClass.Float` to regalloc.zig (v128 + FP share physical regs)
- Float spill slots (16 bytes) separate from GP spill (8 bytes)
- `comptime if (enable_simd)` scaffolding in jit.zig, build.zig
- Create `simd_arm64.zig`, `simd_x86.zig` (empty stubs)
- Verify: `-Dsimd=false` still works, no regression

**13.1 v128 load/store/const**

- `v128.load`, `v128.store`, `v128.const`
- Splat loads: `v128.load8/16/32/64_splat`
- Extending loads: `v128.load8x8_s/u`, `v128.load16x4_s/u`, `v128.load32x2_s/u`
- Zero-extending: `v128.load32_zero`, `v128.load64_zero`
- Lane load/store: `v128.load/store{8,16,32,64}_lane`
- ARM64: LDR Q / STR Q / LDP / STP / DUP / MOV
- x86: MOVDQU / MOVDQA / MOVD / PINSRB etc.

**13.2 Integer arithmetic + bitwise**

- i8x16/i16x8/i32x4/i64x2: add, sub, mul, neg, abs
- Saturating: add_sat, sub_sat (i8x16, i16x8)
- Min/max: min_s/u, max_s/u
- Shifts: shl, shr_s, shr_u
- Bitwise: v128.and, or, xor, not, andnot, bitselect, any_true
- All-true: i8x16.all_true, i16x8.all_true, etc.
- Popcnt: i8x16.popcnt
- ARM64: ADD.16B/8H/4S/2D, SSHL, USHL, CNT, etc.
- x86: PADDB/W/D/Q, PMULLW/D, PAND, POR, PXOR, PCMPEQ, PTEST, etc.

**13.3 Float arithmetic**

- f32x4/f64x2: add, sub, mul, div, neg, abs, sqrt
- Min/max: min, max, pmin, pmax
- Rounding: ceil, floor, trunc, nearest
- ARM64: FADD.4S/2D, FMUL, FDIV, FSQRT, FRINTX, etc.
- x86: ADDPS/PD, MULPS/PD, DIVPS/PD, SQRTPS/PD, ROUNDPS/PD, etc.

**13.4 Comparison + select + splat + lane ops**

- i8x16/i16x8/i32x4/i64x2: eq, ne, lt_s/u, le_s/u, gt_s/u, ge_s/u
- f32x4/f64x2: eq, ne, lt, le, gt, ge
- Splat: i8x16/i16x8/i32x4/i64x2/f32x4/f64x2.splat
- Extract/replace lane (14 ops)
- ARM64: CMEQ, CMGT, CMHI, FCMEQ, FCMGT, DUP, INS, UMOV/SMOV
- x86: PCMPEQB/W/D, PCMPGTB/W/D, CMPEQPS/PD, PEXTRB/W/D/Q, PINSRB/W/D/Q

**13.5 Type conversion**

- Extend: i16x8.extend_low/high_i8x16_s/u, i32x4.extend_*, i64x2.extend_*
- Narrow: i8x16.narrow_i16x8_s/u, i16x8.narrow_i32x4_s/u
- Convert: f32x4.convert_i32x4_s/u, i32x4.trunc_sat_f32x4_s/u
- Promote/demote: f64x2.promote_low_f32x4, f32x4.demote_f64x2_zero
- ARM64: SXTL, UXTL, XTN, SQXTN, FCVTZS, SCVTF, FCVTL, FCVTN
- x86: PMOVSXBW/WD/DQ, PMOVZXBW, PACKSS/USWB, CVTDQ2PS, CVTTPS2DQ, etc.

**13.6 Shuffle/swizzle**

- `i8x16.shuffle` (16 immediate lane indices)
- `i8x16.swizzle` (runtime lane indices)
- ARM64: `TBL` (general), `DUP`/`EXT`/`UZP1`/`UZP2` (special patterns later)
- x86: `PSHUFB` (general fallback, requires SSSE3 ⊂ SSE4.1)
  Two-register shuffle: pshufb×2 + por. Special patterns deferred.
- Relaxed SIMD: i16x8.relaxed_q15mulr_s, relaxed_dot variants

**13.7 Real-world SIMD benchmark expansion**

- Collect SIMD-enabled wasm binaries (Emscripten -msimd128, Rust wasm32-wasi)
- Add to real-world compat suite (target: 5+ SIMD programs)
- wasmtime comparison: `bash bench/compare_runtimes.sh` with SIMD items
- Target: SIMD bench faster than scalar, gap vs wasmtime ≤ 5x

**13.8 Gate**

- Spec: 62,263+ pass (SIMD spec tests JIT-compiled, not interpreter fallback)
- SIMD bench: all 4 benchmarks SIMD faster than scalar
- `-Dsimd=false`: minimal build passes, binary ≤ 1.0 MB
- Full build: binary ≤ 1.5 MB, memory ≤ 4.5 MB RSS
- Mac + Ubuntu + Windows: all tests pass
- Benchmarks recorded: `bash bench/record.sh --id=13.8 --reason="SIMD JIT gate"`

**Gate**: SIMD bench faster than scalar. zwasm v2.0.0 candidate.

### Phase 15: Windows Port (3 days) — DONE (PR #8, D129)

- [x] D129 decision record (VEH, VirtualAlloc, CI strategy)
- [x] Memory management OS abstraction (mmap → VirtualAlloc) — `platform.zig`
- [x] Signal handler port (SIGSEGV → VEH) — `guard.zig`
- [x] JIT W^X port (VirtualProtect + FlushInstructionCache) — `jit.zig`
- [x] WASI filesystem Windows branch — `wasi.zig` HostHandle abstraction
- [x] CI Windows job + release binaries — `ci.yml`, `release.yml`
- [x] x86_64 JIT Win64 ABI (RCX/RDX/R8, shadow space) — `x86.zig`

**Gate**: Windows x86_64 all tests pass. 3-OS CI complete.

### Phase 19: JIT Reliability (2 days)

Make JIT a verifiably correct optimization layer over the interpreter.
Principle: interpreter is the source of truth; JIT must produce identical results.
All changes incremental — no existing behavior removed, only verification added.

**19.1 Differential Testing Infrastructure**

- Add `force_interpreter` flag to Vm — bypass JIT/RegIR, use stack interpreter
- Differential test harness: run same function via interpreter AND JIT, compare results
- Integrate into spec runner (`--diff` mode), fuzz harness, real-world compat
- Catches JIT-only bugs (W35, W36 class) automatically

**19.2 JIT Fuel Check at Back-Edges**

- Emit fuel decrement + conditional trampoline exit at loop back-edges
- ARM64: `ldr x0, [x20, #fuel_offset]; subs x0, x0, #1; str; b.mi exit`
- x86: `dec qword [vm+fuel_offset]; js exit`
- Remove `jitSuppressed()` fuel condition (keep profile/deadline suppression initially)
- Unblocks PR #6 (timeout support)

**19.3 W35 Interpreter OOB Fix** (reclassified: was "ARM64 JIT OOB")

Originally diagnosed as JIT-only, confirmed as **interpreter correctness bug**
(2026-03-22). Both `--interp` and JIT crash; wasmtime runs correctly.
Triggered by wasm codegen patterns new in rustc 1.93.1.

- wasm-tools dump diff (1.92.0 vs 1.93.1) → identify new patterns
- Binary search: which wasm function causes OOB? (strip/tracing)
- Minimal reproducer (.wat) → fix interpreter → verify JIT also fixed
- Unpin CI Rust version, verify real-world 50/50

**Gate**: serde_json 1.93.1 passes on zwasm. CI Rust unpinned. Spec/E2E/compat all pass.

### Phase 18: Book i18n + Lazy Compilation + CLI Extensions (3 days)

**18.1 Book i18n (1 day)**

- `book/en/` + `book/ja/` structure
- Japanese translation + language switcher

**18.2 Lazy Compilation (1 day)**

JIT deferred to first call. Trampoline → direct jump patch.

**18.3 CLI Extensions (1 day)**

- `zwasm dump` (detailed module dump)
- `zwasm bench` (built-in benchmark runner)
- `zwasm diff` (module comparison)
- Fuel API docs + Memory growth callback

## Future (timeline TBD)

| Item                                       | Condition                                       |
|--------------------------------------------|--------------------------------------------------|
| WasmGC ref type bridge (11.4)              | After Phase 11; externref/funcref host interop    |
| Stack Switching                            | Proposal reaches Phase 4                         |
| WASI P3 / Async                            | After wasmtime stabilizes                        |
| Copy-and-Patch JIT                         | When technique matures                           |
| GC collector upgrade (generational/Immix)  | D121 arena approach sufficient for now            |
| Liveness-based regalloc / LIRA             | Rejected (D116/D120), single-pass sufficient     |

## Version Milestones

| Version | Phases | Key Results |
|---------|--------|-------------|
| **v1.3.0** | 1, 3 | Guard pages, cache, CI automation, ARCHITECTURE.md |
| **v1.4.0** | 5, 8 | C API, conditional compilation, 50+ real-world, WAT parity |
| **v1.5.0** | 11     | Allocator injection, C API config, embedding docs |
| **v1.6.0** | 15     | Windows x86_64, 3-OS CI, platform abstraction      |
| **v1.7.0** | 19     | JIT differential testing, fuel check, W35 fix       |
| **v2.0.0** | 13     | SIMD JIT (NEON/SSE)                                |

## Benchmark History

| Milestone          | fib(35) | vs wasmtime |
|--------------------|---------|-------------|
| Stage 0 (baseline) | 544ms   | 9.4x        |
| Stage 3 (3.14)     | 103ms   | 2.0x        |
| Stage 5 (5.7)      | 97ms    | 1.72x       |
| Stage 23           | 91ms    | 1.8x        |
| Stage 25           | 52ms    | 1.0x        |
