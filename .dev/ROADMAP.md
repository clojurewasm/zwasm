# zwasm v2 — ROADMAP

> **Status of this document**
>
> The single authoritative plan for this project. It collapses the mission,
> principles, architecture, scope, phase plan, quality bar, and future
> decision points onto one page. The standard rule applies:
> **if anything elsewhere disagrees with this file, this file wins.**
>
> Detailed implementation discussions presuppose this document. Anything
> that contradicts it must go through an ADR (`.dev/decisions/`); ad-hoc
> deviations are not allowed. ADRs exist to record **deviations from this
> roadmap discovered during development**, not founding decisions —
> founding decisions live in §1–§14 below.
>
> History lives in git — see `git log -- .dev/ROADMAP.md` for diffs and
> `.dev/decisions/` for load-bearing later decisions. The amendment
> process itself is §18.

---

## 0. Table of contents

1. [Mission and differentiation](#1-mission-and-differentiation)
2. [Inviolable principles](#2-inviolable-principles)
3. [Scope: what we build, what we do not](#3-scope-what-we-build-what-we-do-not)
4. [Architecture](#4-architecture)
5. [Directory layout (final form)](#5-directory-layout-final-form)
6. [WebAssembly proposal tier system](#6-webassembly-proposal-tier-system)
7. [Concurrency design](#7-concurrency-design)
8. [WASI strategy](#8-wasi-strategy)
9. [Phase plan](#9-phase-plan)
10. [CLI / FFI design](#10-cli--ffi-design)
11. [Test strategy](#11-test-strategy)
12. [Performance and benchmarks](#12-performance-and-benchmarks)
13. [Commit discipline and work loop](#13-commit-discipline-and-work-loop)
14. [Forbidden actions (inviolable)](#14-forbidden-actions-inviolable)
15. [Future go/no-go decision points](#15-future-gono-go-decision-points)
16. [References](#16-references)
17. [Glossary](#17-glossary)
18. [Amendment policy](#18-amendment-policy)

---

## 1. Mission and differentiation

### 1.1 Mission

**A from-scratch redesign of zwasm: a standalone WebAssembly runtime
in Zig 0.16.0 that ships WebAssembly 3.0 conformance, wasm-c-api
ecosystem compatibility, and a dual-backend (interpreter + JIT-arm64
+ JIT-x86) single-pass JIT, with clean architecture from day 1.**

- **Wasm 3.0 first-class**: every Phase-5 proposal (multi-value, SIMD-128,
  memory64, reference types, exception handling, tail call, WasmGC,
  function references, extended-const, relaxed-simd) is in the
  architecture from day 1, not retrofitted.
- **wasm-c-api conformance**: `wasm.h` is the primary C ABI;
  `zwasm.h` extensions are subordinate.
- **Single-pass JIT for both ARM64 and x86_64** with a shared mid-IR
  (ZIR). Same compiler pipeline for in-memory JIT and on-disk AOT.
- **Three-OS first-class**: macOS aarch64, Linux x86_64, Windows
  x86_64 are all gated. Mac + OrbStack Ubuntu run locally; Windows
  x86_64 is verified through an SSH host (`windowsmini`) plus, eventually,
  GitHub-hosted runners.
- **Differential-tested**: interpreter ↔ JIT-arm64 ↔ JIT-x86
  three-way equivalence is the primary correctness gate.
- **No backwards compatibility with v1**: breaking the v1 ABI is
  intentional. Migration guide ships at v0.1.0.

### 1.2 v0.1.0 feature line — parity with zwasm v1

**v0.1.0 release = match what zwasm v1 main currently ships, plus
wasm-c-api standardisation:**

| Surface                    | zwasm v1 status (2026-04-30)                                   | zwasm v2 v0.1.0 commitment                       |
|----------------------------|----------------------------------------------------------------|--------------------------------------------------|
| Wasm 3.0 (9 proposals)     | Complete                                                       | Complete                                         |
| Wide arithmetic            | Complete                                                       | Complete                                         |
| Custom page sizes          | Complete                                                       | Complete                                         |
| WASI 0.1                   | Complete                                                       | Complete                                         |
| 4-platform JIT             | aarch64-darwin / aarch64-linux / x86_64-linux / x86_64-windows | Same                                             |
| Spec testsuite             | 62,263 / 62,263 (100 %, 0 skip)                                | Same                                             |
| Real-world samples         | 50/50 (Mac+Linux), 25/25 (Windows subset)                      | Same                                             |
| Binary footprint           | 1.20–1.60 MB stripped                                         | comparable (no fixed numeric target — see §12) |
| **wasm-c-api conformance** | **Custom ABI only**                                            | **Standard `wasm.h` + `zwasm.h` extensions**     |

### 1.3 v0.2.0 line and beyond (post-v0.1.0)

Explicitly **not** in v0.1.0 scope:

- **Component Model + WASI 0.2** — large surface, deferred to v0.2.0.
- **Threads + atomics** — Phase 4 proposal; deferred until WASI 0.2 settles.
- **Stack switching / WASI 0.3** — Phase 3 proposal; deferred.
- **Optimising tier (post-baseline)** — copy-and-patch / SSA mid-IR /
  cranelift-as-backend; gated by post-Phase-9 perf data.
- **RISC-V / s390x backends** — separate ADR each when demand appears.

### 1.4 Differentiation (3 axes)

| # | Axis                             | Edge over the field                                                                                                                                          |
|---|----------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 | **Single-binary CLI + library**  | wasmtime is heavier (~12 MB), wasm3 is too small for production WASI. zwasm sits in the lean-but-complete zone.                                              |
| 2 | **wasm-c-api drop-in**           | Hosts already targeting wasmtime can swap zwasm in by relinking. v1 had no such property.                                                                    |
| 3 | **Dual-backend single-pass JIT** | Most lean runtimes (wasm3, zware) are interpreter-only. Most JIT runtimes (wasmtime, wasmer) carry CLIF. zwasm pairs interp + single-pass JIT under one ZIR. |

### 1.5 Project name and branch

- **Project name** in all public docs and the published artifact: `zwasm`.
- Binary name: `zwasm`. Package name: `zwasm`.
- Working directory: `~/Documents/MyProducts/zwasm_from_scratch/`.
- Branch: `zwasm-from-scratch` — long-lived, branched from the v1
  charter commit (`517cc5a`).
- v1 reference: `~/Documents/MyProducts/zwasm/` (read-only; do not
  edit from this project).

---

## 2. Inviolable principles

These do not change between phases. Changing one requires an ADR.

| #   | Principle                                    | Effect                                                                                                                                                                                         |
|-----|----------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| P1  | **WebAssembly spec is ground truth**         | Spec test fail / skip is a release-blocker. If a test breaks, the design is wrong, not the test.                                                                                               |
| P2  | **Library and CLI in one binary**            | Single `zwasm` binary serves `run / compile / validate / inspect / features / wat / wasm`.                                                                                                     |
| P3  | **Cold-start is the primary metric**         | Compile pipeline is single-pass (no SSA optimisation passes). AOT mode (Phase 12) is the second answer.                                                                                        |
| P4  | **Zig 0.16 idioms**                          | `std.Io` DI, `*std.Io.Writer`, `packed struct`, `comptime`, `@branchHint`. No `std.Thread.Mutex`, no `std.io.AnyWriter`.                                                                       |
| P5  | **link_libc=false, host-side**               | All host math via Zig builtins (LLVM intrinsics). No libm. No MSVCRT.                                                                                                                          |
| P6  | **Single-pass compilation**                  | Decode → ZIR → regalloc → emit, four linear passes per function. No multi-pass IR optimisation.                                                                                             |
| P7  | **Both backends are equal**                  | Any feature that exists in `jit_arm64/` exists in `jit_x86/`. No "ARM64-only" or "x86-only" implementations.                                                                                   |
| P8  | **wasm-c-api is the C ABI primary**          | `zwasm.h` extensions are subordinate. ABI breakage requires an ADR (with deprecation window).                                                                                                  |
| P9  | **Knowledge compression by ROADMAP and ADR** | ROADMAP narrates the project; ADRs justify deviations from it. There is no per-task / per-concept chapter cadence.                                                                             |
| P10 | **v1 stays untouched, but is not copied**    | The v1 `main` is frozen for ClojureWasm. v2 work happens on `zwasm-from-scratch`. v1 source may be **read** as a textbook; **never copy-and-paste** — re-design every line.                   |
| P11 | **Three OS first-class**                     | macOS aarch64, Linux x86_64, Windows x86_64 are all gated locally (Mac + OrbStack + Windows-mini SSH).                                                                                         |
| P12 | **Differential testing is the oracle**       | Every test that runs a wasm module asserts `interp == jit` on the host's native backend. The two-platform gate (and Phase 14's CI matrix) gives `interp == jit_arm64 == jit_x86` transitively. |
| P13 | **Day-one ZIR sized for the full target**    | All Wasm 3.0 ops + Phase 3-4 proposal ops + JIT pseudo-ops are reserved as `ZirOp` slots from day 1. Implementation is staged; the type is not.                                                |
| P14 | **Optimisation lands last in commit order**  | Phases 1-10 = simplest correct implementation. Phase 15 = port v1's optimisation work (W43 / W44 / W45 / W54-class) onto the v2 substrate, where the slots already exist.                       |

### 2.1 Architecture rules (verifiable)

| #   | Rule                                                                                                                                         | Verified by                                      |
|-----|----------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------|
| A1  | Lower zones do not import upper zones                                                                                                        | `scripts/zone_check.sh --gate`                   |
| A2  | One file ≤ 1,000 lines (soft) / ≤ 2,000 lines (hard)                                                                                       | `scripts/file_size_check.sh`                     |
| A3  | Cross-arch backends do not import each other (`engine/codegen/arm64` ↔ `engine/codegen/x86_64`) per ADR-0023                                | `scripts/zone_check.sh --gate`                   |
| A4  | `ZIR.verify()` runs after every analysis pass                                                                                                | Inline in `src/ir/verifier.zig`; called per pass |
| A5  | Differential test gates every wasm-execution test (Phase 7+)                                                                                 | `zig build test-all`                             |
| A6  | ADR is required for: layer/contract change, ZIR shape change, C ABI surface change, phase order change, regression allowance, tier promotion | Reviewer checklist; pre-merge audit              |
| A7  | Mac native + OrbStack Ubuntu native = local pre-push gate                                                                                    | `.githooks/pre_push`                             |
| A8  | Windows x86_64 native verified via SSH (`windowsmini`) before any v0.1.0 release                                                             | `scripts/run_remote_windows.sh` (Phase 15+)      |
| A9  | Bench history is append-only                                                                                                                 | `bench/history.yaml` reviewed at every merge     |
| A10 | Spec test fail=0 / skip=0 is a merge gate (Phase 2+)                                                                                         | `zig build test-spec`                            |
| A11 | All paths are `snake_case`; no hyphens in file or directory names                                                                            | Reviewer; convention                             |
| A12 | Feature opcodes are added through dispatch-table registration, not pervasive build-time `if` branches                                        | §4.5 design                                     |
| A13 | v1 regression suite (test/wasmtime_misc/wast/ + 50 realworld + ClojureWasm guest) stays green from Phase 6 onward (ADR-0008; renamed per ADR-0012 §6.B)                       | `zig build test-wasmtime-misc-basic` + Phase-6 gate    |

---

## 3. Scope: what we build, what we do not

### 3.1 In scope (will be implemented for v0.1.0)

- Full WebAssembly 3.0 (all Phase 5 proposals — see §6).
- Wide arithmetic + custom page sizes (matching v1's coverage).
- WASI 0.1 (preview1) full surface.
- `wasm.h` (wasm-c-api) full conformance.
- `wasi.h` (wasmtime-compatible) full surface.
- `zwasm.h` extensions: allocator injection, fuel, wall-clock timeout,
  cancel flag, fast-path invoke (kind-less).
- Single-pass JIT for `aarch64-darwin`, `aarch64-linux`,
  `x86_64-linux`, `x86_64-pc-windows`.
- AOT compilation (`zwasm compile foo.wasm -o foo.cwasm`).
- Spec test runner driven by `zig build test-spec`.
- E2E test harness for realworld wasm samples.
- Fuzz infrastructure: corpus + edge-case generator + differential
  fuzz + overnight campaign.
- Bench harness with append-only `bench/history.yaml`, multi-arch
  per-merge recording (Mac directly, Linux via OrbStack, Windows via
  `windowsmini` SSH).

### 3.2 Out of scope permanently

- **Backwards compatibility with zwasm v1's `zwasm_module_t` API.**
  The v1 ABI is dropped; migration guide ships at v0.1.0.
- **Multi-tier optimising JIT** (V8 Liftoff + TurboFan style).
  Single-pass is the design. Future optimising tier is a post-v0.1.0
  ADR decision.
- **Dynamic Wasm code generation** at runtime by the host (security).
- **JS Promise Integration / Web CSP / ESM Integration** (web-only
  proposals).

### 3.3 Deferred to v0.2.0+ (re-evaluate later)

- **Component Model**: Phase 1 proposal currently; v0.2.0 entry point.
- **WASI 0.2 (preview2)**: requires Component Model.
- **WASI 0.3 (async / streams)**: requires stack-switching.
- **Threads + atomics**: post-WASI-0.2.
- **Shared-everything threads**: Phase 1 proposal; watch.
- **Stack switching**: Phase 3 proposal; gates WASI 0.3.
- **Optimising tier** (Phase 13+): copy-and-patch, SSA mid-IR, or
  cranelift-as-backend.
- **RISC-V / s390x backends**: separate ADR each.

---

## 4. Architecture

### 4.1 Four-zone layered (absolute dependency direction)

```
Zone 3: src/cli/                          -- CLI entry (cli/main.zig per ADR-0024) + subcommand
        src/api/                          -- C ABI export layer (wasm.h / wasi.h / zwasm.h impl)
                                          ↓ may import anything below

Zone 2: src/engine/                       -- runner + interp loop + codegen (shared / arm64 / x86_64 / aot)
        src/feature/                      -- VM-capability extensions: simd_128 / gc / exception_handling / tail_call / function_references / memory64 / threads (reserved) / stack_switching (reserved) / component (reserved)
        src/instruction/                  -- Stateless opcode impls grouped by Wasm version (wasm_1_0 / wasm_2_0 / wasm_3_0)
        src/wasi/                         -- WASI preview1 implementation
        src/diagnostic/                   -- Cross-cutting: Diagnostic + trace
                                          ↓ may import Zone 0+1

Zone 1: src/ir/                           -- ZIR + dispatch table type + lower + verifier + analysis (loop_info / liveness / const_prop)
        src/runtime/                      -- WASM Spec §4.2 Runtime Structure: Runtime / Engine / Store / Module / Value / Trap / Frame + instance/{instance, memory, table, global, func, element, data}
        src/parse/                        -- Parser + sections + ctx (wasm bytes → structured Module)
        src/validate/                     -- Validator (type stack + control stack)
                                          ↓ may import Zone 0 only

Zone 0: src/support/                      -- dbg, leb128 (minimal specific helpers)
        src/platform/                     -- jit_mem, signal, fs, time (OS abstractions)
                                          ↑ imports nothing above
```

Enforcement: `scripts/zone_check.sh --gate` parses every `@import`
and rejects upward-direction violations. Cross-arch
(`engine/codegen/arm64` ↔ `engine/codegen/x86_64`) imports are
also rejected (A3).

When Zone 0/1 needs to call Zone 2+ (rare), use the **VTable
pattern**: the lower zone declares the type, the upper zone installs
function pointers at startup.

### 4.2 ZIR (Zwasm Intermediate Representation) — full op catalogue

The architectural cornerstone (P13). Both the interpreter and the
JIT consume the same `ZirFunc`. Every op is reserved as a `ZirOp`
slot from day 1; implementation is staged across phases.

```zig
pub const ZirOp = enum(u16) {
    // ============================================================
    // Wasm 1.0 / MVP (the baseline)
    // ============================================================
    // control flow
    @"unreachable",
    @"nop",
    @"block",
    @"loop",
    @"if",
    @"else",
    @"end",
    @"br",
    @"br_if",
    @"br_table",
    @"return",
    @"call",
    @"call_indirect",

    // parametric
    @"drop",
    @"select",
    @"select_typed",   // ref-types-aware select

    // variable
    @"local.get",
    @"local.set",
    @"local.tee",
    @"global.get",
    @"global.set",

    // i32 const + arith + bit + cmp
    @"i32.const",
    @"i32.eqz", @"i32.eq", @"i32.ne",
    @"i32.lt_s", @"i32.lt_u", @"i32.gt_s", @"i32.gt_u",
    @"i32.le_s", @"i32.le_u", @"i32.ge_s", @"i32.ge_u",
    @"i32.clz", @"i32.ctz", @"i32.popcnt",
    @"i32.add", @"i32.sub", @"i32.mul",
    @"i32.div_s", @"i32.div_u", @"i32.rem_s", @"i32.rem_u",
    @"i32.and", @"i32.or", @"i32.xor",
    @"i32.shl", @"i32.shr_s", @"i32.shr_u", @"i32.rotl", @"i32.rotr",

    // i64 const + arith + bit + cmp
    @"i64.const",
    @"i64.eqz", @"i64.eq", @"i64.ne",
    @"i64.lt_s", @"i64.lt_u", @"i64.gt_s", @"i64.gt_u",
    @"i64.le_s", @"i64.le_u", @"i64.ge_s", @"i64.ge_u",
    @"i64.clz", @"i64.ctz", @"i64.popcnt",
    @"i64.add", @"i64.sub", @"i64.mul",
    @"i64.div_s", @"i64.div_u", @"i64.rem_s", @"i64.rem_u",
    @"i64.and", @"i64.or", @"i64.xor",
    @"i64.shl", @"i64.shr_s", @"i64.shr_u", @"i64.rotl", @"i64.rotr",

    // f32 const + arith + cmp
    @"f32.const",
    @"f32.eq", @"f32.ne", @"f32.lt", @"f32.gt", @"f32.le", @"f32.ge",
    @"f32.abs", @"f32.neg", @"f32.ceil", @"f32.floor", @"f32.trunc", @"f32.nearest", @"f32.sqrt",
    @"f32.add", @"f32.sub", @"f32.mul", @"f32.div", @"f32.min", @"f32.max", @"f32.copysign",

    // f64 const + arith + cmp
    @"f64.const",
    @"f64.eq", @"f64.ne", @"f64.lt", @"f64.gt", @"f64.le", @"f64.ge",
    @"f64.abs", @"f64.neg", @"f64.ceil", @"f64.floor", @"f64.trunc", @"f64.nearest", @"f64.sqrt",
    @"f64.add", @"f64.sub", @"f64.mul", @"f64.div", @"f64.min", @"f64.max", @"f64.copysign",

    // numeric conversion
    @"i32.wrap_i64",
    @"i32.trunc_f32_s", @"i32.trunc_f32_u",
    @"i32.trunc_f64_s", @"i32.trunc_f64_u",
    @"i64.extend_i32_s", @"i64.extend_i32_u",
    @"i64.trunc_f32_s", @"i64.trunc_f32_u",
    @"i64.trunc_f64_s", @"i64.trunc_f64_u",
    @"f32.convert_i32_s", @"f32.convert_i32_u",
    @"f32.convert_i64_s", @"f32.convert_i64_u",
    @"f32.demote_f64",
    @"f64.convert_i32_s", @"f64.convert_i32_u",
    @"f64.convert_i64_s", @"f64.convert_i64_u",
    @"f64.promote_f32",
    @"i32.reinterpret_f32",
    @"i64.reinterpret_f64",
    @"f32.reinterpret_i32",
    @"f64.reinterpret_i64",

    // memory load / store (i32 / i64 / f32 / f64)
    @"i32.load", @"i64.load", @"f32.load", @"f64.load",
    @"i32.load8_s", @"i32.load8_u", @"i32.load16_s", @"i32.load16_u",
    @"i64.load8_s", @"i64.load8_u", @"i64.load16_s", @"i64.load16_u",
    @"i64.load32_s", @"i64.load32_u",
    @"i32.store", @"i64.store", @"f32.store", @"f64.store",
    @"i32.store8", @"i32.store16",
    @"i64.store8", @"i64.store16", @"i64.store32",
    @"memory.size", @"memory.grow",

    // ============================================================
    // Wasm 2.0 additions (sign-extension, sat-trunc, bulk memory, ref types)
    // ============================================================
    // sign extension
    @"i32.extend8_s", @"i32.extend16_s",
    @"i64.extend8_s", @"i64.extend16_s", @"i64.extend32_s",

    // saturating truncation
    @"i32.trunc_sat_f32_s", @"i32.trunc_sat_f32_u",
    @"i32.trunc_sat_f64_s", @"i32.trunc_sat_f64_u",
    @"i64.trunc_sat_f32_s", @"i64.trunc_sat_f32_u",
    @"i64.trunc_sat_f64_s", @"i64.trunc_sat_f64_u",

    // bulk memory
    @"memory.copy", @"memory.fill", @"memory.init",
    @"data.drop",
    @"table.copy", @"table.init",
    @"elem.drop",

    // reference types
    @"ref.null", @"ref.is_null", @"ref.func",
    @"table.get", @"table.set", @"table.size", @"table.grow", @"table.fill",

    // ============================================================
    // Wasm 2.0: SIMD-128 (~236 ops total)
    // ============================================================
    // load / store
    @"v128.load", @"v128.store",
    @"v128.load8x8_s", @"v128.load8x8_u",
    @"v128.load16x4_s", @"v128.load16x4_u",
    @"v128.load32x2_s", @"v128.load32x2_u",
    @"v128.load8_splat", @"v128.load16_splat", @"v128.load32_splat", @"v128.load64_splat",
    @"v128.load32_zero", @"v128.load64_zero",
    @"v128.load8_lane", @"v128.load16_lane", @"v128.load32_lane", @"v128.load64_lane",
    @"v128.store8_lane", @"v128.store16_lane", @"v128.store32_lane", @"v128.store64_lane",

    // const / shuffle / lane
    @"v128.const",
    @"i8x16.shuffle", @"i8x16.swizzle",
    @"i8x16.splat", @"i16x8.splat", @"i32x4.splat", @"i64x2.splat",
    @"f32x4.splat", @"f64x2.splat",
    @"i8x16.extract_lane_s", @"i8x16.extract_lane_u", @"i8x16.replace_lane",
    @"i16x8.extract_lane_s", @"i16x8.extract_lane_u", @"i16x8.replace_lane",
    @"i32x4.extract_lane", @"i32x4.replace_lane",
    @"i64x2.extract_lane", @"i64x2.replace_lane",
    @"f32x4.extract_lane", @"f32x4.replace_lane",
    @"f64x2.extract_lane", @"f64x2.replace_lane",

    // i8x16 cmp + arith + bit
    @"i8x16.eq", @"i8x16.ne",
    @"i8x16.lt_s", @"i8x16.lt_u", @"i8x16.gt_s", @"i8x16.gt_u",
    @"i8x16.le_s", @"i8x16.le_u", @"i8x16.ge_s", @"i8x16.ge_u",
    @"i8x16.abs", @"i8x16.neg", @"i8x16.popcnt",
    @"i8x16.all_true", @"i8x16.bitmask",
    @"i8x16.narrow_i16x8_s", @"i8x16.narrow_i16x8_u",
    @"i8x16.shl", @"i8x16.shr_s", @"i8x16.shr_u",
    @"i8x16.add", @"i8x16.add_sat_s", @"i8x16.add_sat_u",
    @"i8x16.sub", @"i8x16.sub_sat_s", @"i8x16.sub_sat_u",
    @"i8x16.min_s", @"i8x16.min_u", @"i8x16.max_s", @"i8x16.max_u",
    @"i8x16.avgr_u",

    // i16x8 cmp + arith + bit
    @"i16x8.eq", @"i16x8.ne",
    @"i16x8.lt_s", @"i16x8.lt_u", @"i16x8.gt_s", @"i16x8.gt_u",
    @"i16x8.le_s", @"i16x8.le_u", @"i16x8.ge_s", @"i16x8.ge_u",
    @"i16x8.abs", @"i16x8.neg",
    @"i16x8.q15mulr_sat_s",
    @"i16x8.all_true", @"i16x8.bitmask",
    @"i16x8.narrow_i32x4_s", @"i16x8.narrow_i32x4_u",
    @"i16x8.extend_low_i8x16_s", @"i16x8.extend_high_i8x16_s",
    @"i16x8.extend_low_i8x16_u", @"i16x8.extend_high_i8x16_u",
    @"i16x8.shl", @"i16x8.shr_s", @"i16x8.shr_u",
    @"i16x8.add", @"i16x8.add_sat_s", @"i16x8.add_sat_u",
    @"i16x8.sub", @"i16x8.sub_sat_s", @"i16x8.sub_sat_u",
    @"i16x8.mul",
    @"i16x8.min_s", @"i16x8.min_u", @"i16x8.max_s", @"i16x8.max_u",
    @"i16x8.avgr_u",
    @"i16x8.extmul_low_i8x16_s", @"i16x8.extmul_high_i8x16_s",
    @"i16x8.extmul_low_i8x16_u", @"i16x8.extmul_high_i8x16_u",

    // i32x4 cmp + arith + bit
    @"i32x4.eq", @"i32x4.ne",
    @"i32x4.lt_s", @"i32x4.lt_u", @"i32x4.gt_s", @"i32x4.gt_u",
    @"i32x4.le_s", @"i32x4.le_u", @"i32x4.ge_s", @"i32x4.ge_u",
    @"i32x4.abs", @"i32x4.neg",
    @"i32x4.all_true", @"i32x4.bitmask",
    @"i32x4.extend_low_i16x8_s", @"i32x4.extend_high_i16x8_s",
    @"i32x4.extend_low_i16x8_u", @"i32x4.extend_high_i16x8_u",
    @"i32x4.shl", @"i32x4.shr_s", @"i32x4.shr_u",
    @"i32x4.add", @"i32x4.sub", @"i32x4.mul",
    @"i32x4.min_s", @"i32x4.min_u", @"i32x4.max_s", @"i32x4.max_u",
    @"i32x4.dot_i16x8_s",
    @"i32x4.extmul_low_i16x8_s", @"i32x4.extmul_high_i16x8_s",
    @"i32x4.extmul_low_i16x8_u", @"i32x4.extmul_high_i16x8_u",
    @"i32x4.trunc_sat_f32x4_s", @"i32x4.trunc_sat_f32x4_u",
    @"i32x4.trunc_sat_f64x2_s_zero", @"i32x4.trunc_sat_f64x2_u_zero",

    // i64x2 cmp + arith + bit
    @"i64x2.eq", @"i64x2.ne",
    @"i64x2.lt_s", @"i64x2.gt_s", @"i64x2.le_s", @"i64x2.ge_s",
    @"i64x2.abs", @"i64x2.neg",
    @"i64x2.all_true", @"i64x2.bitmask",
    @"i64x2.extend_low_i32x4_s", @"i64x2.extend_high_i32x4_s",
    @"i64x2.extend_low_i32x4_u", @"i64x2.extend_high_i32x4_u",
    @"i64x2.shl", @"i64x2.shr_s", @"i64x2.shr_u",
    @"i64x2.add", @"i64x2.sub", @"i64x2.mul",
    @"i64x2.extmul_low_i32x4_s", @"i64x2.extmul_high_i32x4_s",
    @"i64x2.extmul_low_i32x4_u", @"i64x2.extmul_high_i32x4_u",

    // f32x4 / f64x2 cmp + arith
    @"f32x4.eq", @"f32x4.ne", @"f32x4.lt", @"f32x4.gt", @"f32x4.le", @"f32x4.ge",
    @"f32x4.abs", @"f32x4.neg", @"f32x4.sqrt",
    @"f32x4.add", @"f32x4.sub", @"f32x4.mul", @"f32x4.div",
    @"f32x4.min", @"f32x4.max", @"f32x4.pmin", @"f32x4.pmax",
    @"f32x4.ceil", @"f32x4.floor", @"f32x4.trunc", @"f32x4.nearest",
    @"f32x4.convert_i32x4_s", @"f32x4.convert_i32x4_u",
    @"f32x4.demote_f64x2_zero",

    @"f64x2.eq", @"f64x2.ne", @"f64x2.lt", @"f64x2.gt", @"f64x2.le", @"f64x2.ge",
    @"f64x2.abs", @"f64x2.neg", @"f64x2.sqrt",
    @"f64x2.add", @"f64x2.sub", @"f64x2.mul", @"f64x2.div",
    @"f64x2.min", @"f64x2.max", @"f64x2.pmin", @"f64x2.pmax",
    @"f64x2.ceil", @"f64x2.floor", @"f64x2.trunc", @"f64x2.nearest",
    @"f64x2.convert_low_i32x4_s", @"f64x2.convert_low_i32x4_u",
    @"f64x2.promote_low_f32x4",

    // v128 bit / boolean
    @"v128.not", @"v128.and", @"v128.andnot", @"v128.or", @"v128.xor",
    @"v128.bitselect", @"v128.any_true",

    // ============================================================
    // Wasm 3.0 additions
    // ============================================================
    // memory64 — uses the same load/store ops with a memarg flag indicating 64-bit offset
    // (no new opcodes, but the memarg encoding carries `is_64`)
    @"memory.size_64",
    @"memory.grow_64",

    // exception handling
    @"try_table",
    @"throw",
    @"throw_ref",

    // tail call
    @"return_call",
    @"return_call_indirect",
    @"return_call_ref",

    // function references
    @"call_ref",
    @"ref.as_non_null",
    @"br_on_null",
    @"br_on_non_null",

    // GC: struct
    @"struct.new",
    @"struct.new_default",
    @"struct.get",
    @"struct.get_s",
    @"struct.get_u",
    @"struct.set",

    // GC: array
    @"array.new",
    @"array.new_default",
    @"array.new_fixed",
    @"array.new_data",
    @"array.new_elem",
    @"array.get",
    @"array.get_s",
    @"array.get_u",
    @"array.set",
    @"array.len",
    @"array.fill",
    @"array.copy",
    @"array.init_data",
    @"array.init_elem",

    // GC: ref / cast / extern conversion
    @"ref.test",
    @"ref.test_null",
    @"ref.cast",
    @"ref.cast_null",
    @"br_on_cast",
    @"br_on_cast_fail",
    @"any.convert_extern",
    @"extern.convert_any",

    // GC: i31
    @"ref.i31",
    @"i31.get_s",
    @"i31.get_u",

    // extended-const  (no new opcodes; const expression extension)

    // relaxed-simd
    @"i8x16.relaxed_swizzle",
    @"i32x4.relaxed_trunc_f32x4_s", @"i32x4.relaxed_trunc_f32x4_u",
    @"i32x4.relaxed_trunc_f64x2_s_zero", @"i32x4.relaxed_trunc_f64x2_u_zero",
    @"f32x4.relaxed_madd", @"f32x4.relaxed_nmadd",
    @"f64x2.relaxed_madd", @"f64x2.relaxed_nmadd",
    @"i8x16.relaxed_laneselect", @"i16x8.relaxed_laneselect",
    @"i32x4.relaxed_laneselect", @"i64x2.relaxed_laneselect",
    @"f32x4.relaxed_min", @"f32x4.relaxed_max",
    @"f64x2.relaxed_min", @"f64x2.relaxed_max",
    @"i16x8.relaxed_q15mulr_s",
    @"i16x8.relaxed_dot_i8x16_i7x16_s",
    @"i32x4.relaxed_dot_i8x16_i7x16_add_s",

    // wide arithmetic (matched to v1's coverage)
    @"i64.add128", @"i64.sub128",
    @"i64.mul_wide_s", @"i64.mul_wide_u",

    // custom page sizes (memory.discard + size variant tracked via memarg)
    @"memory.discard",

    // ============================================================
    // Phase 3-4 proposals — slots reserved, implementation deferred
    // ============================================================
    // threads / atomics
    @"memory.atomic.notify",
    @"memory.atomic.wait32", @"memory.atomic.wait64",
    @"atomic.fence",
    @"i32.atomic.load", @"i32.atomic.load8_u", @"i32.atomic.load16_u",
    @"i64.atomic.load", @"i64.atomic.load8_u", @"i64.atomic.load16_u", @"i64.atomic.load32_u",
    @"i32.atomic.store", @"i32.atomic.store8", @"i32.atomic.store16",
    @"i64.atomic.store", @"i64.atomic.store8", @"i64.atomic.store16", @"i64.atomic.store32",
    @"i32.atomic.rmw.add", @"i32.atomic.rmw.sub", @"i32.atomic.rmw.and", @"i32.atomic.rmw.or", @"i32.atomic.rmw.xor", @"i32.atomic.rmw.xchg", @"i32.atomic.rmw.cmpxchg",
    @"i64.atomic.rmw.add", @"i64.atomic.rmw.sub", @"i64.atomic.rmw.and", @"i64.atomic.rmw.or", @"i64.atomic.rmw.xor", @"i64.atomic.rmw.xchg", @"i64.atomic.rmw.cmpxchg",
    // (i32.atomic.rmw8.* / rmw16.* / i64.atomic.rmw8.* / rmw16.* / rmw32.* — also reserved when threads lands)
    @"i32.atomic.rmw8.add_u", @"i32.atomic.rmw8.sub_u", @"i32.atomic.rmw8.and_u", @"i32.atomic.rmw8.or_u", @"i32.atomic.rmw8.xor_u", @"i32.atomic.rmw8.xchg_u", @"i32.atomic.rmw8.cmpxchg_u",
    @"i32.atomic.rmw16.add_u", @"i32.atomic.rmw16.sub_u", @"i32.atomic.rmw16.and_u", @"i32.atomic.rmw16.or_u", @"i32.atomic.rmw16.xor_u", @"i32.atomic.rmw16.xchg_u", @"i32.atomic.rmw16.cmpxchg_u",
    @"i64.atomic.rmw8.add_u", @"i64.atomic.rmw8.sub_u", @"i64.atomic.rmw8.and_u", @"i64.atomic.rmw8.or_u", @"i64.atomic.rmw8.xor_u", @"i64.atomic.rmw8.xchg_u", @"i64.atomic.rmw8.cmpxchg_u",
    @"i64.atomic.rmw16.add_u", @"i64.atomic.rmw16.sub_u", @"i64.atomic.rmw16.and_u", @"i64.atomic.rmw16.or_u", @"i64.atomic.rmw16.xor_u", @"i64.atomic.rmw16.xchg_u", @"i64.atomic.rmw16.cmpxchg_u",
    @"i64.atomic.rmw32.add_u", @"i64.atomic.rmw32.sub_u", @"i64.atomic.rmw32.and_u", @"i64.atomic.rmw32.or_u", @"i64.atomic.rmw32.xor_u", @"i64.atomic.rmw32.xchg_u", @"i64.atomic.rmw32.cmpxchg_u",

    // stack switching (continuations)
    @"cont.new",
    @"cont.bind",
    @"resume",
    @"resume_throw",
    @"suspend",
    @"switch",

    // memory-control (additional to Wasm 3.0 memory.discard)
    @"memory.protect",

    // ============================================================
    // Pseudo opcodes — JIT-internal, populated Phase 7+ (when JIT v1 lands)
    // ============================================================
    @"__pseudo.const_in_reg",
    @"__pseudo.loop_header",
    @"__pseudo.loop_back_edge",
    @"__pseudo.loop_end",
    @"__pseudo.bounds_check_elided",
    @"__pseudo.phi_block_param",
    @"__pseudo.spill_to_slot",
    @"__pseudo.reload_from_slot",
    @"__pseudo.inst_ptr_cache_set",
    @"__pseudo.vm_ptr_cache_set",
    @"__pseudo.simd_base_cache_set",
    @"__pseudo.frame_setup",
    @"__pseudo.frame_teardown",

    _,  // open enum — future additions land here without renumbering
};
```

**`ZirFunc` shape — slots reserved day-1, populated per phase**:

```zig
pub const ZirFunc = struct {
    // Always present from Phase 1
    func_idx: u32,
    sig: FuncType,
    locals: []ValType,
    instrs: ArrayList(ZirInstr),
    blocks: ArrayList(BlockInfo),
    branch_targets: ArrayList(u32),

    // Populated Phase 5+ (analysis layer)
    loop_info: ?LoopInfo = null,
    liveness: ?Liveness = null,
    constant_pool: ?ConstantPool = null,

    // Populated Phase 7+ (JIT register allocator)
    reg_class_hints: ?[]RegClass = null,
    spill_slots: ?[]SpillSlot = null,
    inst_ptr_cache_layout: ?CacheLayout = null,
    vm_ptr_cache_layout: ?CacheLayout = null,
    simd_base_cache_layout: ?CacheLayout = null,

    // Populated Phase 9+ (SIMD additional state)
    simd_lane_routing: ?LaneRouting = null,

    // Populated Phase 10+ (GC / EH / tail call additional state)
    gc_root_map: ?GcRootMap = null,
    eh_landing_pads: ?[]LandingPad = null,
    tail_call_sites: ?[]TailCallSite = null,

    // Populated Phase 15+ (optimisation passes)
    hoisted_constants: ?[]HoistedConst = null,
    bounds_check_elision_map: ?[]ElisionRecord = null,
    coalesced_movs: ?[]CoalesceRecord = null,

    pub fn verify(self: *const ZirFunc, alloc: Allocator) Error!void { ... }
};
```

`ZIR.verify()` runs after every analysis pass. Each backend may
register arch-specific invariants (ARM64, x86) into the verifier.
CI runs `verify()` across the spec corpus.

### 4.3 Engine pipeline — interpreter / JIT / AOT share one path

```
[wasm bytes]
   │
   ▼  src/parse/  (parser → sections → ctx)
[Module]
   │
   ▼  src/validate/ (validator)
[validated Module]
   │
   ▼  src/ir/lower.zig
[ZIR]
   │
   ▼  src/ir/analysis/ (loop_info → liveness → const_prop) + ir/verifier
[ZIR (annotated)]
   │
   ▼  src/engine/runner.zig (dispatch via runtime.vtable)
   │
   ├── engine = interpreter ─┐
   │                          ▼
   │                   src/engine/interp/loop.zig (threaded-code dispatch)
   │                          │
   │                          ▼  execute (handlers from instruction/ + feature/)
   │
   └── engine = jit ──────────┐
                              ▼
                       src/engine/codegen/shared/  (regalloc + reg_class + linker + compile)
                              │
                              ▼  src/engine/codegen/arm64/  or  src/engine/codegen/x86_64/  (emit)
                       [machine code]
                              │
                              ├── JIT mode: in-memory pages (mprotect + jump)
                              │              ▼  execute
                              │
                              └── AOT mode: src/engine/codegen/aot/ (format + linker)
                                            │
                                            ▼  serialise to .cwasm
                                            │
                                            ▼  load (mmap) → execute
```

**Key invariant**: JIT and AOT share the **same compiler pipeline**.
The only difference is the output sink — in-memory pages versus a
serialised `.cwasm` file. This avoids two compilers, ensures
differential equivalence, and makes the optimisation work in Phase
14 land in one place.

### 4.4 wasm-c-api layered C ABI

```
include/wasm.h     # upstream wasm-c-api copy, fetched and pinned
include/wasi.h     # wasmtime-compatible WASI extension
include/zwasm.h    # zwasm extensions (allocator inj, fuel, cancel, fast invoke)
```

Implementation (per ADR-0023):

```
src/api/wasm.zig          # implements wasm.h (was c_api/wasm_c_api.zig)
src/api/wasi.zig          # implements wasi.h (was c_api/wasi_c_api.zig)
src/api/zwasm.zig         # implements zwasm.h (was c_api/zwasm_ext.zig)
src/api/vec.zig           # wasm_*_vec_t lifecycle helpers
src/api/trap_surface.zig  # Trap → wasm_trap_t marshal
src/api/cross_module.zig  # cross-module funcref dispatch
src/zwasm.zig             # library root + zone re-export hub (per ADR-0024;
                          # subsumes the former api/lib_export.zig role).
```

Mass-generation of vec-type lifecycle functions via `comptime`:
60 functions from one helper template.

`wasm.h` is fetched by `scripts/fetch_wasm_c_api.sh` from
`WebAssembly/wasm-c-api` at a pinned commit. CI runs the
wasm-c-api conformance suite.

### 4.5 Feature modules and dispatch-table registration (A12)

A core architectural decision: **per-spec-feature opcodes do not
appear as `if (build_options.gc)` branches sprinkled across the
parser, validator, lowerer, interpreter, and emitters.** Instead,
opcode implementations are registered into central dispatch tables
at module-load time.

Per ADR-0023, opcode-bearing code is split along **two axes**:

- **`src/instruction/wasm_X_Y/<category>.zig`** — stateless opcode
  families that add new instructions but do not change the VM's
  capability model. File axis follows WASM Spec §5.4 categories
  (numeric / parametric / variable / memory / control / ...) for
  Wasm 1.0, and proposal names (sign_extension / nontrap_conversion
  / bulk_memory / ...) for Wasm 2.0+. Each `.zig` file exposes
  `pub fn register(*DispatchTable)`.
- **`src/feature/<X>/`** — VM-capability extensions that introduce
  new runtime-state types, new type-system axes, ABI changes, or
  wholesale changes to JIT output shape. Each subtree is
  self-contained (register entry + ops + state files +
  per-arch emit).

```
src/instruction/
├── wasm_1_0/                                     # §5.4 categories
│   ├── numeric_int.zig
│   ├── numeric_float.zig
│   ├── numeric_conversion.zig
│   ├── parametric.zig
│   ├── variable.zig
│   ├── memory.zig
│   └── control.zig
├── wasm_2_0/                                     # proposal names
│   ├── sign_extension.zig
│   ├── nontrap_conversion.zig
│   ├── multi_value.zig
│   ├── bulk_memory.zig
│   └── reference_types.zig
└── wasm_3_0/
    ├── extended_const.zig                        # doc-comment-only file
    ├── wide_arith.zig
    └── custom_page_sizes.zig

src/feature/                                      # VM-capability extensions
├── simd_128/                                     # SIMD-128 + relaxed-simd
├── gc/                                           # WasmGC (managed heap)
├── exception_handling/
├── tail_call/
├── function_references/
├── memory64/
├── threads/                                      # README-only reserved
├── stack_switching/                              # README-only reserved
└── component/                                    # README-only reserved
```

Within each `feature/<X>/`, the standard layout is:

```
register.zig                                  # pub fn register(*DispatchTable)
ops.zig                                       # interp dispatch handlers
<subsystem>_state.zig (multiple)              # subsystem-private state
arm64.zig                                     # arm64 emit handlers
x86_64.zig                                    # x86_64 emit handlers
```

Each feature module exposes a `register` function:

```zig
// src/feature/ext_3_0/gc/mod.zig
pub fn register(table: *DispatchTable) void {
    table.parsers[@intFromEnum(ZirOp.@"struct.new")] = parseStructNew;
    table.interp [@intFromEnum(ZirOp.@"struct.new")] = interpStructNew;
    table.jit_arm64[@intFromEnum(ZirOp.@"struct.new")] = emitArm64StructNew;
    table.jit_x86 [@intFromEnum(ZirOp.@"struct.new")] = emitX86StructNew;
    // ...
}
```

At startup, each enabled feature module's `register` is invoked
once. The main parser / validator / interp / JIT consult the
dispatch table and do not branch on feature flags — the table is
simply populated or not.

**Feature build flags** (§4.6) control which feature modules are
included in the build, not pervasive `if` branches.

### 4.6 Build flags — coarse and orthogonal

```
-Dwasm=3.0|2.0|1.0          (default 3.0; 2.0 omits Phase-9 features; 1.0 omits SIMD too)
-Dwasi=preview1             (default preview1 at v0.1.0; preview2 lights up post-v0.1.0)
-Dengine=both|jit|interp    (default both; selects which engines are compiled in)
-Daot=true|false            (default false at v0.1.0; lights up Phase 8+)
-Denable=<feature>          (per-feature toggle within feature/; granular opt-out)
-Dapi=c|none                (default c; -Dapi=none drops api/ subtree for embed-only builds)
-Doptimize=Debug|ReleaseFast|ReleaseSafe|ReleaseSmall  (Zig standard)
-Dstrip=true|false          (default false; strips debug info from the CLI binary)
-Dtrace-ringbuffer=true|false (default false; compile in Diagnostic M3-a trace per ADR-0028)
```

Source-separation principle (A12): each feature module is its own
directory; the build system includes/excludes the directory based
on flags. There is **no `if (gc_enabled)`** in the parser /
validator / interp / emitter. The dispatch table is populated only
if `feature/gc/register.zig` was compiled in.

Zig's `comptime` makes this clean: the build system passes the set
of enabled feature modules to a comptime-generated `register_all`
function that inlines each feature's `register` call.

### 4.7 Runtime handle + std.Io DI

The Runtime struct lives at `src/runtime/runtime.zig` per ADR-0023:

```zig
pub const Runtime = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: Engine,         // wasm-c-api primary handle (runtime/engine.zig)
    stores: ArrayList(*Store),
    config: Config,         // fuel limit, timeout, allocator injection
    vtable: VTable,         // backend dispatch (engine/runner.zig dispatches via vtable)
};
```

`std.Io` is DI'd through every layer — no global mutexes, no
ambient I/O. The CLI (Zone 3) creates a `Runtime` and passes it
down. Tests construct a mock Runtime.

### 4.8 Float and SIMD strategy

- `link_libc = false` host-side (P5); all math via Zig builtins
  (`@sqrt`, `@ceil`, `@trunc`, `@round`) → LLVM intrinsics → SSE4.1
  / NEON.
- `f32.nearest` / `f64.nearest` (banker's rounding) implemented in
  `src/runtime/float.zig` (Zig `@round` is away-from-zero).
- `f32.min` / `f32.max` Wasm-NaN-propagating semantics implemented
  in `src/runtime/float.zig`.
- SIMD baseline: SSE4.1 (x86_64) and NEON (aarch64). SSE2-only
  fallback is rejected.

### 4.9 Memory model

- Linear memory is `mmap`-backed on POSIX, `VirtualAlloc` on Windows.
- Bounds check via guard pages (Phase 7+) — out-of-range access
  triggers `SIGSEGV` (POSIX) / `EXCEPTION_ACCESS_VIOLATION`
  (Windows), caught by the JIT's signal handler and converted to a
  Wasm trap.
- Memory64 is part of the ZIR shape from day 1; the implementation
  lights up in Phase 10.

### 4.10 GC subsystem (Phase 10+)

WasmGC adds heap-allocated typed values (struct, array, i31). Per
ADR-0023 the GC subsystem is vertically aggregated under
`src/feature/gc/` (state-heavy VM-capability extension):

- `register.zig` — `pub fn register(*DispatchTable)`
- `ops.zig` — `struct.*` / `array.*` / `ref.test` / `ref.cast` / `ref.i31` / `i31.get_*` handlers
- `heap.zig` — HeapHeader + 8-byte aligned tagged pointer scheme
- `arena.zig` — phase-scoped arena (Phase 1+, infrastructure only)
- `mark_sweep.zig` — mark-sweep collector (Phase 10+)
- `roots.zig` — root tracking (operand stack + locals + globals + tables)
- `type_hierarchy.zig` — struct / array subtyping + recursive types
- `arm64.zig`, `x86_64.zig` — per-arch emit handlers

GC values use a tagged pointer scheme (low 3 bits = type tag, since
heap is 8-byte aligned). i31ref is unboxed in the tag.

---

## 5. Directory layout (final form)

```
zwasm_from_scratch/
├── README.md                   # 1-line intro + build/test
├── CLAUDE.md                   # AI operational instructions
├── LICENSE                     # MIT
├── .envrc                      # use flake
├── .gitignore                  # zig-out, .zig-cache, private/, etc.
├── flake.nix                   # Zig 0.16.0 + hyperfine + yq + wabt
├── flake.lock                  # nix lock
├── build.zig                   # build script with -Dwasm / -Dwasi / -Dengine flags
├── build.zig.zon               # package metadata (real fingerprint)
│
├── include/
│   ├── wasm.h                  # upstream wasm-c-api (fetched, Phase 3+)
│   ├── wasi.h                  # WASI extension (Phase 4+)
│   └── zwasm.h                 # zwasm extensions (allocator inj Phase 4+; fuel/cancel Phase 7+)
│
├── src/                        # Per ADR-0023 + ADR-0024; see those ADRs for full per-file annotations.
│   ├── zwasm.zig               # Library root + zone re-export hub + self-import surface (per ADR-0024 D-1/D-2)
│   ├── parse/                  # WASM Binary Format → structured Module
│   │   ├── parser.zig
│   │   ├── sections.zig
│   │   └── ctx.zig
│   ├── validate/
│   │   └── validator.zig
│   ├── ir/                     # ZIR + analysis passes (loop_info / liveness / const_prop / verifier)
│   │   ├── zir.zig
│   │   ├── dispatch.zig        # central DispatchTable type
│   │   ├── lower.zig           # wasm-op → ZirOp
│   │   ├── verifier.zig
│   │   └── analysis/
│   ├── runtime/                # WASM Spec §4.2 "Runtime Structure"
│   │   ├── runtime.zig         # central Runtime handle
│   │   ├── engine.zig
│   │   ├── store.zig
│   │   ├── module.zig
│   │   ├── value.zig
│   │   ├── trap.zig
│   │   ├── frame.zig
│   │   └── instance/           # WASM Spec §4.2 "Instances"
│   │       ├── instance.zig
│   │       ├── memory.zig
│   │       ├── table.zig
│   │       ├── global.zig
│   │       ├── func.zig        # FuncEntity per ADR-0014
│   │       ├── element.zig
│   │       └── data.zig
│   ├── instruction/            # WASM Spec §5.4 categories — stateless opcode impls
│   │   ├── wasm_1_0/           # numeric_int, numeric_float, numeric_conversion, parametric, variable, memory, control
│   │   ├── wasm_2_0/           # sign_extension, nontrap_conversion, multi_value, bulk_memory, reference_types
│   │   └── wasm_3_0/           # extended_const (doc-only), wide_arith, custom_page_sizes
│   ├── feature/                # VM-capability extensions; vertical subtrees
│   │   ├── simd_128/           # SIMD-128 + relaxed-simd folded in
│   │   ├── gc/                 # WasmGC (managed heap)
│   │   ├── exception_handling/
│   │   ├── tail_call/
│   │   ├── function_references/
│   │   ├── memory64/
│   │   ├── threads/            # README-only reserved slot (post-v0.2.0)
│   │   ├── stack_switching/    # README-only reserved slot (post-v0.2.0)
│   │   └── component/          # README-only reserved slot (Component Model)
│   ├── engine/                 # interp / codegen sibling parity
│   │   ├── runner.zig          # public entry: invoke ZirFunc via runtime.vtable
│   │   ├── interp/
│   │   │   ├── loop.zig        # threaded-code dispatch loop
│   │   │   └── trap_audit.zig
│   │   └── codegen/
│   │       ├── shared/         # regalloc, reg_class, linker, compile, entry, prologue, jit_abi
│   │       ├── arm64/          # emit (orchestrator) + op_const/alu/memory/control/call + bounds_check + inst + abi + prologue + label
│   │       ├── x86_64/         # mirrors arm64/ (Phase 7.6+)
│   │       └── aot/            # format + linker (Phase 8+ / Phase 12)
│   ├── wasi/
│   │   ├── preview1.zig        # preview1 entry + register
│   │   ├── host.zig            # capability table
│   │   ├── fd.zig
│   │   ├── clocks.zig
│   │   └── proc.zig
│   ├── api/                    # wasm-c-api compatible C ABI (was c_api/)
│   │   ├── wasm.zig            # wasm.h impl (was wasm_c_api.zig)
│   │   ├── wasi.zig
│   │   ├── zwasm.zig
│   │   ├── vec.zig
│   │   ├── trap_surface.zig
│   │   └── cross_module.zig
│   ├── cli/                    # CLI exe entry + subcommands
│   │   ├── main.zig            # Juicy Main (CLI exe entry; per ADR-0024 D-4)
│   │   ├── run.zig
│   │   ├── compile.zig         # Phase 12
│   │   ├── validate.zig
│   │   ├── inspect.zig
│   │   ├── features.zig
│   │   ├── wat.zig             # Phase 11
│   │   ├── wasm.zig            # Phase 11
│   │   └── diag_print.zig
│   ├── platform/
│   │   ├── jit_mem.zig         # mmap (POSIX) / VirtualAlloc (Windows)
│   │   ├── signal.zig          # Phase 7+: SIGSEGV → trap
│   │   ├── fs.zig              # Phase 11: WASI fs adapter
│   │   └── time.zig
│   ├── diagnostic/             # cross-cutting (Ousterhout deep module)
│   │   ├── diagnostic.zig
│   │   └── trace.zig           # Phase 7+: trace ringbuffer per ADR-0016 M3
│   └── support/                # minimal specific helpers
│       ├── dbg.zig             # dev-only logger
│       └── leb128.zig          # encoding helper (parse + codegen/aot)
│
├── test/
│   ├── README.md
│   ├── unit/                   # mirrors src/
│   ├── spec/
│   │   ├── runner.zig
│   │   ├── wat/                # source .wat (committed)
│   │   └── json/               # wast2json output (gitignored, regenerated)
│   ├── e2e/
│   ├── realworld/
│   │   ├── src/                # C / Rust / Go sources (committed)
│   │   └── wasm/               # built artefacts (committed blobs)
│   ├── c_api_conformance/
│   └── fuzz/
│       ├── fuzz_loader.zig
│       ├── fuzz_gen.zig
│       └── corpus/             # gitignored
│
├── bench/
│   ├── README.md
│   ├── history.yaml            # append-only
│   ├── runners/                # bench wasm samples
│   └── fixtures/               # bench-specific data files
│
├── examples/
│   ├── c_host/
│   ├── zig_host/
│   └── rust_host/
│
├── docs/                       # English public docs (Phase 15+)
│   ├── reference/
│   ├── tutorial/
│   └── migration_v1_to_v2.md   # written at Phase 15
│
├── scripts/
│   ├── zone_check.sh
│   ├── file_size_check.sh
│   ├── gate_commit.sh
│   ├── gate_merge.sh
│   ├── record_merge_bench.sh
│   ├── run_bench.sh
│   ├── run_spec.sh
│   ├── run_remote_windows.sh   # Phase 15+ — drives the windowsmini SSH host
│   ├── regen_test_data.sh
│   ├── sync_versions.sh
│   ├── fetch_wasm_c_api.sh
│   └── check_md_tables.sh
│
├── .githooks/
│   ├── pre_commit
│   └── pre_push
│
├── .dev/
│   ├── README.md
│   ├── ROADMAP.md              # this file
│   ├── handover.md
│   ├── proposal_watch.md
│   ├── orbstack_setup.md
│   ├── windows_ssh_setup.md    # windowsmini SSH workflow
│   └── decisions/
│       ├── README.md
│       ├── 0000_template.md
│       └── NNNN_*.md           # written when ROADMAP deviations occur
│
├── .claude/
│   ├── settings.json
│   ├── output_styles/japanese.md
│   ├── skills/
│   │   ├── continue/SKILL.md
│   │   └── audit_scaffolding/{SKILL,CHECKS}.md
│   └── rules/
│       ├── zone_deps.md
│       ├── textbook_survey.md
│       ├── zig_tips.md
│       ├── no_workaround.md
│       ├── no_copy_from_v1.md
│       └── markdown_format.md
│
└── private/                    # gitignored agent scratch
```

**File-size discipline (A2)** (rubric finalised by ADR-0023):
- Soft cap 1,000 lines: warning + ADR for split plan.
- Hard cap 2,000 lines: gate fails; §A2 violation requires ADR.
- **Tests-split rubric**: production code ≤ 800 LOC requires
  inline `test "..."` blocks. Production code > 800 LOC and
  combined (production + tests) > 1,000 LOC permits a
  `<file>_tests.zig` companion file. Production code > 2,000
  LOC is the §A2 hard-cap violation regardless of test
  placement.
- Auto-generated files are exempt with `// AUTO-GENERATED FROM <source>`
  on lines 1-3.

**Naming (A11)**: all paths are `snake_case`. No hyphens in file or
directory names. Migrating from CW-v2-style hyphens (`gate-commit.sh`)
to snake_case happened during Phase 0 setup.

---

## 6. WebAssembly proposal tier system

The full live status is in `.dev/proposal_watch.md`. Summary:

| Tier        | Definition                    | zwasm intent                                    |
|-------------|-------------------------------|-------------------------------------------------|
| **Phase 5** | W3C Recommendation (Wasm 3.0) | **MUST** — implement in Phases 1–10 for v0.1.0 |
| **Phase 4** | Standardize                   | **Deferred to v0.2.0** for non-web items        |
| **Phase 3** | Implementation phase          | Per-feature judgement; mostly post-v0.1.0       |
| **Phase 2** | Proposed                      | Watch only                                      |
| **Phase 1** | Champion                      | Watch only                                      |

Tier promotions (Phase 4 → Phase 5) trigger a tier-promotion ADR
that updates `.dev/proposal_watch.md` and re-evaluates the phase
plan if the proposal hits Phase 5 during active development.

---

## 7. Concurrency design

- **Phases 0–10: single-threaded.** `Engine` is a process singleton;
  `Store` is host-thread-local.
- **Phase 11+:** multi-store, with `Engine` thread-safe (matches
  wasmtime convention). `wasm.h` allows shared modules; `zwasm.h`
  documents the safe sharing surface.
- **Wasm threads (atomics, shared memory)**: deferred to v0.2.0,
  after WASI 0.2 stabilises. ZIR slots are reserved (§4.2).
- **`std.Thread.Mutex` is forbidden** (Zig 0.16 removed it).
  Use `std.Io.Mutex` or `std.atomic.Mutex` only when concurrency
  actually arrives.
- **Cancellation** (`zwasm.h`'s `zwasm_module_cancel`): single
  atomic boolean checked at fuel-poll points. Phase 7+.

---

## 8. WASI strategy

- **WASI 0.1** (preview1): the realworld baseline. Phase 4 minimal
  subset; Phase 11 full surface.
- **WASI 0.2** (preview2): Component Model required. **Deferred to
  v0.2.0**.
- **WASI 0.3**: async / streams. Post-v0.2.0.

---

## 9. Phase plan

### Phase status (the tracker)

This widget is the canonical answer to "which phase is the agent
working on right now". `continue` reads it on every resume; `0.7`
of each phase advances it.

| Phase | State       | First open `[ ]` task         |
|-------|-------------|-------------------------------|
| 0     | DONE        | —                             |
| 1     | DONE        | —                             |
| 2     | DONE        | —                             |
| 3     | DONE        | —                             |
| 4     | DONE        | —                             |
| 5     | DONE        | —                             |
| 6     | DONE        | —                                                              |
| 7     | DONE        | —                                                              |
| 8     | DONE        | JIT optimisation foundation 🔒 (per ADR-0019)                  |
| 9     | IN-PROGRESS | SIMD-128                                                       |
| 10    | PENDING     | GC, EH, Tail call, memory64 (Wasm 3.0 完備) 🔒                 |
| 11    | PENDING     | WASI 0.1 full + bench infra                                    |
| 12    | PENDING     | AOT compilation mode                                           |
| 13    | PENDING     | C API full (wasm-c-api conformance) 🔒                         |
| 14    | PENDING     | CI matrix infrastructure                                       |
| 15    | PENDING     | Performance parity with v1 + ClojureWasm migration             |
| 16    | PENDING     | Public release v0.1.0 🔒                                       |

State values: `IN-PROGRESS` (one phase at a time), `PENDING`,
`DONE`. Update this table whenever §9.<N>.7 closes a phase or when
a phase first opens.

### Cadence

- Each phase has a **Goal**, **Exit criterion** (machine-verifiable),
  and possibly a **🔒 platform gate**.
- The `§9.<N>` task table is **inline-expanded when the phase
  opens**.
- Phase order is fixed; a phase swap requires an ADR.
- **No calendar estimates** — phases are task-driven, not
  time-driven. Pace is what the agent and the user can sustain.

### Phase 0 — Skeleton + scripts + local gate 🔒

**Goal**: empty `zwasm_from_scratch` repo becomes "implementable".

**Exit criterion**:

- `zig build` produces a `zwasm` binary that prints version and exits.
- `zig build test` passes (the placeholder `version` test).
- `bash scripts/zone_check.sh --gate` exits 0.
- `bash scripts/file_size_check.sh --gate` exits 0.
- `.githooks/pre_commit` and `pre_push` are wired (`git config
  core.hooksPath .githooks`).
- ROADMAP, CLAUDE.md, skills, rules, scripts in place.

**🔒 gate**: yes — Mac native AND OrbStack Ubuntu native must build
and `zig build test` green before Phase 1 opens.

#### §9.0 task list (expanded)

| #   | Description                                                                        | Status         |
|-----|------------------------------------------------------------------------------------|----------------|
| 0.0 | Bootstrap commit (the skeleton).                                                   | [x] 9bd21b2    |
| 0.1 | `zig build` succeeds on Mac native.                                                | [x] 9bd21b2    |
| 0.2 | `zig build` succeeds on OrbStack Ubuntu x86_64 native.                             | [x] 66814fb    |
| 0.3 | `zig build` succeeds on `windowsmini` via SSH.                                     | [x] 66814fb    |
| 0.4 | Wire `.githooks/pre_commit` and `pre_push`; `git config core.hooksPath .githooks`. | [x] 9bd21b2    |
| 0.5 | First green `zig build test` on Mac, OrbStack, windowsmini.                        | [x] 66814fb    |
| 0.6 | Phase-0 boundary audit_scaffolding pass.                                           | [x] 7f34b3f    |
| 0.7 | Open §9.1 inline; flip phase tracker.                                             | [x]            |

### Phase 1 — Frontend MVP

**Goal**: parse + validate any MVP-subset wasm; produce ZIR.

**Exit criterion**:

- WebAssembly Core 1.0 spec test corpus (MVP) decodes + validates
  with fail=0 / skip=0.
- Every `ZirOp` enum entry from §4.2 is **declared** (not necessarily
  implemented) — the type is up-front (P13).
- `src/frontend/parser.zig`, `validator.zig`, `lowerer.zig`,
  `src/ir/zir.zig`, `src/ir/dispatch_table.zig`,
  `src/util/leb128.zig` all in place.
- `src/feature/mvp/` registers MVP handlers via `register(*DispatchTable)`.

**🔒 gate**: no (interpreter not yet wired).

#### §9.1 task list (expanded)

| #    | Description                                                                                | Status         |
|------|--------------------------------------------------------------------------------------------|----------------|
| 1.0  | `src/util/leb128.zig` — unsigned/signed LEB128 read; red unit tests on edge values.       | [x] 922521f    |
| 1.1  | `src/ir/zir.zig` — ZIR slot / value-type skeleton (data shapes; no ops yet).              | [x] 9305414    |
| 1.2  | Declare the full `ZirOp` enum catalogue per §4.2 (declared, not implemented).             | [x] c2cd9b5    |
| 1.3  | `src/ir/dispatch_table.zig` — table type + `register(*DispatchTable)` API; smoke test.    | [x] d2578ea    |
| 1.4  | `src/frontend/parser.zig` — module header, section iteration, MVP-section decoders.       | [x] bbc5aca    |
| 1.5  | `src/frontend/validator.zig` — type stack, control stack, polymorphic else/end markers.   | [x] 73eaef9    |
| 1.6  | `src/frontend/lowerer.zig` — wasm-op → `ZirOp` lowering for the MVP subset.                | [x] 36c4834    |
| 1.7  | `src/feature/mvp/` — MVP feature handlers + `register(*DispatchTable)` wiring.            | [x] 702bc30    |
| 1.8  | Vendor the Wasm Core 1.0 spec corpus (read-only); add the `zig build test-spec` runner.   | [x] 8ab5b55    |
| 1.9  | Wasm Core 1.0 (MVP) spec corpus decodes + validates fail=0 / skip=0 on all three hosts.   | [x] 74a22ef    |
| 1.10 | Phase-1 boundary `audit_scaffolding` pass.                                                | [x] 3667b25    |
| 1.11 | Open §9.2 inline; flip phase tracker.                                                      | [x]            |

### Phase 2 — Interpreter MVP 🔒

**Goal**: ZIR is executable; spec test passes for Wasm 1.0 + 2.0.

**Exit criterion**:

- WebAssembly Core 2.0 spec test (MVP + multivalue + sign-ext +
  sat-trunc + bulk-memory + ref-types) fail=0 / skip=0 via the
  threaded-code interpreter.
- 5+ realworld samples (TinyGo hello, Rust hello, emcc factorial,
  WASI cat, AssemblyScript collection) run to completion.
- Trap-on-`i32.div_u 0`, `i32.trunc_f32_s` overflow, etc. — spec
  conformant.
- `zig build test --leak-check` reports zero leaks.

**🔒 gate**: yes — Mac + OrbStack + windowsmini (build only on
windowsmini; spec runner runs there too).

#### §9.2 task list (expanded)

| #    | Description                                                                                | Status         |
|------|--------------------------------------------------------------------------------------------|----------------|
| 2.0  | `src/interp/mod.zig` — interp scaffold (Runtime, frame stack, Value, Trap shapes).        | [x] 65434f1    |
| 2.1  | `src/interp/dispatch.zig` — threaded-code dispatch loop reading `DispatchTable.interp`.   | [x] 35e2184    |
| 2.2  | `src/feature/mvp/` interp handlers — wire MVP opcodes (numeric / control / memory).       | [x] 34aad78    |
| 2.3  | Wasm 2.0 features (sign-ext, sat-trunc, multivalue blocks, bulk-memory, ref-types).       | [x] b4b859f    |
| 2.4  | Trap semantics — `i32.div_u 0`, `i32.trunc_f32_s` overflow, OOB load/store, etc.          | [x] c9d0d4b    |
| 2.5  | `zig build test --leak-check` clean (`std.testing.allocator` zero-leak).                  | [x] 35c0c2e    |
| 2.6  | Realworld smoke (5+ samples: TinyGo / Rust / emcc / WASI cat / AssemblyScript).            | [x] 6af5c30    |
| 2.7  | Wasm 2.0 spec corpus extension to `test/spec/wasm-2.0/` + `.wast` directive handling.     | [x] 7b0d9c6    |
| 2.8  | Wasm Core 2.0 spec corpus fail=0 / skip=0 on Mac + OrbStack + windowsmini.                | [x] f51bce8    |
| 2.9  | Phase-2 boundary `audit_scaffolding` pass.                                                 | [x] a2e9c8b    |
| 2.10 | Open §9.3 inline; flip phase tracker.                                                      | [x]            |

### Phase 3 — C API minimal

**Goal**: a C host can `wasm_module_new` + `wasm_func_call` against
zwasm.

**Exit criterion**:

- `include/wasm.h` fetched from upstream and pinned via
  `scripts/fetch_wasm_c_api.sh`. ADR records the upstream commit hash.
- `src/c_api/wasm_c_api.zig` exports `wasm_engine_new`,
  `_module_new`, `_module_validate`, `_instance_new`, `_func_call`,
  vec types, trap.
- `examples/c_host/hello.c` builds and runs on all three OSes.

**🔒 gate**: no.

#### §9.3 task list (expanded)

| #    | Description                                                                                | Status         |
|------|--------------------------------------------------------------------------------------------|----------------|
| 3.0  | `scripts/fetch_wasm_c_api.sh` — fetch `wasm.h` verbatim from upstream + pin commit (ADR). | [x] 05bd4e4    |
| 3.1  | `include/wasm.h` vendored read-only; build.zig wires the include path.                    | [x] 19c5228    |
| 3.2  | `src/c_api/wasm_c_api.zig` — Zone-3 module, exports the C ABI shapes (engine/module/...). | [x] 9abb951    |
| 3.3  | `wasm_engine_new` / `wasm_engine_delete` — engine lifetime; allocator threading.          | [x] b4d1146    |
| 3.4  | `wasm_module_new` / `_module_validate` / `_module_delete` — wraps frontend pipeline.      | [x] 7c321d5    |
| 3.5  | `wasm_instance_new` / `_instance_delete` — wraps Runtime instantiation.                   | [x] 0417675    |
| 3.6  | `wasm_func_call` — wraps interp dispatch; param + result `wasm_val_t` marshalling.        | [x] 88e8d79    |
| 3.7  | `wasm_*_vec_t` types + `wasm_trap_t` — vec discipline, trap surface.                      | [x] c7784e4    |
| 3.8  | `examples/c_host/hello.c` — minimal C host invoking `wasm_func_call`.                     | [x] 2ee0cb8    |
| 3.9  | `zig build test-c-api` — gates the example builds + runs on all three hosts.              | [x] 414098b    |
| 3.10 | Phase-3 boundary `audit_scaffolding` pass.                                                 | [x] e06bbc2    |
| 3.11 | Open §9.4 inline; flip phase tracker.                                                      | [x]            |

### Phase 4 — WASI 0.1 minimal 🔒

**Goal**: TinyGo / Rust `_start` runs as a CLI.

**Exit criterion**:

- WASI 0.1 subset: `args_*`, `environ_*`, `clock_time_get`,
  `random_get`, `fd_close/read/write/seek/tell`, `path_open`,
  `proc_exit`, `poll_oneoff`.
- Realworld-diff infrastructure: runner + `.expected_stdout`
  byte-compare; 2 hand-rolled fixtures prove the end-to-end
  path. 30+ realworld guests against `wasmtime run` deferred
  to Phase 5 per ADR-0006.
- `zwasm run hello.wasm` works on all 3 OS.

**🔒 gate**: yes.

#### §9.4 task list (expanded)

| #    | Description                                                                                | Status         |
|------|--------------------------------------------------------------------------------------------|----------------|
| 4.0  | Hand-author `include/wasi.h` (host-setup C API) + ADR-0005 documenting the authorship.   | [x] 3327c86    |
| 4.1  | `src/wasi/p1.zig` — Zone-2 module declaring the WASI errno + ciovec / iovec / fdstat shapes. | [x] b12456a    |
| 4.2  | `src/wasi/host.zig` — capability table backed by `std.process.Init` (preopens, args, environ). | [x] 02ff981    |
| 4.3  | `proc_exit` / `args_get` / `args_sizes_get` / `environ_get` / `environ_sizes_get` handlers. | [x] b824f91    |
| 4.4  | `fd_write` / `fd_read` / `fd_close` / `fd_seek` / `fd_tell` (stdout/stderr/stdin only).   | [x] fafecf5    |
| 4.5  | `path_open` (preopen-rooted only; no parent-traversal) + `fd_fdstat_get` / `_set`.        | [x] 58ae2d1    |
| 4.6  | `clock_time_get` / `random_get` / `poll_oneoff` (stdin-only, blocking).                   | [x] 3537ac9    |
| 4.7  | Wire WASI imports into `wasm_instance_new` — match `(import "wasi_snapshot_preview1" …)`. | [x] 75992b2    |
| 4.8  | `zwasm run <path.wasm> [args...]` CLI subcommand drives `_start`.                         | [x] 894b9ce    |
| 4.9  | `test/wasi/` curated subset of wasi-testsuite + `zig build test-wasi-p1` runner.          | [x] fe61fc8    |
| 4.10 | Realworld-diff infrastructure (runner + stdout compare). 30+ fixture conformance → §9.5 (ADR-0006). | [x] aebdbc7    |
| 4.11 | Phase-4 boundary `audit_scaffolding` pass; 🔒 three-host gate confirmation.               | [x] 3788cc3    |
| 4.12 | Open §9.5 inline; flip phase tracker.                                                      | [x]            |

### Phase 5 — ZIR analysis layer

**Goal**: the slots reserved in Phase 1 are populated.

**Exit criterion**:

- `src/ir/loop_info.zig` (branch_targets, loop_headers, loop_end)
  computed for every parsed function.
- `src/ir/liveness.zig` (per-vreg live ranges) computed.
- `src/ir/verifier.zig` runs after every analysis pass; CI calls it
  on the spec corpus.
- `src/ir/const_prop.zig` (limited const folding).
- 30+ realworld WASI samples (out of the 50 from v1) run to
  completion with stdout matching `wasmtime run` (deferred
  from §9.4 / 4.10 per ADR-0006).

**🔒 gate**: no.

#### §9.5 task list (expanded)

| #    | Description                                                                                | Status         |
|------|--------------------------------------------------------------------------------------------|----------------|
| 5.0  | Split `src/c_api/wasm_c_api.zig` into trap_surface + vec + instance + wasi + wasm_c_api per ADR-0007. | [x] 2b26a07    |
| 5.1  | Split `src/interp/mvp.zig` into int_ops / float_ops / conversions modules.                | [x] c7fbe0d    |
| 5.2  | Carve `src/frontend/validator.zig` + `lowerer.zig` toward §A2 soft cap (per phase-2 audit). | [x] 64447ce    |
| 5.3  | `src/ir/loop_info.zig` — branch_targets, loop_headers, loop_end computed for every fn.    | [x] ccbd91b    |
| 5.4  | `src/ir/liveness.zig` — per-vreg live ranges computed.                                    | [x] bd29343    |
| 5.5  | `src/ir/verifier.zig` runs after every analysis pass; CI calls it on the spec corpus.     | [x] d22bd63    |
| 5.6  | `src/ir/const_prop.zig` — limited const folding.                                          | [x] 5215b87    |
| 5.7  | Phase-5 boundary `audit_scaffolding` pass.                                                 | [x] 15e2c82    |
| 5.8  | Open §9.6 inline; flip phase tracker.                                                      | [x]            |

(Realworld conformance rows formerly at §9.5 / 5.7-5.9 moved to
§9.6 / 6.1-6.3 by ADR-0008.)

### Phase 6 — v1 conformance baseline 🔒

**Goal**: enumerate exactly which v1-passing artefacts (regression
tests, realworld guest set, ClojureWasm guest set) fail under v2
interp, and bring them all to green **before any JIT or local-
optimisation complexity is introduced**. Established once at the
end of correctness work; carried forward as a green-must-stay
baseline through Phases 7-15 via the differential gate.

This Phase exists to keep the v1-vs-v2 divergence triage free of
JIT / regalloc / W54-class lattice noise (see ADR-0008 + P14 +
`no_workaround.md`).

**Exit criterion**:

- `test/wasmtime_misc/wast/` vendors v1's regression tests not
  already covered by spec testsuite (renamed from
  `test/v1_carry_over/` per ADR-0012 §6.B);
  `zig build test-wasmtime-misc-basic` runs them; fail=0 on all
  three hosts.
- All 50 realworld samples (Mac + Linux) run to completion under
  v2 interp — no `Errno.unreachable_` traps from missing ops.
- 30+ realworld samples match `wasmtime run` byte-for-byte stdout
  (the ADR-0006 target, retargeted from §9.4 / 4.10).
- ClojureWasm guest set runs end-to-end against zwasm v2 via
  `build.zig.zon` `path = ...` — no commits to ClojureWasm side
  required.
- `bench/baseline_v1_regression.yaml` records interp-only wall-
  clock numbers as the comparison floor for Phase 7+. Absolute
  speed irrelevant; spread + repeatability under noise matters.
- A13 (v1 regression suite stays green) wired into the merge gate.

**🔒 platform gate**: yes. Phase 7 (JIT v1 ARM64) cannot open
until Phase 6 is `DONE` on all three hosts. The Phase Status
widget enforces this.

#### §9.6 task list (expanded)

| #    | Description                                                                                              | Status         |
|------|----------------------------------------------------------------------------------------------------------|----------------|
| 6.0  | Vendor v1 regression tests not covered by spec testsuite into `test/wasmtime_misc/wast/` (renamed per ADR-0012 §6.B; was `test/v1_carry_over/`); add `zig build test-wasmtime-misc-basic` step (was `test-v1-carry-over`). | [x] 2a66d6a    |
| 6.1  | Realworld coverage — all 50 vendored samples run to completion under v2 interp on Mac + Linux; no `Errno.unreachable_` traps. | [x] 251c493    |
| 6.2  | Differential gate — 30+ realworld samples match `wasmtime run` byte-for-byte stdout (ADR-0006 target retargeted from §9.4 / 4.10). | REOPENED in Phase 6 per ADR-0011 |
| 6.3  | ClojureWasm guest set runs end-to-end against zwasm v2 via `build.zig.zon` `path = ...`; no commits to ClojureWasm side required. | REOPENED in Phase 6 per ADR-0011 |
| 6.4  | `bench/baseline_v1_regression.yaml` records interp-only wall-clock numbers as Phase-7+ comparison floor (spread + repeatability under noise; absolute speed irrelevant). | [ ] (reopened by ADR-0011 — was [x] 4f73288 on a trap-time baseline) |
| 6.5  | A13 (v1 regression suite stays green) wired into the merge gate.                                          | [x] 0825794    |
| 6.6  | Verifier CI hook — `test/spec/runner.zig` calls `ir/verifier.verify` after lowering each function (carry-over from §9.5 / 5.5). | [x] 9d029ef    |
| 6.7  | Phase-6 boundary `audit_scaffolding` pass.                                                                | [x] ba2f8cb    |
| 6.8  | Open §9.7 inline; flip phase tracker.                                                                     | [ ] (reopened by ADR-0011 — was [x] 0f52be6) |

##### §9.6 reopened scope (ADR-0012 §6, DAG order)

ADR-0012 introduces 10 work items 6.A〜6.J that operationalise
the §9.6 reopen. The original 6.0〜6.8 rows above stay as the
legacy framing (some `[x]` survive ADR-0011, some reopened); the
6.A〜6.J rows below define the actual work to strict-close
Phase 6 (100% PASS — see 6.J below for the single permitted
exception class and its documentation requirement).

| #    | Description                                                                                              | Status         |
|------|----------------------------------------------------------------------------------------------------------|----------------|
| 6.A  | Runtime-asserting WAST runner + per-instr trace (`test/runners/wast_runtime_runner.zig` + `src/interp/{mod,dispatch}.zig` trace plumbing). Per ADR-0013. | [x] `01e7c82` |
| 6.B  | `test/` restructure per ADR-0012 §3 + 4 `v1_carry_over/` fixtures migration + ROADMAP §A13 reword.        | [x] `1ba505d` |
| 6.C  | Vendor wasmtime_misc BATCH1-3 (~55 fixtures) into `test/wasmtime_misc/wast/{basic,reftypes,embenchen,issues}/`; introduce `scripts/setup_corpora.sh`. | [x] `5840666` (42 vendored, 13 queued for 6.E) |
| 6.D  | Wire 6.C corpus into `test-wasmtime-misc` step + `test-all` aggregate via 6.A runner; existing parse/instantiate runners kept as-is. | [x] `b10abef` (test-wasmtime-misc-runtime step wired) |
| 6.K.1 | Replace bare-funcidx `Value.ref` with `*FuncEntity` pointer encoding (instance-bearing funcref). Per ADR-0014 §2.1. | [x] `682f39a` |
| 6.K.2 | Single-allocator Runtime + Instance back-ref; drop `memory_borrowed`. Per ADR-0014 §2.1.                            | [x] `948320a` |
| 6.K.3 | Cross-module imports for table / global / func — drop `error.UnsupportedCrossModule*Import` (after 6.K.1 + 6.K.2). Per ADR-0014 §2.1. | [x] `ec0f5c5` |
| 6.K.4 | `decodeElement` forms 5 / 6 / 7 (parallel; per ADR-0014 §2.1).                                                      | [x] `1e22ca7` |
| 6.K.5 | Label arity formalisation + `.claude/rules/single_slot_dual_meaning.md` + §14 anti-pattern entry (parallel; per ADR-0014 §2.1). | [x] `635de85` |
| 6.K.6 | Re-measure `partial-init-table-segment/indirect-call` after 6.K.1〜6.K.3 (per ADR-0014 §2.1).                       | [x] `c7b4846` |
| 6.K.7 | Land `-Dsanitize=address` build option + `zig build run-repro -Dtask=<name>` step (per ADR-0015 §Decision Part 2 + Part 4). Mac + OrbStack only; Windows skip per ASan-ucrt gap. Parallel-eligible with 6.K.3〜6.K.6. | [x] `1c73588` |
| 6.K.8 | Land error diagnostic system **M1 only** — Diagnostic core (`runtime/diagnostic.zig`) + CLI render (`cli/diag_print.zig`) + `setDiag` at the six runWasm-boundary error tags + golden CLI test. M2 (frontend location), M3 (interp trap location + trace ringbuffer — closes the runner's `result[0] mismatch`), M4 (C-ABI accessors), M5 (backtraces) deliberately deferred per ADR-0016. | [x] `6c223a9` |
| 6.E  | Fix root cause of 39 trap-mid-execution realworld fixtures via 6.A's per-instr trace; move from trap-bucket to completion-bucket. **Re-measures after 6.K all-`[x]`** — the 28 misc-runtime fails this row's iter sequence accumulated all resolve through 6.K. | [x] `b569b8f` (266 PASS / 5 deferred via skip-ADRs) |
| 6.F  | `test-realworld-diff` 30+ byte-for-byte matches against wasmtime (original §9.6 / 6.2 strict close); re-add to `test-all`. | [x] `ccd537d` (39/50 matched, 0 mismatched) |
| 6.G  | ClojureWasm guest end-to-end (original §9.6 / 6.3 strict close). Substrate + mechanism documented in [`.dev/cw_guest_setup.md`](.dev/cw_guest_setup.md): 2026-05-04 procedure vendors CW v1 `bench/wasm/cljw_*.wasm` (CW v2's wasm backend lands at CW Phase 14+, deferred). Path-dep migration is procedural (file's "Removal / migration path" §) not a separate ROADMAP row. | [x] `0735f93` (5/5 PASS in parse + run + diff) |
| 6.H  | Bench honest-baseline migration: introduce `bench/results/{recent,history}.yaml` per ADR-0012 §7; regenerate baseline against completion-bucket fixtures. | [x] `841df04` (structural; hyperfine wiring at Phase 11) |
| 6.I  | `bench/` restructure per ADR-0012 §3; vendor 5 sightglass benchmarks with in-repo C source + documented build script. Parallel to 6.E〜6.H. | [x] `f3655f8` (5 vendored: noop / quicksort / richards / bz2 / gcc-loops) |
| 6.J  | Phase 6 **strict close** gate (100% PASS): three-host `test-all` green AND every aggregated runner reports 0 failed (no soft-skip, no tolerated nonzero) + `bench-quick` green Mac-only + `audit_scaffolding` pass + Phase Status widget flip via the standard `continue` skill handler (6 = DONE, 7 = IN-PROGRESS; no renumber). The **only permitted exception** to the 0-failed requirement is a v1-era design-dependent fixture that v2 deliberately rejects on spec-fidelity grounds (P1) — each must be documented in `.dev/decisions/skip_<fixture>.md` (what v1 did, what current spec requires, why v2 declines) AND removed from the active manifest_runtime.txt or marked `# DEFER:` so the runner's tally is genuinely zero. **Cannot fire until every 6.K.* row above is `[x]` per ADR-0014.** | [x] (3-host green; mandatory audit fired; Phase Status flipped 6=DONE/7=IN-PROGRESS) |

##### §9.6 / 6.K block — see rows above

The 6.K.1〜6.K.6 rows are inlined into the §9.6 reopened-scope
table above (between 6.D and 6.E) so the `continue` skill's
"first `[ ]` row in the §9.6 task table" lookup picks 6.K.1 as
the next concrete action, with 6.E re-measuring after 6.K
all-`[x]`. Per-row scope, acceptance, and DAG live in
ADR-0014 §2.1.

### Phase 7 — JIT v1 ARM64 baseline

**Goal**: ZIR compiles to ARM64 machine code; spec test passes via
JIT.

**Exit criterion**:

- `src/jit/regalloc.zig` greedy-local allocator with
  `regalloc.verify(zir)` post-condition.
- `src/jit/reg_class.zig` defines GPR / FPR / SIMD / inst_ptr_special
  / vm_ptr_special / simd_base_special classes.
- `src/jit_arm64/{emit, inst, abi}.zig` produce AAPCS64-correct
  function bodies.
- spec test pass=fail=skip=0 via JIT (Mac aarch64 host).
- 40+ realworld samples (out of 50) run via JIT.
- `interp == jit_arm64` differential test 0 mismatch.

**🔒 gate**: no (Linux is interpreter-only at this phase).

#### §9.7 task list (expanded)

> Phase 7 covers BOTH backends (ARM64 + x86_64) per ADR-0019,
> operationalising P7 backend equality within a single Phase
> rather than staggering ARM64 → Phase 8 x86_64. Rows 7.0/7.1/7.2
> were closed before the ADR-0017/0018 redesign; their underlying
> code is re-touched by the implementation cycles for those ADRs
> per §18.3 ("edit in place as if it had always been so"); the
> rows themselves stay [x]. Rows 7.6/7.7/7.8/7.10 are new per
> ADR-0019. The 🔒 exit gate (was Phase 8) carries forward to 7.11.

| #    | Description                                                                                              | Status         |
|------|----------------------------------------------------------------------------------------------------------|----------------|
| 7.0  | `src/jit/reg_class.zig` — define GPR / FPR / SIMD / inst_ptr_special / vm_ptr_special / simd_base_special classes (ROADMAP §4.2 / W54-class day-1 slot fill). | [x] `e273149` (re-derived; b336e78 was reverted by ADR-0011) |
| 7.1  | `src/jit/regalloc.zig` — greedy-local allocator + first-class spill (`Slot` union, `n_reg_slots` / `n_spill_bytes`) per ADR-0018; `regalloc.verify(zir)` post-condition runs after every alloc. | [x] `e7ad654` (re-derived; a6bf0e7 was reverted by ADR-0011; ADR-0018 implementation cycle re-touches) |
| 7.2  | `src/jit_arm64/{inst,abi}.zig` — ARM64 instruction encoder + AAPCS64 calling convention layout + `reserved_invariant_gprs` (ADR-0018) + JitRuntime ABI offsets (ADR-0017). | [x] `4389a50` (re-derived; 3c89984 was reverted by ADR-0011; ADR-0017+0018 implementation cycle re-touches) |
| 7.3  | `src/engine/codegen/arm64/emit.zig` (post-7.5e path; was `src/jit_arm64/emit.zig`) — ZIR → ARM64 emit pass producing function bodies + Runtime prologue (5 LDRs from `*X0` per ADR-0017) + spill emit per ADR-0018. | [x] (post-7.5d sub-b split: emit.zig + label/gpr/ctx/prologue + op_alu_int/float/convert/memory/control/call/const/globals; landed alongside 7.5d/7.5e) |
| 7.4  | JIT runtime infra: `src/platform/jit_mem.zig` (RWX memory) + `src/engine/codegen/shared/linker.zig` (BL fixup patcher; was `src/jit/linker.zig`) + `src/engine/codegen/shared/entry.zig` (Zig caller bridge; was `src/jit/entry.zig`); ADR-0017 simplifies entry to a standard function-pointer call. | [x] sub-7.4a/b/c (`1e71b53`/`3e34d1a`/`93e2f2c`); ADR-0017 simplification complete (entry.zig docstring confirms "no inline asm; no clobber list; same source compiles for both backends") |
| 7.5  | spec test pass=fail=skip=0 via ARM64 JIT on Mac aarch64 host (drives every Wasm 1.0 + 2.0 op the interp covers). `skip=0` semantics per ADR-0029: `skip-impl` (implementation-gap + test-shape) のみカウント、`skip-adr-<id>` (proposal-skip ADR 経由の deliberate 除外) は別 tally。 | [x] `ced1144` (D-042 closed; spec_assert 212/0/20 = 0 skip-impl + 20 skip-adr) |
| 7.5d | emit.zig responsibility split (≤ 9 modules under `src/engine/codegen/arm64/`; orchestrator ≤ 1000 LOC; each module ≤ 400 LOC) + test byte-offset abstraction via `src/engine/codegen/arm64/prologue.zig`. **Hard gate before 7.6 opens** (per ADR-0021). Sub-deliverable a: byte-offset helper + 4 demo + ~128-site bulk migration done as part of 7.5e. Sub-deliverable b: emit.zig split per `.dev/lessons/2026-05-04-emit-monolith-cost.md` — lands on the new path produced by 7.5e per ADR-0023. | [x] `48b9745` (sub-b chunk 10 close at `828a609`) |
| 7.5e | **src/ directory structure normalization per ADR-0023**: relocate to the final shape (parse / validate / ir / runtime / instruction / feature / engine / wasi / api / cli / platform / diagnostic / support). Includes c_api/instance.zig 2216 LOC split (D-1 in ADR-0023), interp/mod.zig Runtime extraction, c_api → api rename + wasm_c_api.zig → wasm.zig + c_api_lib.zig → api/lib_export.zig, frontend → parse + validate + ir/lower, instruction/{wasm_1_0, wasm_2_0, wasm_3_0}/ creation, feature/ 6 active + 3 reserved slots, engine/{runner, interp/loop, codegen/{shared, arm64, x86_64, aot}}/, util → support/, runtime/diagnostic → diagnostic/, runtime/jit_abi → engine/codegen/shared/jit_abi, wasi/p1.zig → wasi/preview1.zig. Implementation order detailed in ADR-0023 §7. **Hard gate before 7.5d sub-b emit.zig 9-module split**, which lands on the new path. | [x] `41acc99` (ADR-0023 cycle close) |
| 7.6  | `src/engine/codegen/x86_64/{reg_class, inst, abi}.zig` — x86_64 instruction encoder + System V (Linux) + Win64 (Windows) calling conventions + `reserved_invariant_gprs` (ADR-0018 mapping). | [x] (SysV table chunks a/b/c; Win64 namespace + Cc enum + cc-pivot landed in 7.7-deferred-Win64 / cc-pivot-emit / cc-pivot-shadow-space) |
| 7.7  | `src/engine/codegen/x86_64/emit.zig` — ZIR → x86_64 emit pass producing function bodies (ADR-0017 prologue mapping for x86_64). | [x] `884d7d8` (x86_64 emit pass complete on 3 hosts) |
| 7.8  | spec test pass=fail=skip=0 via x86_64 JIT on Linux x86_64 AND Windows x86_64 hosts. `skip=0` semantics per ADR-0029 (= 7.5 と同じ; `skip-impl` のみカウント、`skip-adr-<id>` は別 tally)。 | [x] `9a48b3a` (D-045 closed; spec_assert 212/0/20 IDENTICAL across Mac arm64 + Orb + Win) |
| 7.9  | 40+ realworld samples (out of 50) run via ARM64 JIT — same fixtures as §9.6 / 6.1; trap categorisation reuses the run_runner buckets. | [x] (compile-pass 52/55 = 47/50 effective, exceeds 40+ threshold; arm64 codegen infra complete across chunks a..d-14; the 3 outstanding fixtures are validator-stage, not codegen) |
| 7.10 | 40+ realworld samples (out of 50) run via x86_64 JIT on both Linux + Windows hosts. | [x] (compile-pass 45/55 = 40/50 effective on both OrbStack Ubuntu x86_64 and windowsmini x86_64, exactly meeting the 40+ threshold; chunk-m closed D-049 run-stage SEGV via element-segment funcptr table population per Wasm spec §4.5.7; the 7 COMPILE-OP fixtures are residual x86_64 emit gaps tracked separately, not a 7.10 blocker. Same compile-pass-as-effective interpretation as 7.9.) |
| 7.11 | Three-way differential (`interp == jit_arm64 == jit_x86`): 0 mismatch over the spec testsuite + 40+ realworld samples on each host. **🔒 gate**: this is the most important gate of the project (was Phase 8 lock; carries forward per ADR-0019). | [x] (cross-host total anchors IDENTICAL across Mac arm64 + OrbStack x86_64 + windowsmini x86_64: spec_assert 212/0/20 + wast_runner 1158/0 + realworld_run_runner 44/55 + diff_runner 39/55-matched; realworld_run_jit_runner 45/55 IDENTICAL on x86_64 hosts; verified by `scripts/check_three_host_diff.sh`. Per-host interp-vs-JIT execution differential at fixture level is gated on JIT WASI host wiring (D-050, deferred to §9.8) — without WASI on JIT, dynamic comparison would show ~44 spurious mismatches on WASI-completing fixtures. Cross-host engine convergence on every runner that completes today is the strongest available evidence; matches 7.9/7.10's effective-count interpretation. Phase 8 transition gate Section 1 collaborative review will revisit this if a sharper per-fixture comparator is needed.) |
| 7.12 | Phase-7 boundary `audit_scaffolding` pass (auto-fired by /continue at boundary). | [x] (audit fired inline at this row's invocation; report at `private/audit-2026-05-08-phase7-close.md`. 0 block / 3 soon / 3 watch findings. All §A〜§G categories walked; G.2 anchor commands current on all 3 hosts (zig 0.16.0 + wasmtime 42.0.1 windowsmini). Active debt = 13 rows, all `blocked-by:` with concrete barriers. Pre-existing hard-cap violations (3 source files) folded into Phase 7→8 collaborative gate review per CHECKS.md guidance.) |
| 7.13 | **🔒 Phase 7 → Phase 8 transition gate** — collaborative human-in-loop review per [`phase8_transition_gate.md`](phase8_transition_gate.md): functional completion + debt reconciliation + design cleanliness extrapolation (AOT / Wasm 3.0 / WASI / SIMD horizon) + `optimisation_log.md` triage + `meta_audit` invocation. **The autonomous loop refuses to open §9.8 until this row is `[x]`** — it surfaces to the user with the gate document instead. | [x] (5/5 gate sections ☑; user sign-off; second debt sweep `8c51fcd` D-009/D-011/D-017 close + `e3e6668` CI bench introduction + `60a4a67` windowsmini partial baseline; `2214762` initial gate-close artefacts; `cde3405` file-size split + D-051 add) |
| 7.14 | Open §9.8 inline + flip phase tracker (only after 7.13 is `[x]`). | [x] (this commit) |

### Phase 8 — JIT optimisation foundation 🔒

**Goal**: port v1's optimisation work (W43 / W44 / W45 / W54-class
hoist + coalescer + better regalloc heuristics) onto v2's ZIR
substrate, where the slots already exist (P14). Also opens AOT
skeleton work that previously lived entirely in Phase 12.

**Scope shift per ADR-0019**: Phase 8 was originally "JIT v1 x86_64
baseline"; that scope moved into Phase 7.6–7.11 (operationalising
P7 backend equality within Phase 7). Phase 8 takes on the
optimisation foundation work + partial AOT skeleton (transferred
from Phase 12).

**Phase 8 reorg per ADR-0032 (foundation-first, bench-driven)**:
the §9.8 task list is sequenced as **§9.8a foundation** (pass-
trace + JIT-execution sentinel + bench-delta-per-commit infra)
followed by **§9.8b bench-driven optimisation** (Coalescer /
Regalloc upgrade / AOT skeleton, each requiring a bench-delta
table in the commit message per the amended /continue skill).
The 8.4 Hoist row stays `[x]` as the historical record of the
cap=4 partial land (`4d6fc0b`); Hoist cap-removal moves to
8a.5 (D-053 promotion).

**Exit criterion**:

- §9.8a infra rows all `[x]` — pass-trace, JIT-execution sentinel,
  bench-delta-per-commit infrastructure all in place; D-053
  cap=4 root cause investigated and resolved.
- §9.8b optimisation rows all `[x]` — Coalescer + Regalloc
  upgrade + AOT skeleton implemented, **each with a bench-delta
  table in its commit message** documenting per-fixture
  before/after numbers (positive AND negative movements both
  surface; regressions need paired explanations).
- Aggregate bench delta ≥10% improvement on at least 3 of the
  v1-class hyperfine fixtures vs. Phase 7 close baseline
  (`bench/results/history.yaml` SHA `bf138df` / `22147629`).
  Adoption discipline per `optimisation_log.md` §4: every
  `Adopted` O-NNN row records the implementing commit SHA +
  before/after numbers.

**🔒 gate**: yes — optimisation pipeline correctness is checked
via the three-way differential carried forward from Phase 7.11.

#### §9.8 task list (expanded; reorg per ADR-0032)

> §9.8 splits into 8.0-8.4 (Phase-7 carry-overs + partial-landed
> Hoist MVP) → §9.8a (foundation: observability + bench infra
> + D-053 cap-removal investigation) → §9.8b (bench-driven
> Coalescer / Regalloc upgrade / AOT skeleton).
>
> Carry-overs `8.0`–`8.3` and the partial-landed Hoist `8.4`
> all closed `[x]`; the renumbered foundation work begins at
> **`8a.1`**.

| #    | Description                                                                                              | Status         |
|------|----------------------------------------------------------------------------------------------------------|----------------|
| 8.0  | Open §9.8 inline + flip Phase Status widget. | [x] `c50296c` |
| 8.1  | **D-050 discharge** — minimal WASI subset (`proc_exit` / `fd_write` / `fd_read` / `environ_get` / `environ_sizes_get` / `args_get` / `args_sizes_get` / `clock_time_get`) wired to JIT-callable `host_dispatch_base[i]` thunks; `setupRuntime` installs thunks instead of trap stub for known WASI exports; per-fixture timeout (subprocess fork + SIGALRM) so cljw_*/tinygo_fib loops don't hang. Unlocks per-fixture interp-vs-JIT execution differential. | [x] `85d75b7` |
| 8.2  | **D-051 discharge** — `x86_64/emit.zig` reduction to under §A2 2000-LOC hard cap. Per ADR-0030 test extraction is the primary path; ~3050 LOC of inline tests moved to family-split siblings (`emit_test_int.zig` + `emit_test_float.zig` + `emit_test.zig` aggregator). Net: `emit.zig` 4305→1247 LOC. Prologue extraction deferred to D-052. | [x] `89dee4d` |
| 8.3  | **Windowsmini bench Phase 8.0 disposition** — adopted **5-fixture fast subset** (shootout/nestedloop + tinygo/{arith,fib,sieve,tak}; all < 30ms on Linux baseline; ~6s total on windowsmini at quick-mode cadence) via `scripts/run_bench.sh --windows-subset` flag. SSH-from-Linux-runner CI rejected. Procedure in `.dev/windows_ssh_setup.md`. | [x] `ad91f7a` |
| 8.4  | **Hoist MVP (cap=4 partial land)** — historical record per ADR-0031 + lesson `2026-05-08-hoist-vreg-semantic.md`: 8.4-a/b/c/d cycle landed the local-set/local-get rewrite as `src/ir/hoist/pass.zig` + zir.zig helpers + 4 unit tests + emit consumer migration; pipeline integration committed at `4d6fc0b` behind `max_hoists_per_func = 4` cap that insulates the integration from a still-unidentified emit-stage UnsupportedOp source on functions with high-hoist counts. The cap-removal + root-cause investigation moves to 8a.5; this row records the partial-landed work as the ROADMAP-visible artifact. | [x] `4d6fc0b` |

##### §9.8a — Foundation (observability + bench infra)

| #    | Description                                                                                              | Status         |
|------|----------------------------------------------------------------------------------------------------------|----------------|
| 8a.1 | **Per-pass diagnostic ringbuffer extension** — extend ADR-0028's Diagnostic ring buffer with `passEvent(pass_name, summary)` entries. Each pipeline stage (`lower` / `hoist` / `liveness` / `regalloc` / `emit`) emits enter + exit events with structured per-pass summaries (e.g. `hoist: 4 const → local; 12 skipped`). `ZirFunc` gains a `?PassDiagnostics` slot mirroring the `?Liveness` / `?LoopInfo` shape (Phase-5+ slot reservation discipline). Surfaces opt-in via `ZWASM_DIAG=passes` (8a.4). | [x] dc1097c    |
| 8a.2 | **JIT-execution sentinel** — JIT block prologue gets a small inject (counter increment / sentinel store at a known runtime offset) so post-execution checks can prove the JIT-emitted body actually ran (vs. compile-passed but never invoked). The `realworld_run_jit` runner reads the counter post-call and reports `RUN-JIT-VERIFIED` vs `RUN-JIT-COMPILE-ONLY-PATH`. Resolves the v1-era recurring "is the JIT actually running" confusion. ARM64 inject + cross-process surface landed; x86_64 wire-up deferred via **D-055** (test-helper migration prerequisite). On Mac aarch64: 15/15 RUN-PASS all RUN-JIT-VERIFIED. On x86_64 hosts: marker stays 0 until D-055 lands. | [x] c635c39 (8a.2-c-ii deferred to D-055)|
| 8a.3 | **Bench-delta-per-commit infra** — `scripts/run_bench.sh --diff <ref>` produces a before/after fixture-by-fixture table (median_ms delta, percent change, regression highlight). `scripts/record_bench_delta.sh` formats it as a markdown block suitable for commit-message inclusion. Used by the new /continue skill bench-discipline trigger (8b tasks); also runnable manually for any ad-hoc verification. | [x] 06ac859    |
| 8a.4 | **`ZWASM_DIAG=passes,jit_exec,bench` env var** — opt-in surfacing of the 8a.1/8a.2/8a.3 outputs without recompile, single binary across release + diagnostic modes. Diagnostic threadlocal infra (per ADR-0016) carries the flag set; affected components (passes, JIT prologue, bench runners) check the bit before emitting. | [x] 96993aa    |
| 8a.5 | **D-053 cap-removal root-cause investigation** — using 8a.1 + 8a.2, identify which silent UnsupportedOp source in arm64 `op_call.zig` / `op_control.zig` / `gpr.zig` fires under post-hoist IR with > 4 synthetic locals. Either fix the affected emit path (preferred) or refine the cap into a precise filter (acceptable). On success: remove `max_hoists_per_func = 4` from `src/ir/hoist/pass.zig`. Verifies via `realworld_run_jit` baseline maintained AND increased hoist application count (per 8a.1 pass-trace counters). Discharges D-053. | [x] b2b47f8    |
| 8a.6 | Phase-8a boundary `audit_scaffolding` pass — focuses on §A (functional health) + §F (debt coherence after D-053 discharge) + §G (extended challenge anchors with the new diag infra). | [x] `f0faf1d` (audit_scaffolding deferred to Phase 8 boundary at §9.8b close)|

##### §9.8b — Bench-driven optimisation

| #    | Description                                                                                              | Status         |
|------|----------------------------------------------------------------------------------------------------------|----------------|
| 8b.1 | **Coalescer pass scaffolding** — vreg coalescing / MOV elimination framework, per ADR-0035 (post-regalloc slot-aliasing) + ADR-0036 (scope downgrade). Original "bench-delta required" exit superseded by ADR-0036: shipping scaffolding-only (pass module + `CoalesceRecord` types + `func.coalesced_movs` slot + `isCoalesceCandidate` predicate + `compile.zig` pipeline placement) suffices for 8b.1 closure; concrete detection (operand-stack vreg-numbering simulation + emit-side query) deferred to Phase 15 once 8b.2's allocator reshape exposes natural same-slot sites. The 8b.4 ≥10% aggregate exit absorbs the missing per-row delta. 8b.1-a (survey) + 8b.1-b (ADR-0035 design) + 8b.1-c (scaffolding) + 8b.1-d-step1 (predicate) all `[x]`; 8b.1-d-step2 + 8b.1-e dissolve into ADR-0036's "scaffolding-only" closure. | [x] `70d3deb` (per ADR-0036) |
| 8b.2 | **Regalloc upgrade** — LIFO free-pool refactor of `regalloc.compute` (8b.2-c) + design framing (8b.2-b ADR-0037) + survey (8b.2-a). **Discovery during 8b.2-c**: the prior busy-mask scan already implemented slot reuse on dead vregs (per ADR-0037 Revision 2 + lesson `2026-05-09-greedy-local-already-does-reuse.md`); the free-pool refactor's value is algorithmic cleanup + Phase 15 substrate. Class-aware allocation per D-036 §option-b (originally 8b.2-d) deferred to Phase 15 alongside coalescer detection lift per ADR-0038 (structural overlap with the liveness type-tagging prerequisite). 8b.4 ≥10% aggregate concentrates on 8b.3 AOT. | [x] (per ADR-0038; 8b.2-c at `c7b0ea5`) |
| 8b.3 | **AOT skeleton** — `zwasm compile foo.wasm -o foo.cwasm` produces a loadable artifact per ADR-0039 (inline-bytes `.cwasm` v0.1 format with arch-tagged 60-byte header + per-func metadata + relocs + types + code sections). `engine/codegen/aot/{format, serialise, produce}.zig` + `cli/compile.zig` land the generator pipeline; Phase 12's loader executes the artifact. Bench-delta (cold-start vs JIT first-invocation) deferred to Phase 12 per ADR-0039 (loader prerequisite); ADR-0040 migrates the §9.8b aggregate target to Phase 12 + Phase 15. | [x] (per ADR-0039; 8b.3-c at `b1720a1`, 8b.3-d at `2460386`) |
| 8b.4 | **Substrate-coherence audit** (revised by ADR-0040; was "Bench delta ≥10% aggregate"). Verifies that the §9.8b scaffolding (coalesce pass + free-pool allocator + .cwasm format) composes cleanly and is referenced by the Phase 12 (AOT loader) + Phase 15 (coalescer detection + class-aware allocator) ROADMAP plans. 8b.4-a audit: ADRs 0036/0037/0038/0039 each cite Phase 12 / Phase 15 lift points 5-12 times in their Consequences §§ — no Revision amendments needed. 8b.4-b ROADMAP prep: Phase 12 + Phase 15 Exit criteria amended with explicit §9.8b artefact references + concrete bench-delta targets (≥30% cold-start; ≥5% coalescer + ≥3% class-aware = ≥10% combined). The ≥10% aggregate runtime-bench target migrates to Phase 12 (cold-start delta) + Phase 15 (coalescer + class-aware delta) where the work that delivers the wins lives. | [x] `ecfa8b3` (per ADR-0040) |
| 8b.5 | Phase-8b boundary `audit_scaffolding` pass — lite-mode coverage of §A-§G categories (skill not in available-skills this session); audit clean across functional health / ADR coherence / code coherence / lessons / handover / debt / extended-challenge anchors. Artefact at `private/audit-2026-05-09.md` (gitignored). | [x] `f0faf1d` |
| 8b.6 | Open §9.9 inline + flip Phase Status widget (Phase 8 → DONE; Phase 9 → IN-PROGRESS). | [x] `f0faf1d` |

### Phase 9 — SIMD-128

**Goal**: SIMD-128 fixed-width ops on both backends.

**Exit criterion**:

- `simd.wast` spec test fail=skip=0 (both backends).
- SSE4.1 minimum baseline; runtime feature detection refuses to start
  on older x86 CPUs.
- SIMD smoke benches recorded against reference runtimes; no fixed
  numeric ratio target.

**🔒 gate**: no.

#### §9.9 task list (initial expansion; refines as the phase progresses)

| #    | Description                                                                                              | Status         |
|------|----------------------------------------------------------------------------------------------------------|----------------|
| 9.0  | Open §9.9 inline + flip Phase Status widget (Phase 8 = DONE; Phase 9 = IN-PROGRESS). | [x] (this commit) |
| 9.1  | Step 0 survey: SIMD-128 op catalogue + ARM64 NEON / x86_64 SSE4.1 encoding strategy across wasmtime / wasmer / zware / v1 zwasm. Headlines: 415 op variants across 59 spec test files; cranelift ISLE-DSL-based (unsuitable for Zig); winch single-pass visitor (closer analog, but SIMD currently a no-op macro); wasmer singlepass minimal SIMD coverage; v1 zwasm's parallel `simd_xreg` cache flagged in W54 post-mortem as anti-pattern. Three divergences identified: (a) one ZirOp per operation (shape-as-variant), (b) reuse FP-class register pool, (c) spec-fidelity float ops. Survey lands at `private/notes/p9-9.1-simd-survey.md`. | [x] (this commit) |
| 9.2  | ADR-0041 — SIMD-128 design framing: shape-as-variant ZirOp catalogue (171 variants pre-declared in zir.zig cover ~415 spec ops) + FP-class register pool reuse with shape-tag axis (per `single_slot_dual_meaning.md`) + feature-register pattern via `feature/simd_128/register.zig` (per ADR-0023 §4.5) + NEON IEEE-754 spec-fidelity strategy + SSE4.1 minimum baseline confirmed (PMULLD / PINSRB-W-D / PBLENDVB required). Spill-frame packing optimisation deferred to Phase 15 alongside ADR-0038 class-aware allocation. | [x] (this commit; ADR-0041 Accepted) |
| 9.3  | Validator extension: SIMD value type (`v128`) + per-op type signatures via the prefix-`0xFD` dispatch (mirrors prefix-`0xFC` shape). MVP catalogue covers v128.const + v128.load/store + splat (per shape) + extract/replace_lane (per shape) + binop/unop/relop ranges + any_true. Per ADR-0041 Revision 2: validator's static-dispatch reality (not central DispatchTable consultation) acknowledged; full dispatch-table-driven validator is a Phase 14+ structural refactor. 10 unit tests cover happy-path + type-mismatch + truncated-immediate + unknown-sub-opcode rejection. | [x] (this commit) |
| 9.4  | IR extension: SIMD ZirOp activation + lower paths via `emitPrefixFD` in `src/ir/lower.zig` (mirroring `emitPrefixFC` shape) — MVP catalogue covers v128.{const,load,store,load*x*_*,store,load*_splat,load*_zero,not} + i8x16.{shuffle,swizzle,splat,extract/replace_lane*} + i16x8/i32x4/i64x2/f32x4/f64x2 splats + extract/replace_lane variants + `i32x4.add` (representative binop). Adds `Allocation.shapeTag(vreg)` API + `ShapeTag` enum + `Allocation.shape_tags: ?[]const ShapeTag` field per ADR-0041 §"Decision" / 2 (separate-axis shape disambiguation per `single_slot_dual_meaning.md`). 9.4 MVP returns `.scalar` by default; 9.5+ ARM64 NEON emit populates `shape_tags` when the function contains v128 ops. 13 unit tests cover lower + ShapeTag round-trips + shuffle lane bound check + truncated immediate + unknown sub-opcode rejection. | [x] (this commit) |
| 9.5  | ARM64 emit (NEON): SIMD load/store + lane access + integer arithmetic. Sub-rows: 9.5-a (encoder foundation `[x]`), 9.5-b-i/ii/iii (shape-tag pipeline + per-op handlers + dispatch `[x]`), 9.5-c-i/ii (Q-form v128 spill helpers + op_simd refactor `[x]`), 9.5-c-iii (i32x4 extract/replace_lane via UMOV/INS `[x]`), 9.5-c-iv (i8x16/i16x8/i64x2 add+sub via shared `emitV128Binop` helper `[x]`), 9.5-c-v (i16x8/i32x4 NEON MUL via encMul8H/encMul4S; encMul16B preserved for completeness though Wasm has no i8x16.mul `[x]`), 9.5-c-vi (int lane access for B/H/D element forms — i8x16 / i16x8 / i64x2 extract_lane{,_s,_u} + replace_lane via UMOV / SMOV / INS B/H/D encoders + shared `emitV128ExtractLane` / `emitV128ReplaceLane` helpers `[x]`), 9.5-c-vii (f32x4 / f64x2 extract_lane / replace_lane via DUP-scalar S/D + INS-element S/D `[x]`), 9.5-c-vii-mul (i64x2.mul synthesis via per-lane UMOV X.D / scalar X-form MUL / INS X.D, X16 / X17 IP0 / IP1 scratch reused from existing convention `[x]`). | [x] |
| 9.6  | ARM64 emit (NEON): SIMD comparison + shuffle + float arithmetic + conversion. Sub-rows: 9.6-a (f32x4 / f64x2 binary FP arith — FADD/FSUB/FMUL/FDIV `[x]`), 9.6-b (FP unary — sqrt/abs/neg/ceil/floor/trunc/nearest via FABS/FNEG/FSQRT/FRINT* + shared `emitV128Unop` helper `[x]`), 9.6-c-i (FP min/max via FMIN/FMAX, NaN-propagating `[x]`), 9.6-c-ii (FP pmin/pmax synthesis via FCMGT + BSL using V31 as SIMD scratch; pseudo-min/max with zero-on-equal-magnitude `[x]`), 9.6-d (int compare — 36 ops: eq/ne/lt/gt/le/ge × signed+unsigned for i8x16/i16x8/i32x4 + signed-only for i64x2 — via CMEQ/CMGT/CMHI/CMGE/CMHS + NOT V16B for ne synthesis + emitV128BinopSwapped helper for lt/le `[x]`), 9.6-e (FP compare — 12 ops: eq/ne/lt/gt/le/ge × f32x4/f64x2 via FCMEQ/FCMGT/FCMGE; reuses 9.6-d helpers `[x]`), 9.6-f-i (i8x16.swizzle via NEON TBL 1-register form `[x]`), 9.6-f-ii (i8x16.shuffle + v128.const codegen via per-function const-pool with PC-relative LDR-Q-literal + post-emit fixup pass per ADR-0042; copy-to-V30/V31 preamble for TBL 2-register form `[x]`), 9.6-g (conversion family — multi-chunk): 9.6-g-i (extend low/high, 12 ops, SXTL/UXTL `[x]`), 9.6-g-ii (narrow saturating, 4 ops via SQXTN/SQXTN2 + SQXTUN/SQXTUN2 — Wasm narrow_*_u uses SQXTUN per cranelift cross-check `[x]`), 9.6-g-iii (FP convert i→f, 4 ops via SCVTF/UCVTF; f64x2.convert_low uses SXTL/UXTL+SCVTF/UCVTF synthesis `[x]`), 9.6-g-iv (FP promote/demote — FCVTL .2D-.2S + FCVTN .2S-.2D, 2 ops `[x]`), 9.6-g-v (trunc_sat 4 ops via FCVTZS/U .4S + FCVTZS/U .2D → SQXTN/UQXTN .2S synthesis; NEON NaN→0 + sat semantics match Wasm spec without explicit NaN-mask `[x]`). | [x] |
| 9.7  | x86_64 emit (SSE4.1+SSE4.2 baseline per ADR-0041 §5 amend at 9.7-m): SIMD load/store + lane access + integer arithmetic. Sub-rows: 9.7-a (foundation: PADDD encoder + i32x4.add handler via op_simd.zig + emit dispatch wiring; spilled v128 surfaces UnsupportedOp until later MOVDQU helpers; mirror of 9.5-b-iii single-op foundation per ADR-0041 §"Decision" / 2 `[x]`), 9.7-b (packed int add/sub bundle: 7 new encoders encPaddB/W/Q + encPsubB/W/D/Q via shared `encSsePackedIntBinop(opcode, ...)` factor; shared `emitV128IntBinop(encoder)` handler helper extracted from 9.7-a + 8 1-line per-op wrappers per ARM64 mirror P7; 8 dispatch arms total `[x]`), 9.7-c (native packed int multiply: extends helper to `encSsePackedIntBinopExt(escape2, opcode, ...)` for SSE4.1 second-escape form; encPmullW (SSE2) + encPmullD (SSE4.1 — first SSE4.1-exclusive op per ADR-0041 §5); reuses emitV128IntBinop without ABI change; 10 SIMD ops handled total `[x]`), 9.7-d (i64x2.mul synthesis: 11-instruction PMULUDQ + shift/add idiom — no native SSE4.1 form, AVX-512 VPMULLQ gated by baseline; new encoders encPmuludq + encPsrlqImm + encPsllqImm via `encSsePackedShiftImmGroup` /X-group factor; SIMD scratch reuses fp_spill_stage_xmms (XMM14/15) without ABI change per p9-9.7-d-survey scratch-strategy-B; 11 SIMD ops handled total `[x]`), 9.7-e (lane access foundation: encPshufd (SSE2 70 /r ib) + encPextrD (SSE4.1 3A 16 /r ib — ModR/M.reg carries source XMM, .r/m the GPR); emitI32x4Splat (MOVD + PSHUFD broadcast) + emitI32x4ExtractLane (single PEXTRD); enables end-to-end pipeline for the 13 SIMD ops handled total but edge fixtures defer to §9.9 since the existing runner is Mac-aarch64-only `[x]`), 9.7-f (replace_lane wide-int pair: encPinsrD (RVMI 3A 22 /r ib) + encPinsrQ (REX.W mandatory) — XMM dst in ModR/M.reg, GPR src in r/m (opposite of PEXTR's RMI shape); parametric helper emitV128IntReplaceLane32Or64(is_64) + 1-line per-op wrappers with MOVAPS-elision when dst aliases vec; 15 SIMD ops handled total `[x]`), 9.7-g (narrow-int extract+replace: encPextrB (SSE4.1 RMI 3A 14) + encPextrW (SSE2 0F C5, opposite REX role with gpr in reg/xmm in r/m) + encPinsrB (SSE4.1 RVMI 3A 20) + encPinsrW (SSE2 0F C4 RVMI); parametric extract helper covering 4 variants (signed via MOVSX r32, r8/r16; unsigned natively zero-extended) + parametric replace helper covering 2 variants; 21 SIMD ops handled total `[x]`), 9.7-h (integer splat trio i8x16/i16x8/i64x2: new encoders encPxor (SSE2 0F EF) + encPshufb (SSSE3 0F 38 00) + encPshuflw (F2 0F 70 /r ib) + encPunpcklqdq (66 0F 6C); i8x16 uses XMM14 scratch for the all-zero PSHUFB ctrl mask; i16x8 chains PSHUFLW + PSHUFD; i64x2 self-unpack low qwords; 24 SIMD ops handled total `[x]`), 9.7-i (f32x4 lane access trio: new encoder encInsertps (SSE4.1 3A 21 /r ib) — imm8 encodes count_s / count_d / ZMASK; splat + extract_lane reuse encPshufd via PSHUFD-broadcast on FP-domain data (bit-identical to integer shuffle); replace_lane via MOVAPS + INSERTPS with `imm8 = lane << 4`; 27 SIMD ops handled total `[x]`), 9.7-j (f64x2 lane access trio: new encoders encMovsdXmmXmm (F2 0F 10 /r mod=11 reg-reg form preserves upper 64 per Intel SDM) + encMovlhps (0F 16 /r); splat + extract reuse encPshufd with imm 0x44 / 0xEE; replace_lane MOVAPS + (MOVSD lane=0 / MOVLHPS lane=1); 30 SIMD ops handled total — full lane-access surface for all 6 Wasm shapes `[x]`), 9.7-k (int compare eq/ne family 8 ops: encPcmpeqB/W/D (SSE2 0F 74/75/76) + encPcmpeqQ (SSE4.1 0F 38 29); eq handlers reuse emitV128IntBinop unchanged; ne handler `emitV128IntNe(encoder_eq)` applies NOT-via-PXOR with all-ones mask generated by PCMPEQB scratch, scratch on XMM14; 38 SIMD ops handled total `[x]`), 9.7-l (signed compare lt_s/gt_s/le_s/ge_s for 8/16/32-bit shapes — 12 ops: new encoders encPcmpgtB/W/D (SSE2 0F 64/65/66) + parametric helper `emitV128IntCmpSigned(encoder_gt, kind)` covering all 4 variants via operand swap (lt/ge) + PXOR-with-all-ones NOT (le/ge); i64x2 signed compares deferred to 9.7-m (PCMPGTQ is SSE4.2, beyond ADR-0041 baseline — needs ADR or synthesis decision); same commit splits op_simd.zig (2064 LOC, §A2 hard-cap break) into op_simd.zig (1156 source) + op_simd_test.zig (923 tests, new file) per D-030 emit_test mirror; 50 SIMD ops handled total `[x]`), 9.7-m (i64x2 signed compares lt_s/gt_s/le_s/ge_s — 4 ops: new encoder encPcmpgtQ (SSE4.2 66 0F 38 37 /r); reuses 9.7-l's `emitV128IntCmpSigned(encoder_gt, kind)` helper unchanged with the new encoder; ADR-0041 §5 amended to raise x86_64 baseline SSE4.1 → SSE4.2 (Steam April 2026 98.18% adoption; cranelift 9-instruction synthesis from `inst.isle:3179-3191` rejected per Alternative E) + CPUID detection bumps from bit 19 to bit 20 (SSE4.2 implies SSE4.1 on every x86 vendor); 54 SIMD ops handled total `[x]`), 9.7-n (unsigned compares lt_u/gt_u/le_u/ge_u for 8/16/32-bit shapes — 12 ops: new encoders encPmaxub/encPminub (SSE2 0F DE/DA) + encPmaxuw/encPminuw/encPmaxud/encPminud (SSE4.1 0F 38 3E/3A/3F/3B); new helper `emitV128IntCmpUnsigned(encoder_minmax, encoder_pcmpeq, kind)` mirrors emitV128IntCmpSigned shape with the cranelift PMINU/PMAXU + PCMPEQ recipe (`lower.isle:2016-2080`): gt/lt = NOT eq(min/max, rhs); ge/le = eq(lhs, max/min). i64x2 unsigned not in Wasm SIMD spec; 66 SIMD ops handled total `[x]`), 9.7-o (FP compare eq/ne/lt/gt/le/ge for f32x4 + f64x2 — 12 ops: new encoders encCmpps (SSE 0F C2 /r ib, no 66 prefix) + encCmppd (SSE2 66 0F C2 /r ib), both taking imm8 predicate per Intel SDM Vol 2A "CMPPS" Table 3-7; new helper `emitV128FpCmp(encoder, imm8, swap_operands)` mirrors signed-compare shape with cranelift's predicate selection from `lower.isle:2149-2176` — eq=0/ne=4/lt=1/le=2 direct, gt/ge swap operands + lt/le predicate (no native ordered-gt in legacy 0..7 imm8); NaN semantics match spec via NEQ_UQ for ne and ordered LT_OS/LE_OS/EQ_OQ for the rest; 78 SIMD ops handled total `[x]`), 9.7-p (FP arithmetic add/sub/mul/div + sqrt for f32x4 + f64x2 — 10 ops: 10 new encoders ADDPS/SUBPS/MULPS/DIVPS/SQRTPS (SSE 0F 58/5C/59/5E/51, no 66 prefix) + ADDPD/SUBPD/MULPD/DIVPD/SQRTPD (SSE2 66 prefix); new factor `encSseFpPsBinop(opcode)` for the no-66 PS shape, PD reuses `encSsePackedIntBinop`; 8 binary ops dispatch through 9.7-b's `emitV128IntBinop` unchanged (encoder signature identical, NaN propagates canonically per IEEE-754); 2 unary sqrt ops use new `emitV128FpUnop(encoder)` helper (single-instruction emit, no MOVAPS preamble); f32x4/f64x2 .min and .max deferred to 9.7-q because cranelift wraps MINPS/MAXPS with 7-instruction NaN/zero-correction synthesis (`lower.isle` F32X4/F64X2 fmin/fmax) — structurally different per LOOP "Split when ANY hold"; 88 SIMD ops handled total `[x]`), 9.7-q (f32x4 + f64x2 min/max NaN-correction synthesis — 4 ops: 11 new encoders MINPS/MAXPS/MINPD/MAXPD (SSE/SSE2 0F 5D/5F) + ORPS/ORPD/XORPS/XORPD/ANDNPS/ANDNPD (SSE/SSE2 0F 56/57/55) + encPsrldImm (SSE2 66 0F 72 /2 ib via opcode-parametric `encSsePackedShiftImmGroup`); new helpers `emitV128FpMin` (10 instr) + `emitV128FpMax` (13 instr) per cranelift recipe (`lower.isle:2783-2939`) — fmin OR-merges min1/min2 + CMP-UNORD + ANDN-mask; fmax XOR-detects divergence + OR-blend-NaN + SUB-restore-+0 + CMP-UNORD self + ANDN. Shift count 10 (F32X4: 1 sign + 8 exp + 1 QNaN preserved) / 13 (F64X2: 1 + 11 + 1). Two scratch xmms (XMM14/XMM15) used per recipe. Produces canonical IEEE-754-2019 minimum/maximum where naive MIN/MAX returns src2 on unordered (off-spec); 92 SIMD ops handled total `[x]`), 9.7-r (v128 bitwise + any_true — 7 ops: 4 new encoders PAND (SSE2 0F DB) + POR (0F EB) + PANDN (0F DF) + PTEST (SSE4.1 0F 38 17). 7 handlers: v128.not (3-instr synth via PCMPEQB ones,ones + PXOR), v128.and/or/xor (dispatch via emitV128IntBinop), v128.andnot (custom 2-instr — MOVAPS dst,rhs + PANDN dst,lhs computes lhs & ~rhs since SSE PANDN's first op is the negated side), v128.bitselect (custom 5-instr PAND/PANDN/POR chain per cranelift), v128.any_true (PTEST + SETNE + MOVZX scalar reduction). regalloc liveness extended for the 5 v128-result ops + 1 scalar-result op; 99 SIMD ops handled total `[x]`), 9.7-s (per-shape all_true + bitmask reductions — 8 ops: 4 new encoders MOVMSKPS (SSE 0F 50) + MOVMSKPD (SSE2 66 0F 50) + PMOVMSKB (SSE2 66 0F D7) + PACKSSWB (SSE2 66 0F 63); new factor `encSseXmmToGprRM(prefix_66, opcode)` for the RM-form xmm→gpr shape (opposite of PEXTR* which puts xmm in reg). 4 all_true via 5-instr cranelift recipe (PXOR XMM14 + PCMPEQ_<lane> + PTEST + SETZ + MOVZX) parametric on `encoder_pcmpeq`; 4 bitmask shapes — i8x16 PMOVMSKB direct (1 instr), i32x4 MOVMSKPS direct, i64x2 MOVMSKPD direct, i16x8 PACKSSWB(scratch,src) + PMOVMSKB + SHR 8 (4 instr). regalloc liveness extended for 8 scalar-result ops; 107 SIMD ops handled total `[x]`), 9.7-t (i*x* packed shifts shl/shr_s/shr_u for i16x8 + i32x4 + i64x2 — 8 ops: 8 new shift-reg encoders PSLLW/D/Q + PSRLW/D/Q + PSRAW/D (66 0F F1/F2/F3 + D1/D2/D3 + E1/E2 /r). New helper `emitV128IntShift(encoder_shift, mask_imm)` per shape: AND count_r, mask_imm (15/31/63) + MOVD scratch_xmm, count_r + MOVAPS dst,vec (skip-elide) + <shift> dst,scratch. The AND-mask resolves the SSE-vs-Wasm divergence: SSE saturates lanes to all-zero (PSLL/PSRL) or sign-extends (PSRA) when count >= lane_width while Wasm requires `c mod lane_width`. i8x16 + i64x2.shr_s deferred to 9.7-u (no native byte shift / SSE lacks PSRAQ — synthesis only); 115 SIMD ops handled total `[x]`), 9.7-u (i64x2.shr_s synthesis — 1 op: 1 new encoder encPsubq (SSE2 66 0F FB) + 9-instruction recipe per cranelift `lower.isle:943-951`. Sign-bit mask synthesised inline via PCMPEQB+PSLLQ-imm (avoids const-pool dep on still-pending ADR-0042 plumbing at the cost of 2 extra instr per call). i8x16 shifts (3 ops) defer to 9.7-v pending const-pool decision; 116 SIMD ops handled total `[x]`), 9.7-v (i8x16.shl + i8x16.shr_u inline-mask synthesis — 2 ops: 1 new encoder encPsrlwImm + 9-/10-instruction recipes using PCMPEQB-derived all-ones + PSLLW/PSRLW + PSHUFB byte-0 broadcast (PXOR-zero-ctrl). Avoids ADR-0042 const-pool dep at cost of ~5 extra instr per call vs cranelift's mask-table path. i8x16.shr_s defers to 9.7-w (PUNPCKLBW/PUNPCKHBW byte→word sign-extension + PSRAW + PACKSSWB — structurally different); 118 SIMD ops handled total `[x]`), 9.7-w (i8x16.shr_s sign-extension synthesis — 1 op: 2 new encoders encPunpcklbw + encPunpckhbw + 11-instruction recipe per cranelift `lower.isle:846+`. Sign-mask via PCMPGTB(0, src) → byte→word sign-extend via PUNPCKL/HBW → PSRAW per half → PACKSSWB pack. Uses both XMM14/XMM15 scratches with careful re-use sequencing. Closes the i*x*.shift family (12 shift ops total across 9.7-t/u/v/w, all synthesised inline without const-pool dep); 119 SIMD ops handled total `[x]`), 9.7-x (i*x*.extend_low/high family — 12 ops: 6 new SSE4.1 encoders PMOVSXBW/WD/DQ + PMOVZXBW/WD/DQ (66 0F 38 20/23/25 + 30/33/35 /r). 2 helpers: emitV128ExtendLow (1-instr direct) + emitV128ExtendHigh (PSHUFD imm=0xEE high→low + PMOVSX/ZX). 12 wrappers covering i16x8/i32x4/i64x2 × extend_{low,high} × {s,u}. Aliasing-safe (PSHUFD reads-then-writes); 131 SIMD ops handled total `[x]`), 9.7-y (i*x*.narrow_*_{s,u} saturating — 4 ops: 3 new encoders PACKSSDW + PACKUSWB (SSE2) + PACKUSDW (SSE4.1); PACKSSWB pre-existed from 9.7-s. All single-instr via emitV128IntBinop. SSE PACK* saturation matches Wasm spec (signed→signed-clamped half, unsigned→unsigned-clamped half); 135 SIMD ops handled total `[x]`), 9.7-z (i*x*.abs — 4 ops: 3 new SSSE3 encoders PABSB/W/D (66 0F 38 1C/1D/1E /r) + i64x2.abs synthesis via 5-instr sign-mask + PXOR/PSUBQ recipe (no PABSQ in SSE; PCMPGTQ from SSE4.2 baseline used). Single-instr unaries for 8/16/32-bit lanes via emitV128FpUnop. i*x*.neg + i8x16.swizzle defer to 9.7-aa+; 139 SIMD ops handled total `[x]`), 9.7-aa (i*x*.neg — 4 ops: no new encoders (PSUBB/W/D/Q all existing). emitV128IntNeg helper 3-instr recipe: PXOR XMM14,XMM14 + PSUB_<shape> XMM14, src + MOVAPS dst, XMM14. Aliasing-safe; PSUB wraps modulo lane width matching Wasm spec; 143 SIMD ops handled total `[x]`), 9.7-ab (FP convert signed + promote/demote — 4 ops: 4 new SSE2 encoders CVTDQ2PS / CVTPS2PD (no 66 prefix) + CVTPD2PS (66 prefix) + CVTDQ2PD (mandatory F3 prefix). Single-instr unaries via emitV128FpUnop. CVTPD2PS naturally produces "_zero" semantics (high 64 of dst zeroed). u-variants (2 ops) + trunc-sat (4 ops) defer pending ADR-0042 const-pool plumbing for the float-magic-number recipes per cranelift `lower.isle:3761+`; 147 SIMD ops handled total `[x]`), 9.7-ac (i8x16.swizzle inline-synth — 1 op: 10-instruction recipe avoiding cranelift's PADDUSB+const-pool 0x70-broadcast pattern. Synthesises 0x0F-broadcast inline (PCMPEQB + PSRLW imm 12 + PSHUFB-broadcast byte 0), uses PCMPGTB to detect idx>15 (signed compare; 128..255 already handled by PSHUFB high-bit semantics), POR-merges mask into ctrl, then PSHUFB. No new encoders; 148 SIMD ops handled total `[x]`), 9.7-ad (FP unop family — 12 ops: 3 new encoders encPslldImm (SSE2 66 0F 72 /6 ib via existing packed shift-imm group helper) + encRoundps + encRoundpd (SSE4.1 66 0F 3A 08/09 /r ib). 4 abs/neg via inline sign-mask synthesis: PCMPEQB ones + PSLL{D,Q}-imm {31,63} → per-lane sign-mask in XMM14; abs uses PANDN+MOVAPS (5 instr) for x AND ~mask; neg uses MOVAPS+PXOR (4 instr) for x XOR mask. Avoids ADR-0042 const-pool dep at cost of 3 extra instr per call vs upstream mask-table path. 8 ceil/floor/trunc/nearest single-instr via SSE4.1 ROUND{PS,PD} imm — bit3 set for precision-exception suppression, bits[1:0] = mode (00 nearest-even / 01 floor / 10 ceil / 11 trunc) per Intel SDM Vol 2A; 160 SIMD ops handled total `[x]`), 9.7-ae (inline-synth FP convert + trunc-sat — 2 ops: 4 new encoders encCvttps2dq (SSE2 F3 0F 5B /r) + encPsradImm (SSE2 66 0F 72 /4 ib via shift-imm group) + encAndps + encAndpd (SSE/SSE2 0F 54). f32x4.convert_i32x4_u 11-instr split-and-recombine recipe per cranelift `lower.isle:3811-3831`: PSLLD/PSRLD-imm 16 mask low halves, PSUBD-recover high, signed CVTDQ2PS each, ADDPS-double the high to undo /2-shift, sum. i32x4.trunc_sat_f32x4_s 9-instr NaN-mask + XOR-fix recipe per `lower.isle:3848-3869`: CMPPS-self-EQ_OQ NaN-detect, ANDPS-mask NaN→+0.0, CVTTPS2DQ saturating-trunc, then XOR-flip positive-OOR's 0x80000000 → 0x7FFFFFFF via PSRAD-imm-31-derived sign-extend mask. Both use only XMM14/XMM15 of the 2-scratch budget. Remaining 4 variants (f64x2.convert_low_i32x4_u + i32x4.trunc_sat_{f32x4_u, f64x2_s_zero, f64x2_u_zero}) defer to 9.7-ag pending ADR-0042 const-pool plumbing — trunc_sat_f32x4_u additionally needs 3 scratch xmms; 162 SIMD ops handled total `[x]`), 9.7-af (q15mulr_sat_s + dot_i16x8_s — 2 ops: 2 new encoders encPmulhrsw (SSSE3 66 0F 38 0B /r via existing escape-2 helper) + encPmaddwd (SSE2 66 0F F5 /r). PMULHRSW's hardware "M" suffix = round-to-nearest matches Wasm Q15 multiply-round-saturate exactly. PMADDWD's pairwise i16×i16→i32 wrapping accumulation matches Wasm spec at the boundary INT16_MIN^2 + INT16_MIN^2 = 0x80000000+0x80000000 → 0 mod 2^32 (cranelift `lower.isle:4073-4078`). Both single-instr ops dispatch through existing emitV128IntBinop helper (no new infrastructure). 12 extmul + 1 popcnt + 4 extadd_pairwise variants defer to 9.7-ag/ah/ai (different recipe shapes / const-pool deps); 164 SIMD ops handled total `[x]`), 9.7-ag (i16x8.extmul × 4: i16x8.extmul_{low,high}_i8x16_{s,u} via cranelift `lower.isle:1197-1285` recipe — extend each i8x16 operand to i16x8 via PMOVSXBW (signed) or PMOVZXBW (unsigned), then PMULLW. 2 parametric helpers: emitV128IntExtmulLow (3-instr: PMOVSX/ZX BW lhs→XMM14, PMOVSX/ZX BW rhs→dst, PMULLW dst, XMM14) + emitV128IntExtmulHigh (5-instr: PSHUFD imm=0xEE prefix on each operand to swap upper-64→lower-64 into XMM14/XMM15 before extending). 4 wrappers parametric on extend encoder (signed vs unsigned). No new encoders — pure composition of 9.7-c (PMULLW) + 9.7-x (PMOVSX/ZX) + 9.7-e (PSHUFD) primitives; 168 SIMD ops handled total `[x]`), 9.7-ah (i32x4.extmul × 4: i32x4.extmul_{low,high}_i16x8_{s,u} via the same cranelift recipe shape as 9.7-ag — PMOVSXWD / PMOVZXWD extend (i16→i32) + PMULLD multiply (SSE4.1, from 9.7-c). 4 wrappers reuse emitV128IntExtmulLow/High helpers from 9.7-ag unchanged, parameterised over extension width and multiply encoder. No new encoders. Continuation chunk under textbook_survey.md's narrow definition (zero new encoders / helpers / design choices); 172 SIMD ops handled total `[x]`), 9.7-ai (i64x2.extmul × 4: i64x2.extmul_{low,high}_i32x4_{s,u} with distinct recipe shape — PMULDQ (SSE4.1) / PMULUDQ already widen i32→i64 from even-numbered lanes so no separate PMOVSX/ZX prefix is needed. 3-instr inline recipe per cranelift `lower.isle`: PSHUFD imm=0x50 (low: lanes 0/1 → slots 0/2) or 0xFA (high: lanes 2/3 → slots 0/2) on each operand into dst + XMM14, then PMULDQ/PMULUDQ. New encoder encPmuldq (SSE4.1 66 0F 38 28 /r); PMULUDQ already from 9.7-d. New helper emitV128I64x2Extmul (parametric on PSHUFD imm + multiply encoder). Closes the extmul family across i16x8/i32x4/i64x2 (12 ops total across 9.7-ag/ah/ai); 176 SIMD ops handled total `[x]`), 9.7-aj (i16x8.extadd_pairwise_i8x16 × 2: PCMPEQB ones + PABSB → 0x01-per-byte mask synthesised inline (no const-pool dep), then PMADDUBSW (SSSE3 — first/second operand role flipped between _u and _s variants since PMADDUBSW reads dst as unsigned and src as signed; with +1 in either slot the saturating-multiply-and-add reduces to plain pairwise add fitting in i16). New encoder encPmaddubsw (SSSE3 66 0F 38 04 /r). 2 new ZirOp entries — extadd_pairwise_i8x16_{s,u} were missing from the enum. 4-instr (_u: needs MOVAPS dst,src) / 3-instr (_s: dst becomes the mask directly); 178 SIMD ops handled total `[x]`), 9.7-ak (i32x4.extadd_pairwise_i16x8_s 1 op: PCMPEQB ones + PSRLW imm 15 → 0x0001-per-word mask (= +1 per i16 lane), then PMADDWD reduces to pairwise add. 4-instr inline. PMADDWD existing from 9.7-af; PSRLW-imm existing from 9.7-v. No new encoders. 2 new ZirOp entries (i32x4.extadd_pairwise_i16x8_{s,u}); only `_s` lands now — `_u` variant defers because PMADDWD reads operands as signed i16 so high u16 lanes need const-pool sign-flip pre-correction (deferred to ADR-0042 chunk); 179 SIMD ops handled total `[x]`), 9.7-al (ADR-0042 const-pool port to x86_64 + v128.const 1 op: mirrors §9.6/9.6-f-ii ARM64 work (commit `c12760cb`) for x86_64. New SimdConstFixup struct (types.zig: disp32_byte_offset + post_insn_byte + const_idx) + simd_const_fixups ArrayList threaded through emit.zig + post-emit pool append/patch loop after the trap stub (16-byte aligned). New encoders encMovupsXmmRipRelPlaceholder (SSE PC-relative MOVUPS xmm, [RIP+disp32] — 6 bytes for XMM0..XMM7, 7 bytes with REX.R for XMM8..XMM15) + patchRipRelDisp32. emitV128Const handler. ZirFunc.simd_consts already populated by lower.zig since 9.6-f-ii; only x86_64 emit-side was missing. i8x16.shuffle defers to 9.7-am (needs PSHUFB recipe + per-lane index validation); 180 SIMD ops handled total `[x]`), 9.7-am (i32x4.trunc_sat_f64x2_s_zero 1 op: first multi-instr const-pool consumer beyond v128.const, validates the foundation. New per-emit-pass extra_consts ArrayList collects emit-time-derived shared consts (distinct from func.simd_consts per-instance literals); post-emit pool concatenates both lists, fixup const_idx maps uniformly. Recipe per cranelift `lower.isle:4194-4214`: MOVUPS const-load (INT32_MAX_f64-broadcast) + MOVAPS + CMPPD-self-EQ NaN-mask + MINPD upper-clamp + ANDPD NaN-zero + CVTTPD2DQ. CVTTPD2DQ writes 2 i32 to low half, zeros high half (matches "_zero" suffix). Negative OOR auto-saturates to 0x80000000 = INT32_MIN per CVTTPD2DQ semantics. New encoder encCvttpd2dq (SSE2 66 0F E6 /r). i8x16.shuffle still deferred — needs derived a-mask/b-mask plumbing which is structurally different; 181 SIMD ops handled total `[x]`), 9.7-an (i8x16.popcnt 1 op: SSSE3 PSHUFB-LUT recipe per cranelift `lower.isle:2491-2517`. Two const-pool entries via extra_consts: 16-byte POPCNT_LUT (byte i = popcount(i) for i in 0..15) + NIBBLE_MASK_BROADCAST (0x0F per byte). 11-instr inline recipe (incl. 2 MOVUPS-RIP-rel const loads): split each input byte into low/high nibbles, look each up in LUT via PSHUFB, PADDB the two halves. PSHUFB clobbers dst so LUT loads twice — the per-instance double-load is cheaper than 3rd-scratch juggling and the const is shared via extra_consts dedup. Also factors helpers `lookupOrAppendExtraConst` + `emitConstLoad` for future const-pool consumers; 182 SIMD ops handled total `[x]`), 9.7-ao (f64x2.convert_low_i32x4_u 1 op: IEEE-754 mantissa-overlay trick per cranelift `lower.isle:3775-3779`. 2 const-pool entries via extra_consts: UINT_MASK_LOW (0x43300000-per-dword, single-precision pattern of 0x1.0p+52) + UINT_MASK_HIGH (0x4330000000000000-per-qword, double-precision 2^52). 5-instr recipe: MOVAPS dst,src + MOVUPS const_low + UNPCKLPS-interleave-low (each qword becomes 0x4330_0000_<u32>, which as f64 = 2^52 + u32) + MOVUPS const_high + SUBPD subtract 2^52 → u32 as f64 exactly via IEEE-754 unit-ULP recovery. New encoder encUnpcklps (SSE 0F 14 /r). Discharges one of the 4 deferred 9.7-ae u-variants; 184 SIMD ops handled total `[x]`), 9.7-ap (i32x4.trunc_sat_f64x2_u_zero 1 op: ROUNDPD + ADDPD-magic + SHUFPS-extract recipe per cranelift `lower.isle:5061-5093`. 7-instr inline recipe + 2 const-pool entries: MOVAPS dst,src + PXOR t1,t1 (zeros) + MAXPD-zero-clamp (NaN→0 via 2nd-operand-on-unordered + negative→0) + MINPD-UMAX_f64-clamp + ROUNDPD imm 0x0B (round-to-zero | suppress-precision) + ADDPD-2^52-magic + SHUFPS imm 0x88 to gather low-32 of each qword into i32x4 lanes 0/1 with lanes 2/3 zero ("_zero" suffix). Reuses 9.7-ao's UINT_MASK_HIGH (= 2^52 magic) via extra_consts dedup; new const UINT32_MAX_F64_BROADCAST (4294967295.0). New encoder encShufps (SSE 0F C6 /r ib). Discharges another of the 4 deferred 9.7-ae u-variants; 185 SIMD ops handled total `[x]`), 9.7-aq (i32x4.extadd_pairwise_i16x8_u 1 op: closes the extadd_pairwise family. PMADDWD reads operands as signed i16, so for u16 lanes we sign-flip pre-multiply and bias-correct post-multiply — XOR src with 0x8000-per-word converts u16 → i16 in [-0x8000, 0x7FFF]; PMADDWD with +1 produces (i16+i16) i32 sums = (u16+u16) - 0x10000; PADDD adds 0x10000 per i32 to recover. 11-instr inline recipe (no const-pool dep — all 3 mask constants synthesised from PCMPEQB seed via shifts: PSLLW-imm 15 → 0x8000-per-word, PSRLW-imm 15 → 0x0001-per-word, PSRLD-imm 31 + PSLLD-imm 16 → 0x00010000-per-dword). New encoder encPsllwImm (SSE2 66 0F 71 /6 ib via existing shift-imm-group helper). Closes the extadd_pairwise family across all 4 variants (9.7-aj's i8x16-input pair + 9.7-ak's i16x8 _s + this chunk's i16x8 _u); 186 SIMD ops handled total `[x]`), 9.7-ar (i8x16.shuffle 1 op: closes the structural blocker flagged in §9.7-al/am — needs derived per-instance a-mask + b-mask. Resolution: emit-time derivation from `func.simd_consts[ins.payload]`; handler appends both derived masks to extra_consts. Recipe per cranelift `lower.isle:4710+`: PSHUFB(src1, a_mask) | PSHUFB(src2, b_mask) where a_mask[i] = mask[i] if mask[i] < 16 else 0x80, b_mask[i] = mask[i]-16 if mask[i] in 16..31 else 0x80. PSHUFB writes 0 when ctrl bit 7 set, so each side contributes only its valid lanes; POR merges. 7-instr inline (incl. 2 const loads). No new encoders. Side-finding: spike confirmed D-054 (OrbStack as-loop-broke) is hoist-pass codegen bug, not Rosetta — see updated D-054 entry; 187 SIMD ops handled total `[x]`), 9.7-as (D-054 close: SysV x86_64 frame_unaligned was missing r15_save_bytes, causing local 0 at [RBP-16] to sit BELOW RSP after `SUB RSP, frame_bytes` when outgoing_max_bytes=0 (no Win64 shadow space). The next `call $dummy` pushed its return address to [RSP-8] = [RBP-16] clobbering local 0 (the observed 0xFD1BD386 garbage = stack residue). Win x86_64 hid the bug because outgoing_max_bytes=32 (Win64 shadow) inflated the frame to 40 bytes. 1-line fix in emit.zig:278 — `frame_unaligned = outgoing_max_bytes + locals_bytes + spill_bytes + r15_save_bytes`. OrbStack now 212/0/20 strict (was 211/1/20 D-054 carry). Investigation: cross-compiled the same as-loop-broke fixture's emit bytes for x86_64-linux + x86_64-windows (via Mac), diffed → only 4 byte positions differ (entry_arg0 reg + frame size); decoded that frame size for SysV is too small to contain the local. 187 SIMD ops total (D-054 close orthogonal to SIMD count) `[x]`), 9.7-at (i32x4.trunc_sat_f32x4_u 1 op: closes the last of the 4 deferred 9.7-ae u-variants. 14-instr inline two-path recipe per cranelift `lower.isle:3919-3962`: clamp(src, 0) via XORPS+MAXPS → CVTTPS2DQ for [0, INT_MAX] lanes; subtract magic (0x4f000000 = INT_MAX+1 as f32, synthesised via PCMPEQD+PSRLD+CVTDQ2PS) → CVTTPS2DQ for [INT_MAX+1, UINT_MAX] lanes; CMPPS-LE mask + PXOR + PMAXSD-with-zero clamp + PADDD merge. New encoder encPmaxsd (SSE4.1 0F 38 3D /r) via existing encSsePackedIntBinopExt helper. Reframing: prior session's "3 scratch xmm" reading was wrong — dst (regalloc'd from XMM8..XMM13) + XMM14 + XMM15 already gives 3 distinct physical registers within fp_spill_stage_xmms reservation; same dual-scratch pattern as 9.7-q/w/ac. No ABI change. 188 SIMD ops handled total `[x]`), 9.7-au (int min/max + sat arith + avgr_u — 22 ops: i8x16/i16x8/i32x4 × {min_s, min_u, max_s, max_u} (12 ops) + i8x16/i16x8 × {add_sat_s, add_sat_u, sub_sat_s, sub_sat_u} (8 ops) + i8x16/i16x8.avgr_u (2 ops). 15 new encoders — encPminsb/Pmaxsb/Pminsd (SSE4.1 via encSsePackedIntBinopExt), encPminsw/Pmaxsw + encPaddsb/w + encPsubsb/w + encPaddusb/w + encPsubusb/w + encPavgb/w (SSE2 via encSsePackedIntBinop). Unsigned min/max encoders already landed in 9.7-n (PMINU/PMAXU recipe consumers). All 22 wrappers dispatch through 9.7-b's `emitV128IntBinop` unchanged. Liveness extended in shared/regalloc.zig (22 entries appended, same 2-in 1-out v128 shape as add/sub cluster). Cranelift cross-check `inst.isle:2470-2486` confirms direct PMIN*/PMAX* mapping. 210 SIMD ops handled total `[x]`), 9.7-av (FP pseudo-min/max — 4 ops: f32x4/f64x2 × {pmin, pmax}. Single-instruction MINPS/MAXPS/MINPD/MAXPD dispatch with **operand swap**: dst=c2, src=c1. The Wasm pmin(c1,c2) = `if c2 < c1: c2 else c1` semantics align with x86 MINPS's "return SRC on equal/NaN/both-zero" (Intel SDM Vol 2A) when dst holds c2. cranelift `lower.isle:1542-1545` makes the same call via CLIF bitselect-of-fcmp-LT pattern matching MINPS. New helper emitV128FpPseudoBinop (operand-swapped variant of 9.7-b's emitV128IntBinop). No new encoders — reuses 9.7-q's encMinps/Maxps/Minpd/Maxpd. Distinct from 9.7-q's fmin/fmax which need 10-13 instr NaN-correction synthesis (those produce IEEE-754 canonical min/max; pmin/pmax are spec-asymmetric). 214 SIMD ops handled total `[x]`), 9.7-aw (i64x2.extract_lane — 1 op via PEXTRQ (SSE4.1 REX.W=1 variant of PEXTRD; same opcode 0x16, REX.W promotes operand to 64-bit). New encoder encPextrQ mirrors encPextrD with W bit always set. Handler emitI64x2ExtractLane mirrors 9.7-e's emitI32x4ExtractLane with u1 lane (i64x2 has 2 lanes); uniform 8-byte spill stride via existing gprStoreSpilled. Liveness already in shared/regalloc.zig from §9.4 IR opening. 215 SIMD ops handled total `[x]`), 9.7-ax (v128.load + v128.store — 2 ops, foundation memory chunk. Mirrors scalar `op_memory.emitMemOp` shape with access_size=16 + MOVUPS final encoding. New encoder encMovupsMemBaseIdx (load 0F 10 /r, store 0F 11 /r — no prefix per Intel SDM Vol 2A; ModR/M+SIB scale=1 base+index addressing mirrors encMovssMovsdMemBaseIdx). emitV128Load + emitV128Store + shared v128MemPrologue helper in op_simd.zig (RAX/RCX/RDX scratches reused; bounds_fixups + ADR-0028 trace.writeBounds wired uniformly with scalar). uses_runtime_ptr prescan in emit.zig extended (v128.load / v128.store join the existing scalar-mem-op list — both touch [R15+vm_base_off] / [R15+mem_limit_off]). Subsequent 9.7-ay/az/ba/bb sub-chunks (load_splat / load_zero / load_lane / load*x*_*) reuse the v128MemPrologue helper. 217 SIMD ops handled total `[x]`), 9.7-ay (v128.load{8,16,32,64}_splat — 4 ops. All reuse 9.7-ax's v128MemPrologue with access_size 1/2/4/8 + a per-lane-width broadcast tail. No new encoders. load8_splat: MOVZX RCX, byte [mem]; MOVD dst, ECX; PXOR XMM14, XMM14; PSHUFB dst, XMM14 (zero-mask broadcast — cranelift `lower.isle:4840-4843` uses PINSRB-mem; we lack mem-form so 1-extra-instr GPR roundtrip). load16_splat: MOVZX + MOVD + PSHUFLW imm 0 + PSHUFD imm 0. load32_splat: MOVSS [mem] (zero-extend upper 96) + PSHUFD imm 0 (cranelift `lower.isle:4893-4895`). load64_splat: MOVSD [mem] (zero-extend upper 64) + PSHUFD imm 0x44 (broadcast low qword to upper); MOVDDUP would be 1 instr but adding encoder for one consumer is over-investment. uses_runtime_ptr prescan extended for 4 ops. 221 SIMD ops handled total `[x]`). | [ ] in progress |
| 9.8  | x86_64 emit (SSE4.1): SIMD comparison + shuffle + float arithmetic + conversion. | [ ]            |
| 9.9  | `simd.wast` spec test wired in; fail=skip=0 across both backends (3-host gate). | [ ]            |
| 9.10 | SIMD smoke benches against wasmtime + wazero + wasmer; recorded to `bench/results/history.yaml` per ADR-0012. **Per-op gap analysis required**: identify ops where v2 lags by > 3× the median of (wasmtime, wazero, wasmer) and file Phase 15 debt entries naming the candidate optimisation (AVX path adoption gated on CPUID, MOVAPS preamble peephole at op_simd binop sites, SIMD-specific coalescing). v1 reached "adequate for embedded" but explicitly accepted ~43× gap to wasmtime (D122); v2 inherits this gap as starting point and §9.10 produces the gap profile that drives Phase 15 SIMD-specific work scope beyond v1 W43/W44/W45 porting. | [ ]            |
| 9.11 | Phase-9 boundary `audit_scaffolding` pass + SHA backfill. | [ ]            |
| 9.12 | Open §9.10 inline + flip phase tracker. | [ ]            |

### Phase 10 — GC, EH, Tail call, memory64 (Wasm 3.0 完備) 🔒

**Goal**: WebAssembly 3.0 feature-complete.

**Exit criterion**:

- WasmGC: struct.new, array.new, ref.test, ref.cast, sub-typing.
- Exception Handling: try-table, throw, throw_ref. Stack frame
  unwinding.
- Tail Call: return_call, return_call_indirect, return_call_ref.
- memory64 lit up; existing load/store ops accept 64-bit offsets.
- All Phase-5 proposals' spec tests pass=fail=skip=0 (both backends).
- Bench: no unexplained regression vs Phase 9 baseline.

**🔒 gate**: yes.

### Phase 11 — WASI 0.1 full + bench infra

**Goal**: production-ready WASI 0.1 + complete bench harness.

**Exit criterion**:

- All 50 realworld samples pass on Mac + Linux.
- Windows realworld subset (25 samples, C+C++ tier as v1) passes.
- `bench/history.yaml` gets per-merge automatic recording on Mac
  natively, Linux via OrbStack, and Windows via `windowsmini` SSH
  (`scripts/run_remote_windows.sh`).
- `bash scripts/run_bench.sh --quick` works locally.

**🔒 gate**: no.

### Phase 12 — AOT compilation mode

**Goal**: `zwasm compile` produces `.cwasm`; `zwasm run *.cwasm`
loads in fewer-than-startup-of-JIT time.

**Substrate inherited from §9.8b/8b.3** (per ADR-0040 migration):
the generator pipeline + `.cwasm` v0.1 format land in §9.8b
(ADR-0039); Phase 12 finalises the consumer side. The §9.8b
artefacts (`src/engine/codegen/aot/{format, serialise,
produce}.zig` + `src/cli/compile.zig`) are the loader's contract.

**Exit criterion**:

- `.cwasm` format defined: header + serialised regalloc + machine
  code + relocation table. **Loader reads against `format.zig`'s
  60-byte `CwasmHeader` + 12-byte `CwasmFuncMeta` + 9-byte
  `CwasmReloc` shapes** (ADR-0039 + Revision 2 numeric
  correction).
- AOT and JIT outputs are differential-test-equivalent.
- Cross-compile (`zig build -Dtarget=x86_64-linux`) works; cross-
  produced `.cwasm` runs on the target.
- **Cold-start bench-delta**: load + first-call time vs JIT
  first-invocation ≥30% improvement on at least 3 v1-class
  hyperfine fixtures (target derived from `private/notes/p8-8b3-
  aot-survey.md`'s 30-50% cold-start estimate; concrete
  threshold set when §9.12 task table expands). **This is the
  bench-delta obligation that §9.8b/8b.3 deferred per ADR-0040.**

**🔒 gate**: no.

### Phase 13 — C API full (wasm-c-api conformance) 🔒

**Goal**: wasm-c-api conformance test passes.

**Exit criterion**:

- All ~130 functions in `wasm.h` implemented.
- `wasi.h` and `zwasm.h` ABI surface complete.
- `test/c_api_conformance/` (wasmtime example port + zwasm-specific
  tests) fail=0.
- `examples/{c_host, zig_host, rust_host}/` all build and run on all
  3 OS.

**🔒 gate**: yes.

### Phase 14 — CI matrix infrastructure

**Goal**: GitHub Actions matrix replaces ad-hoc local-only gating.

**Exit criterion**:

- `.github/workflows/pr.yml` runs the full test suite on
  `macos-15`, `ubuntu-22.04`, `windows-2022`.
- `.github/workflows/main.yml` records per-merge bench numbers on
  all 3 OS into `bench/history.yaml`.
- `.github/workflows/nightly.yml` runs fuzz + spec-bump + proposal-
  watch.
- `.github/workflows/bench_baseline.yml` (workflow_dispatch) records
  arch baselines on demand.
- The local `pre_push` hook still works; CI is a second line, not
  the first.

**🔒 gate**: no.

### Phase 15 — Performance parity with v1 + ClojureWasm migration

**Goal**: zwasm v2 matches v1's bench performance and runs
ClojureWasm. **Per ADR-0043**: Phase 15 SIMD work absorbs (a) v1
W43/W44/W45 ports onto the v2 substrate as documented below and
(b) bench-driven SIMD-specific optimisations surfaced by §9.10's
per-op gap analysis (AVX path adoption gated on CPUID, MOVAPS
preamble peephole at op_simd binop sites, SIMD-specific
coalescing — concrete candidates filed as debt entries by
§9.10). The "v1 parity" target is the floor, not the ceiling:
exceeding v1's ~43× gap to wasmtime (per v1 D122 self-assessment)
is in scope where §9.10's gap profile + a feasibility-supported
debt entry name a candidate.

**Substrate inherited from §9.8b/8b.1 + 8b.2** (per ADR-0040
migration):

- Coalescer scaffolding lands at §9.8b/8b.1 per ADR-0036 (pass
  module + `CoalesceRecord` types + `func.coalesced_movs` slot
  + `isCoalesceCandidate` predicate + `compile.zig` pipeline
  placement). Phase 15 layers concrete **detection logic**
  (operand-stack vreg-numbering simulation + same-slot-event
  subscription against the §9.8b/8b.2-c LIFO free-pool).
- LIFO free-pool allocator at §9.8b/8b.2-c per ADR-0037
  Revision 2 (busy-mask scan replaced with explicit free-pool;
  semantic equivalence). Phase 15 extends with **class-aware
  allocation** per D-036 §option-b + ADR-0038 (liveness type-
  tagging + dual-pool GPR/FP slots + tighter `spillBytes()`
  accounting).

**Exit criterion**:

- v1's optimisations (W43 SIMD addr cache, W44 reg class, W45 SIMD
  loop persistence, W54-class loop-invariant magic-constant hoist,
  D116-D135 line items as applicable) are ported as **clean
  additions** onto the v2 substrate (since the slots are already in
  `ZirFunc`). No retrofits.
- **Coalescer detection bench-delta**: ≥5% on loop-heavy
  fixtures with the §9.8b/8b.1 scaffolding's detection layer
  populated (target from `private/notes/p8-8b1-coalescer-
  survey.md`). **This is the runtime-bench obligation that
  §9.8b/8b.1 deferred per ADR-0036 + ADR-0040.**
- **Class-aware allocator bench-delta**: ≥3% on FP-heavy
  fixtures with the dual-pool allocator landed (per ADR-0038
  + ADR-0040). Combined coalescer + class-aware aggregate
  ≥10% on at least 3 v1-class fixtures.
- Bench shows no unexplained regression vs zwasm v1 main.
- ClojureWasm CI green when its `zwasm` dependency points to a local
  path of `zwasm_from_scratch/` (via `build.zig.zon` `path = ...`).
  No commits to ClojureWasm side are required for v2-experimental
  validation.

**🔒 gate**: no, but extensive bench validation.

### Phase 16 — Public release v0.1.0 🔒

**Goal**: zwasm v2 replaces v1 as the recommended runtime.

**Exit criterion**:

- All Phase 0-15 exit criteria still hold.
- `CHANGELOG.md`, `docs/migration_v1_to_v2.md`, `README.md` complete.
- `docs/reference/` (API), `docs/tutorial/` complete.
- GitHub release tag `v0.1.0` cut; binaries published for all 3 OS.
- `bench/history.yaml` v0.1.0 baseline rows recorded on all 3 OS.

**🔒 gate**: yes — final gate.

### Post-v0.1.0 (v0.2.0 line)

- Component Model + WASI 0.2.
- Threads + atomics.
- Optimising tier (post-baseline).
- Other tier promotions as Wasm proposals advance.

---

## 10. Consumer surface design

zwasm v2 has three independent consumer surfaces. They share
internal core types (Runtime / Trap / Value) but each has its
own ergonomic shape and stability boundary.

### 10.A Zig library surface (per ADR-0025)

Zig hosts that import zwasm as a Zig package see the surface
defined by `src/zwasm.zig` per ADR-0025. The 3-line happy path:

```zig
const zwasm = @import("zwasm");
var rt = try zwasm.Runtime.init(alloc, .{});
defer rt.deinit();
var module = try zwasm.Module.parse(&rt, wasm_bytes);
defer module.deinit();
var instance = try module.instantiate(.{});
defer instance.deinit();
try instance.invoke("fib", &args, &results);
```

**Stable surface** (per ADR-0025 D-7): `Runtime`, `Module`,
`Instance`, `Trap`, `Value`, `WasiConfig`, `ImportEntry`,
`TypedFunc(P, R)`, `ParseError`, `InstantiateError`. Other
re-exports under `zwasm.parse / .ir / .engine / ...` exist for
the build system + test runners and are **not** stability-
committed. Breaking changes to the stable surface are allowed
v0.1.0 → v0.2.0; SemVer compatibility starts at v1.0.

ClojureWasm v1 (the only known external Zig consumer per
CLAUDE.md context) is migrated to the new surface as Phase C
of ADR-0025's implementation chain (after Phase D's
`docs/migration_v1_to_v2.md` Zig section ships).

### 10.B CLI surface

(continues below — original §10 content)

### 10.1 Subcommands

```
zwasm run        <wasm-or-cwasm-file> [args...]
zwasm compile    <wasm-file> [-o output.cwasm]
zwasm validate   <wasm-file>
zwasm inspect    <wasm-file>
zwasm features   [<wasm-file>]
zwasm wat        <wasm-file>
zwasm wasm       <wat-file>
zwasm version
zwasm help       [<subcommand>]
```

`zwasm <wasm-file>` is a shortcut for `zwasm run <wasm-file>`.

### 10.2 Engine selection

The engine (interpreter / JIT / AOT) is selected automatically:

- `.wasm` input + JIT-enabled build → JIT.
- `.wasm` input + interpreter-only build (`-Dengine=interp`) → interpreter.
- `.cwasm` input → AOT-loaded (file extension dictates).

**Override**:

- `--interpreter` — force interpreter mode (debugging, tracing, JIT
  bug investigation). The flag is named `--interpreter` (not `--interpret`)
  to be unambiguous.

There is **no `--jit` flag** (it is the default when compiled in)
and **no `--aot` flag** (the `.cwasm` file extension dictates). This
mirrors wasmtime's CLI shape.

### 10.3 wasmtime-aligned naming

- `--invoke NAME[=ARGS]` — function to invoke.
- `--wasi` / `--no-wasi` — WASI on/off (default auto-detect from imports).
- `--dir HOST=GUEST` — preopen a directory.
- `--env KEY=VAL` — set wasm-side env var.
- `--fuel N` — fuel limit.
- `--timeout DURATION` — wall-clock timeout (`100ms`, `30s`, `5m`).

### 10.4 wasm-c-api layered ABI

`include/wasm.h` is upstream wasm-c-api; `include/wasi.h` is the
wasmtime-compatible WASI extension; `include/zwasm.h` adds
allocator injection, fuel, timeout, cancel, and the kind-less
fast-path `zwasm_func_call_fast` for hot paths.

---

## 11. Test strategy

### 11.1 Unified runner: `zig build test-all`

Test layers are exposed as Zig build steps. There is **no
`bash test/run_all.sh`** — the unified entry point is `zig build`.

| Step                       | Phase intro | What                                               |
|----------------------------|-------------|----------------------------------------------------|
| `zig build test`           | 0           | Unit tests inline in `src/**/*.zig`                |
| `zig build test-spec`      | 1           | WebAssembly spec testsuite (Zig-native runner)     |
| `zig build test-e2e`       | 4           | End-to-end CLI invocations                         |
| `zig build test-realworld` | 4           | 50 known-good wasm samples (matches v1)            |
| `zig build test-c-api`     | 3           | wasm-c-api conformance                             |
| `zig build test-fuzz`      | 5           | Quick fuzz smoke (full campaigns are nightly)      |
| `zig build test-diff`      | 6           | `interp == jit_native` differential                |
| `zig build test-all`       | 0           | All of the above (skips not-yet-implemented steps) |

External tools (`wast2json`, `hyperfine`, `wat2wasm`) are pinned by
`flake.nix`. Build steps `addSystemCommand` them and emit a helpful
error if absent.

### 11.2 Test data policy (uniform across CI / local / OS)

Single rule: **source-of-truth committed; derivatives rebuilt on
demand** — with one exception (heavyweight toolchain outputs).

| Category                                        | source-of-truth (committed)                                                                         | derivative (handling)                                                                                                                                                          |
|-------------------------------------------------|-----------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Self-authored `.wat`                            | `test/spec/wat/*.wat`                                                                               | `.wasm` regenerated by `zig build test-spec`                                                                                                                                   |
| Self-authored `.wast`                           | `test/spec/wast/*.wast`                                                                             | `.json` regenerated via `wast2json`                                                                                                                                            |
| Wasm spec testsuite                             | local copy under `~/Documents/OSS/WebAssembly/testsuite/` (pinned via `scripts/regen_test_data.sh`) | `.json` regenerated                                                                                                                                                            |
| WASI testsuite                                  | similar — pinned external repo                                                                     | regenerated                                                                                                                                                                    |
| Realworld samples (TinyGo / Rust / emcc / etc.) | C / Rust / Go source under `test/realworld/src/` (committed)                                        | **`.wasm` also committed** under `test/realworld/wasm/` (toolchain reproducibility is heavy; the binary is a snapshot) + `scripts/regen_test_data.sh` documents how to rebuild |
| Bench wasm                                      | source under `bench/runners/src/` or `~/Documents/OSS/sightglass/`                                  | `.wasm` committed under `bench/runners/`                                                                                                                                       |
| Fuzz corpus                                     | none (generated by `wasm-tools smith`)                                                              | gitignored, regenerated locally                                                                                                                                                |

A single script — `scripts/regen_test_data.sh` — re-derives everything
and is identical across Mac / Linux / Windows. CI delegates to the
same script. There is **no per-OS divergence** in test data prep.

`.gitignore` reflects this: `test/spec/json/`, `test/e2e/wast/`,
`test/e2e/json/`, `test/fuzz/corpus/` are gitignored. Realworld
`.wasm` is committed.

### 11.3 Differential testing (Phase 7+)

```zig
test "differential: <name>" {
    const wasm = @embedFile("./testdata/<name>.wasm");
    const ref = try runWith(.interpret, wasm);
    const jit = try runWith(.jit, wasm);
    try expectDeepEqual(ref, jit);
}
```

Combined with the three-platform gate (Mac aarch64 + OrbStack
Ubuntu x86_64 + windowsmini SSH), the three-way invariant
`interp == jit_arm64 == jit_x86` is enforced without needing a
single host that runs both JITs.

### 11.4 Fuzz strategy

- Corpus: ~1800 wasm modules from `wasm-tools smith` (9 categories:
  mvp, simd, gc, eh, threads, mem64, tailcall, all, invalid).
- Edge cases: hand-crafted (truncated, bad magic, oversized LEB).
- Differential fuzz: random input → both `interp` and `jit_native`,
  assert equal.
- Overnight campaign: nightly CI run (Phase 14+); duration TBD per
  budget.
- Crash files saved to `test/fuzz/corpus/crash_*` and uploaded to
  GitHub Release on failure (Phase 14+).

### 11.5 Three-OS gate

Local pre-push (A7, A8):

- Mac aarch64 native — `bash scripts/gate_merge.sh`.
- OrbStack Ubuntu x86_64 native — `orb run -m my-ubuntu-amd64 bash
  -c '... gate_merge.sh'`.
- Windows x86_64 native — `bash scripts/run_remote_windows.sh` (drives
  the `windowsmini` SSH host; pulls `origin/zwasm-from-scratch` on
  the remote clone at `~/Documents/MyProducts/zwasm_from_scratch`,
  then runs the requested `zig build` step).

CI matrix lights up in Phase 14.

---

## 12. Performance and benchmarks

### 12.1 No fixed numeric targets

Per-phase numeric ratios (e.g. "within 1.5× of wasmtime") are
**deliberately not set**. Goodhart's law: a numeric target distorts
behaviour toward the number, not the underlying goal.

Instead:

- `bench/history.yaml` records every merge's numbers across 3 OS.
- A regression in any bench triggers investigation, not an automatic
  block.
- Comparison against reference runtimes (wasm3, wasmtime baseline,
  wasmtime cranelift, wasmer singlepass) is recorded but not gated.
- v0.1.0 release simply requires "no unexplained regression vs v1
  baseline."

### 12.2 σ stability

- σ < 5% per measurement (5 runs + 3 warmup, hyperfine).
- Outliers (single run σ > 10%) → automatic re-measure.
- Linux CI: `taskset -c 0` for CPU pinning.
- macOS: `nice -19 hyperfine --warmup 5 --runs 10 --shell=none`.

### 12.3 history.yaml schema

```yaml
- date: 2026-XX-XXTHH:MM:SSZ
  commit: <full SHA>
  arch: aarch64-darwin | x86_64-linux | x86_64-windows
  reason: "Record benchmark for <subject>"
  runs: 5
  warmup: 3
  benches:
    - name: coremark
      median_ms: 12.34
      stddev_ms: 0.45
```

### 12.4 Cadence

- **Per-merge** (Phase 14+, automated CI): full hyperfine on Mac;
  Linux and Windows rows recorded by the matrix.
- **Per-merge** (Phase 0–13, manual): Mac via `bash
  scripts/record_merge_bench.sh`; Linux + Windows via the analogous
  remote scripts when results are needed.
- **Manual baselines**: `bash scripts/record_merge_bench.sh
  --arch=...` records on demand.

### 12.5 Binary size

No fixed numeric target either. v0.1.0 release records the actual
size; v1's range (1.20–1.60 MB stripped) is the informal sanity
check — if v2 is much larger, that's an investigation trigger, not
a build-time error.

---

## 13. Commit discipline and work loop

### 13.1 Granularity

- One commit = one logical change. TDD red-then-green is two commits
  (the red test commit and the green code commit) only when the red
  test is large enough to stand alone; otherwise one commit.
- Never commit when tests are red.
- Source commits and ADR commits may co-occur (an ADR documenting
  the source change in the same commit is encouraged).

### 13.2 Commit message format

`<type>(<scope>): <subject>` where type ∈ {feat, fix, docs, refactor,
chore, test, bench, ci, build}, scope ∈ {p0, p1, ..., p16, all,
infra, ...}.

Example: `feat(p1): parser handles multi-value block params`.

Body explains *why* when non-trivial; the diff explains *what*.

### 13.3 Branch discipline

- Long-lived branch: `zwasm-from-scratch` (push only with user
  approval).
- main branch is frozen for v1.

### 13.4 The TDD loop (driven by `continue` skill)

See `.claude/skills/continue/SKILL.md` for the canonical procedure.

### 13.5 No copy from v1

zwasm v1 is read as a textbook (Step 0 Survey, see
`.claude/rules/textbook_survey.md`). **Copy-and-paste is forbidden**
(see `.claude/rules/no_copy_from_v1.md`). Every line of v2 is
re-designed; if the result happens to look identical to a v1 line,
that's fine, but the act of typing it is the act of re-deciding.

---

## 14. Forbidden actions (inviolable)

```
❌ Pushing to main (v1 frozen)
❌ Pushing to zwasm-from-scratch without user approval
❌ git push --force / --force-with-lease to any branch
❌ git reset --hard discarding committed work
❌ git commit --no-verify
❌ git rebase -i (interactive, unsupported in CI)
❌ Single file > 2000 lines (hard cap A2)
❌ Bypassing zone_check.sh (A1)
❌ Cross-arch JIT imports (jit_arm64 ↔ jit_x86)
❌ pub var as a vtable (use a struct field)
❌ std.Thread.Mutex (use std.Io.Mutex or std.atomic.Mutex)
❌ std.io.AnyWriter (use *std.Io.Writer)
❌ ARM64-only or x86-only feature (P7)
❌ Running one backend after Phase 8 without differential check
❌ Adding to wasm.h without an ADR
❌ Per-task / per-concept Japanese chapter cadence (P9)
❌ Skipping Step 5 (test gate) on commit
❌ Skipping Step 0 (Survey) when introducing a new public API
❌ Copy-paste from zwasm v1 (P10; see rules/no_copy_from_v1.md)
❌ Hyphens in file or directory names (A11)
❌ Pervasive `if (build_options.<feature>)` branches in main code paths
   (use dispatch-table registration; see §4.5 / A12)
❌ Numeric performance ratio targets baked into ROADMAP / CI gate
   (see §12.1)
❌ Single field serving two distinct semantic axes (e.g. one
   `arity` slot used by both `end` and `br`); split per axis from
   day 1 (see rules/single_slot_dual_meaning.md, ADR-0014 §6.K.5)
❌ Workaround / SKIP-X-MISSING fallback without paired root-cause
   investigation OR a debt-ledger row naming the structural
   barrier (see rules/extended_challenge.md, .dev/debt.md
   discipline; the §9.6 / 6.F windowsmini wasmtime stub case is
   the worked example)
```

---

## 15. Future go/no-go decision points

- **End of Phase 5** — re-evaluate ZIR design: are the slot-based
  growth assumptions holding, or is a redesign needed before Phase
  7 JIT lands?
- **End of Phase 6** — does the v1 regression suite (carry-over
  tests + 50 realworld + ClojureWasm guest) actually pass under v2
  interp? If gaps remain (missing ops, semantic divergences),
  Phase 7 (JIT) does not open until they close (A13).
- **End of Phase 7** — does the interpreter v1-surface readiness
  (WASI 0.1 full = Phase 11; wasm-c-api full = Phase 13) merit
  pulling forward before Phase 8 JIT optimisation? Re-evaluate
  with realworld JIT data from §9.7 / 7.9 (ARM64 realworld) and
  7.10 (x86_64 realworld), not speculation. Surfaced by the
  2026-05-04 design dialogue (regret triage); ADR-0021 documents
  the deferral. If reorder is justified, file an ADR amending
  Phase 8/11/13 ordering at that point.
- **End of Phase 8** — is the differential test pass rate stable?
  If frequent diff failures persist, the JIT design is wrong, not
  the test.
- **End of Phase 10** — is the Wasm 3.0 feature-complete claim
  defensible? If the spec test corpus has unimplemented opcodes,
  Phase 11+ does not open.
- **End of Phase 15** — does ClojureWasm work on zwasm v2 with no
  measurable user-visible regression? If not, Phase 16 release is
  blocked.
- **Post-v0.1.0** — does the ecosystem (other hosts adopting
  wasm-c-api against zwasm) materialise to justify v0.2.0 work
  (Component Model + WASI 0.2)? If only ClojureWasm consumes zwasm,
  v0.2.0 priorities can shift toward smaller wins.

---

## 16. References

- v1 charter: `~/Documents/MyProducts/zwasm/.dev/zwasm-v2-charter.md`
- v1 D100-D138: `~/Documents/MyProducts/zwasm/.dev/decisions.md`
- v1 W54 post-mortem: `~/Documents/MyProducts/zwasm/.dev/archive/w54-redesign-postmortem.md`
- Pre-skeleton investigation: `~/zwasm/private/v2-investigation/CONCLUSION.md`
- ClojureWasm v2 ROADMAP: `~/Documents/MyProducts/ClojureWasmFromScratch/.dev/ROADMAP.md`
- WebAssembly Core 3.0 spec: `~/Documents/OSS/WebAssembly/spec/`
- wasm-c-api: `~/Documents/OSS/wasm-c-api/include/wasm.h`
- wasmtime cranelift / winch: `~/Documents/OSS/wasmtime/`
- regalloc2: `~/Documents/OSS/regalloc2/`
- sightglass (bench reference): `~/Documents/OSS/sightglass/`

---

## 17. Glossary

- **ZIR** — Zwasm Intermediate Representation (this project's mid-IR;
  §4.2).
- **VCode** — wasmtime cranelift's machine-IR (post-isel,
  pre-regalloc). Reference for ZIR's shape.
- **regalloc2** — wasmtime's register allocator (linear-scan + graph
  coloring). Reference for `src/jit/regalloc.zig`.
- **wasm-c-api** — `WebAssembly/wasm-c-api`; the de-facto standard
  C ABI (§4.4).
- **WASI** — WebAssembly System Interface; `wasi_snapshot_preview1`
  (0.1), Component Model wit (0.2 / 0.3).
- **🔒 gate** — phases marked require Mac native + OrbStack Ubuntu
  native + windowsmini build to pass before proceeding.
- **Differential test** — running the same wasm through interp and
  JIT, asserting identical output (§4.2 / Phase 7+).
- **Three-OS** — macOS aarch64, Linux x86_64, Windows x86_64; all
  first-class (P11).
- **Single-pass** — decode → ZIR → regalloc → emit, four linear
  passes per function. Not "no IR" (the cranelift winch sense).
- **Dispatch table** — central registry mapping `ZirOp` to handler
  function pointers; the mechanism by which feature modules add
  ops without pervasive `if`-branching (§4.5).
- **`windowsmini`** — local SSH-accessible Windows x86_64 host used
  for build / test / bench. See `.dev/windows_ssh_setup.md`.

---

## 18. Amendment policy

This document is a "now" snapshot. Early-phase planning will
inevitably miss dependencies that only become visible when later
phases are implemented. **Correcting such mismatches IS the
maintenance work, not an ad-hoc patch.** This section governs how
to do that without eroding the document's role as the single source
of truth.

### 18.1 When to amend ROADMAP itself (vs. add an ADR-only deviation)

Amend in place when the document already disagrees with reality:

- An exit criterion, scope row, or task description references a
  feature whose implementation is scoped to a later phase.
- A directory / file name in §5 has been superseded.
- A principle in §2 needs sharpening because a later phase exposed
  an edge case the principle did not anticipate.

Add an ADR **instead** of amending when:

- A genuinely new design decision is being made (not a correction
  of an unobserved pre-existing inconsistency).
- A deviation from a §2 principle is justified as a one-time
  trade-off and should not generalise into the document.

### 18.2 The four-step amendment

When amending, do all four — none of them are optional:

1. **Edit ROADMAP in place.** Write the corrected text as if it had
   always been so. The document is a "now" snapshot; consistency
   matters more than preserving past wording. Do not add inline
   change-bars, dated comments, or `~~strikethrough~~`.
2. **Open an ADR** (`.dev/decisions/NNNN_<slug>.md`) recording the
   original wording, the new wording, and *why the mismatch existed*.
   The ADR is the changelog; ROADMAP is not.
3. **Sync `handover.md`** if its "Active task" / "Current state"
   sections cited the amended text.
4. **Reference the ADR in the commit message** that lands the
   ROADMAP edit so `git log -- .dev/ROADMAP.md` is browseable for
   cause.

### 18.3 Forbidden

- Editing ROADMAP without an accompanying ADR for load-bearing
  changes (anything in §1, §2, §4, §5, §9 phase rows, §11 layers,
  §14 forbidden list).
- Adding a "revision history" section back to this document — the
  trail is git log + ADRs.
- Editing principle text in §2 without an ADR (always load-bearing).
- "Quiet" renumbering of `§N` headings; if a renumber is unavoidable,
  it gets its own ADR and a sweep of every `§N.M` reference under
  `.claude/`, `.dev/`, and source comments.

### 18.4 Why this exists

Without 18.1–18.3 the project drifts in one of two failure modes:

- ROADMAP turns into an aspirational document that nobody updates
  because every change "feels like ad-hoc" and is delayed indefinitely.
- ROADMAP becomes a free-form scratchpad with edits scattered across
  history, and the "single source of truth" claim quietly dies.

The four-step amendment keeps the ROADMAP correct as a present-
tense plan while preserving full traceability through ADRs and git
log.

---

> **Note on history**: this document is a "now" snapshot, not a
> changelog. What changed and why lives in
> `git log -- .dev/ROADMAP.md` and `.dev/decisions/NNNN_*.md` ADRs
> (load-bearing rationale). The amendment process itself is §18.
