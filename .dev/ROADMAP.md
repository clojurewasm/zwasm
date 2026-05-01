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
| P3  | **Cold-start is the primary metric**         | Compile pipeline is single-pass (no SSA optimisation passes). AOT mode (Phase 11) is the second answer.                                                                                        |
| P4  | **Zig 0.16 idioms**                          | `std.Io` DI, `*std.Io.Writer`, `packed struct`, `comptime`, `@branchHint`. No `std.Thread.Mutex`, no `std.io.AnyWriter`.                                                                       |
| P5  | **link_libc=false, host-side**               | All host math via Zig builtins (LLVM intrinsics). No libm. No MSVCRT.                                                                                                                          |
| P6  | **Single-pass compilation**                  | Decode → ZIR → regalloc → emit, four linear passes per function. No multi-pass IR optimisation.                                                                                             |
| P7  | **Both backends are equal**                  | Any feature that exists in `jit_arm64/` exists in `jit_x86/`. No "ARM64-only" or "x86-only" implementations.                                                                                   |
| P8  | **wasm-c-api is the C ABI primary**          | `zwasm.h` extensions are subordinate. ABI breakage requires an ADR (with deprecation window).                                                                                                  |
| P9  | **Knowledge compression by ROADMAP and ADR** | ROADMAP narrates the project; ADRs justify deviations from it. There is no per-task / per-concept chapter cadence.                                                                             |
| P10 | **v1 stays untouched, but is not copied**    | The v1 `main` is frozen for ClojureWasm. v2 work happens on `zwasm-from-scratch`. v1 source may be **read** as a textbook; **never copy-and-paste** — re-design every line.                   |
| P11 | **Three OS first-class**                     | macOS aarch64, Linux x86_64, Windows x86_64 are all gated locally (Mac + OrbStack + Windows-mini SSH).                                                                                         |
| P12 | **Differential testing is the oracle**       | Every test that runs a wasm module asserts `interp == jit` on the host's native backend. The two-platform gate (and Phase 13's CI matrix) gives `interp == jit_arm64 == jit_x86` transitively. |
| P13 | **Day-one ZIR sized for the full target**    | All Wasm 3.0 ops + Phase 3-4 proposal ops + JIT pseudo-ops are reserved as `ZirOp` slots from day 1. Implementation is staged; the type is not.                                                |
| P14 | **Optimisation lands last in commit order**  | Phases 1-9 = simplest correct implementation. Phase 14 = port v1's optimisation work (W43 / W44 / W45 / W54-class) onto the v2 substrate, where the slots already exist.                       |

### 2.1 Architecture rules (verifiable)

| #   | Rule                                                                                                                                         | Verified by                                      |
|-----|----------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------|
| A1  | Lower zones do not import upper zones                                                                                                        | `scripts/zone_check.sh --gate`                   |
| A2  | One file ≤ 1,000 lines (soft) / ≤ 2,000 lines (hard)                                                                                       | `scripts/file_size_check.sh`                     |
| A3  | Cross-arch backends do not import each other (`jit_arm64` ↔ `jit_x86`)                                                                      | `scripts/zone_check.sh --gate`                   |
| A4  | `ZIR.verify()` runs after every analysis pass                                                                                                | Inline in `src/ir/verifier.zig`; called per pass |
| A5  | Differential test gates every wasm-execution test (Phase 6+)                                                                                 | `zig build test-all`                             |
| A6  | ADR is required for: layer/contract change, ZIR shape change, C ABI surface change, phase order change, regression allowance, tier promotion | Reviewer checklist; pre-merge audit              |
| A7  | Mac native + OrbStack Ubuntu native = local pre-push gate                                                                                    | `.githooks/pre_push`                             |
| A8  | Windows x86_64 native verified via SSH (`windowsmini`) before any v0.1.0 release                                                             | `scripts/run_remote_windows.sh` (Phase 14+)      |
| A9  | Bench history is append-only                                                                                                                 | `bench/history.yaml` reviewed at every merge     |
| A10 | Spec test fail=0 / skip=0 is a merge gate (Phase 2+)                                                                                         | `zig build test-spec`                            |
| A11 | All paths are `snake_case`; no hyphens in file or directory names                                                                            | Reviewer; convention                             |
| A12 | Feature opcodes are added through dispatch-table registration, not pervasive build-time `if` branches                                        | §4.5 design                                     |

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
- **Optimising tier** (Phase 12+): copy-and-patch, SSA mid-IR, or
  cranelift-as-backend.
- **RISC-V / s390x backends**: separate ADR each.

---

## 4. Architecture

### 4.1 Four-zone layered (absolute dependency direction)

```
Zone 3: src/cli/ + src/main.zig         -- CLI entry, argparse, subcommand
        src/c_api/                       -- C ABI export layer (wasm.h / wasi.h / zwasm.h)
                                         ↓ may import anything below

Zone 2: src/interp/                      -- Threaded-code interpreter
        src/jit/                         -- Shared JIT (regalloc, reg_class, prologue, emit_common, aot)
        src/jit_arm64/                   -- ARM64-specific emit
        src/jit_x86/                     -- x86-specific emit
        src/wasi/                        -- WASI 0.1 implementation
                                         ↓ may import Zone 0+1

Zone 1: src/ir/                          -- ZIR + verifier + analysis (loop_info, liveness)
        src/runtime/                     -- Module / Instance / Store / Memory / Trap / Float / Value / GC
        src/frontend/                    -- Parser / Validator / Lowerer (wasm body → ZIR)
        src/feature/                     -- Per-spec-feature modules (registered into dispatch tables)
                                         ↓ may import Zone 0 only

Zone 0: src/util/                        -- LEB128, duration, hash, sort
        src/platform/                    -- Linux / Darwin / Windows / POSIX abstractions
                                         ↑ imports nothing above
```

Enforcement: `scripts/zone_check.sh --gate` parses every `@import`
and rejects upward-direction violations. Cross-arch (`jit_arm64` ↔
`jit_x86`) imports are also rejected (A3).

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
    // Pseudo opcodes — JIT-internal, populated Phase 6+ (when JIT v1 lands)
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

    // Populated Phase 6+ (JIT register allocator)
    reg_class_hints: ?[]RegClass = null,
    spill_slots: ?[]SpillSlot = null,
    inst_ptr_cache_layout: ?CacheLayout = null,
    vm_ptr_cache_layout: ?CacheLayout = null,
    simd_base_cache_layout: ?CacheLayout = null,

    // Populated Phase 8+ (SIMD additional state)
    simd_lane_routing: ?LaneRouting = null,

    // Populated Phase 9+ (GC / EH / tail call additional state)
    gc_root_map: ?GcRootMap = null,
    eh_landing_pads: ?[]LandingPad = null,
    tail_call_sites: ?[]TailCallSite = null,

    // Populated Phase 14+ (optimisation passes)
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
   ▼  src/frontend/  (parser → validator → lowerer)
[ZIR]
   │
   ▼  src/ir/       (loop_info → liveness → const_prop → verifier)
[ZIR (annotated)]
   │
   ├── engine = interpreter ─┐
   │                          ▼
   │                   src/interp/  (threaded-code dispatch)
   │                          │
   │                          ▼  execute
   │
   └── engine = jit ──────────┐
                              ▼
                       src/jit/regalloc + reg_class
                              │
                              ▼  src/jit_arm64/emit  or  src/jit_x86/emit
                       [machine code]
                              │
                              ├── JIT mode: in-memory pages (mprotect + jump)
                              │              ▼  execute
                              │
                              └── AOT mode: serialise to .cwasm + relocation
                                            │
                                            ▼  on-disk .cwasm file
                                            │
                                            ▼  load (mmap)
                                            │
                                            ▼  execute
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

Implementation:

```
src/c_api/wasm_c_api.zig    # implements wasm.h
src/c_api/wasi_c_api.zig    # implements wasi.h
src/c_api/zwasm_ext.zig     # implements zwasm.h
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
each feature lives in its own subtree under `src/feature/` and
registers its handlers into central dispatch tables at module-load
time.

```
src/feature/
├── mvp/                  # Wasm 1.0 — always built
├── ext_2_0/              # Wasm 2.0 additions (always built when -Dwasm>=2.0)
│   ├── multivalue/
│   ├── sign_ext/
│   ├── sat_trunc/
│   ├── bulk_memory/
│   ├── ref_types/
│   └── simd/
├── ext_3_0/              # Wasm 3.0 additions (always built when -Dwasm>=3.0)
│   ├── memory64/
│   ├── eh/
│   ├── tail_call/
│   ├── func_refs/
│   ├── gc/
│   ├── extended_const/
│   └── relaxed_simd/
└── ext_proposals/        # Phase 3-4 proposals — built when explicitly enabled
    ├── threads/
    ├── wide_arith/
    ├── stack_switching/
    ├── custom_page_sizes/
    └── memory_control/
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
-Dwasi=p1                   (default p1 only at v0.1.0; p2 lights up post-v0.1.0)
-Dengine=both|jit|interp    (default both; selects which engines are compiled in)
-Doptimize=Debug|ReleaseFast|ReleaseSafe|ReleaseSmall  (Zig standard)
-Dstrip=true|false          (default false; strips debug info from the CLI binary)
```

Source-separation principle (A12): each feature module is its own
directory; the build system includes/excludes the directory based
on flags. There is **no `if (gc_enabled)`** in the parser /
validator / interp / emitter. The dispatch table is populated only
if `gc/mod.zig` was compiled in.

Zig's `comptime` makes this clean: the build system passes the set
of enabled feature modules to a comptime-generated `register_all`
function that inlines each feature's `register` call.

### 4.7 Runtime handle + std.Io DI

```zig
pub const Runtime = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: Engine,         // wasm-c-api primary handle
    stores: ArrayList(*Store),
    config: Config,         // fuel limit, timeout, allocator injection
    vtable: VTable,         // backend dispatch (interp / jit_arm64 / jit_x86)
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
- Bounds check via guard pages (Phase 6+) — out-of-range access
  triggers `SIGSEGV` (POSIX) / `EXCEPTION_ACCESS_VIOLATION`
  (Windows), caught by the JIT's signal handler and converted to a
  Wasm trap.
- Memory64 is part of the ZIR shape from day 1; the implementation
  lights up in Phase 9.

### 4.10 GC subsystem (Phase 9+)

WasmGC adds heap-allocated typed values (struct, array, i31). The
implementation lives in `src/runtime/gc/`:

- `arena.zig` — phase-scoped arena (Phase 1+, infrastructure only)
- `mark_sweep.zig` — mark-sweep collector (Phase 9+)
- `roots.zig` — root tracking (operand stack + locals + globals + tables)

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
│   └── zwasm.h                 # zwasm extensions (allocator inj Phase 4+; fuel/cancel Phase 6+)
│
├── src/
│   ├── main.zig
│   ├── cli/
│   │   ├── argparse.zig
│   │   ├── run.zig
│   │   ├── compile.zig
│   │   ├── validate.zig
│   │   ├── inspect.zig
│   │   ├── features.zig
│   │   ├── wat.zig
│   │   └── wasm.zig
│   │
│   ├── frontend/
│   │   ├── parser.zig
│   │   ├── validator.zig
│   │   ├── lowerer.zig
│   │   └── opcode.zig
│   │
│   ├── ir/
│   │   ├── zir.zig
│   │   ├── verifier.zig
│   │   ├── loop_info.zig
│   │   ├── liveness.zig
│   │   ├── const_prop.zig
│   │   ├── opcode_table.zig
│   │   └── dispatch_table.zig
│   │
│   ├── runtime/
│   │   ├── module.zig
│   │   ├── instance.zig
│   │   ├── store.zig
│   │   ├── engine.zig
│   │   ├── memory.zig
│   │   ├── table.zig
│   │   ├── global.zig
│   │   ├── trap.zig
│   │   ├── float.zig
│   │   ├── value.zig
│   │   └── gc/
│   │       ├── arena.zig
│   │       ├── mark_sweep.zig
│   │       └── roots.zig
│   │
│   ├── feature/
│   │   ├── mvp/
│   │   ├── ext_2_0/
│   │   │   ├── multivalue/
│   │   │   ├── sign_ext/
│   │   │   ├── sat_trunc/
│   │   │   ├── bulk_memory/
│   │   │   ├── ref_types/
│   │   │   └── simd/
│   │   ├── ext_3_0/
│   │   │   ├── memory64/
│   │   │   ├── eh/
│   │   │   ├── tail_call/
│   │   │   ├── func_refs/
│   │   │   ├── gc/
│   │   │   ├── extended_const/
│   │   │   └── relaxed_simd/
│   │   └── ext_proposals/
│   │       ├── threads/
│   │       ├── wide_arith/
│   │       ├── stack_switching/
│   │       ├── custom_page_sizes/
│   │       └── memory_control/
│   │
│   ├── interp/
│   │   ├── threaded.zig
│   │   └── handlers.zig
│   │
│   ├── jit/
│   │   ├── regalloc.zig
│   │   ├── reg_class.zig
│   │   ├── emit_common.zig
│   │   ├── prologue.zig
│   │   └── aot.zig
│   │
│   ├── jit_arm64/
│   │   ├── emit.zig
│   │   ├── inst.zig
│   │   └── abi.zig
│   │
│   ├── jit_x86/
│   │   ├── emit.zig
│   │   ├── inst.zig
│   │   └── abi.zig
│   │
│   ├── wasi/
│   │   ├── preview1.zig
│   │   ├── fs.zig
│   │   ├── time.zig
│   │   └── random.zig
│   │
│   ├── c_api/
│   │   ├── wasm_c_api.zig
│   │   ├── wasi_c_api.zig
│   │   └── zwasm_ext.zig
│   │
│   ├── platform/
│   │   ├── linux.zig
│   │   ├── darwin.zig
│   │   ├── windows.zig
│   │   └── posix.zig
│   │
│   └── util/
│       ├── leb128.zig
│       ├── duration.zig
│       └── hash.zig
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
├── docs/                       # English public docs (Phase 14+)
│   ├── reference/
│   ├── tutorial/
│   └── migration_v1_to_v2.md   # written at Phase 14
│
├── scripts/
│   ├── zone_check.sh
│   ├── file_size_check.sh
│   ├── gate_commit.sh
│   ├── gate_merge.sh
│   ├── record_merge_bench.sh
│   ├── run_bench.sh
│   ├── run_spec.sh
│   ├── run_remote_windows.sh   # Phase 14+ — drives the windowsmini SSH host
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

**File-size discipline (A2)**:
- Soft cap 1,000 lines: warning + ADR for split plan.
- Hard cap 2,000 lines: gate fails.
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
| **Phase 5** | W3C Recommendation (Wasm 3.0) | **MUST** — implement in Phases 1–9 for v0.1.0 |
| **Phase 4** | Standardize                   | **Deferred to v0.2.0** for non-web items        |
| **Phase 3** | Implementation phase          | Per-feature judgement; mostly post-v0.1.0       |
| **Phase 2** | Proposed                      | Watch only                                      |
| **Phase 1** | Champion                      | Watch only                                      |

Tier promotions (Phase 4 → Phase 5) trigger a tier-promotion ADR
that updates `.dev/proposal_watch.md` and re-evaluates the phase
plan if the proposal hits Phase 5 during active development.

---

## 7. Concurrency design

- **Phases 0–9: single-threaded.** `Engine` is a process singleton;
  `Store` is host-thread-local.
- **Phase 10+:** multi-store, with `Engine` thread-safe (matches
  wasmtime convention). `wasm.h` allows shared modules; `zwasm.h`
  documents the safe sharing surface.
- **Wasm threads (atomics, shared memory)**: deferred to v0.2.0,
  after WASI 0.2 stabilises. ZIR slots are reserved (§4.2).
- **`std.Thread.Mutex` is forbidden** (Zig 0.16 removed it).
  Use `std.Io.Mutex` or `std.atomic.Mutex` only when concurrency
  actually arrives.
- **Cancellation** (`zwasm.h`'s `zwasm_module_cancel`): single
  atomic boolean checked at fuel-poll points. Phase 6+.

---

## 8. WASI strategy

- **WASI 0.1** (preview1): the realworld baseline. Phase 4 minimal
  subset; Phase 10 full surface.
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
| 3     | IN-PROGRESS | §9.3 / 3.0 (fetch wasm.h)     |
| 4     | PENDING     |                               |
| 5     | PENDING     |                               |
| 6     | PENDING     |                               |
| 7     | PENDING     |                               |
| 8     | PENDING     |                               |
| 9     | PENDING     |                               |
| 10    | PENDING     |                               |
| 11    | PENDING     |                               |
| 12    | PENDING     |                               |
| 13    | PENDING     |                               |
| 14    | PENDING     |                               |
| 15    | PENDING     |                               |

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
| 3.0  | `scripts/fetch_wasm_c_api.sh` — fetch `wasm.h` verbatim from upstream + pin commit (ADR). | [ ]            |
| 3.1  | `include/wasm.h` vendored read-only; build.zig wires the include path.                    | [ ]            |
| 3.2  | `src/c_api/wasm_c_api.zig` — Zone-3 module, exports the C ABI shapes (engine/module/...). | [ ]            |
| 3.3  | `wasm_engine_new` / `wasm_engine_delete` — engine lifetime; allocator threading.          | [ ]            |
| 3.4  | `wasm_module_new` / `_module_validate` / `_module_delete` — wraps frontend pipeline.      | [ ]            |
| 3.5  | `wasm_instance_new` / `_instance_delete` — wraps Runtime instantiation.                   | [ ]            |
| 3.6  | `wasm_func_call` — wraps interp dispatch; param + result `wasm_val_t` marshalling.        | [ ]            |
| 3.7  | `wasm_*_vec_t` types + `wasm_trap_t` — vec discipline, trap surface.                      | [ ]            |
| 3.8  | `examples/c_host/hello.c` — minimal C host invoking `wasm_func_call`.                     | [ ]            |
| 3.9  | `zig build test-c-api` — gates the example builds + runs on all three hosts.              | [ ]            |
| 3.10 | Phase-3 boundary `audit_scaffolding` pass.                                                 | [ ]            |
| 3.11 | Open §9.4 inline; flip phase tracker.                                                      | [ ]            |

### Phase 4 — WASI 0.1 minimal 🔒

**Goal**: TinyGo / Rust `_start` runs as a CLI.

**Exit criterion**:

- WASI 0.1 subset: `args_*`, `environ_*`, `clock_time_get`,
  `random_get`, `fd_close/read/write/seek/tell`, `path_open`,
  `proc_exit`, `poll_oneoff`.
- 30+ realworld samples (out of the 50 from v1) run to completion
  with stdout matching `wasmtime run`.
- `zwasm run hello.wasm` works on all 3 OS.

**🔒 gate**: yes.

### Phase 5 — ZIR analysis layer

**Goal**: the slots reserved in Phase 1 are populated.

**Exit criterion**:

- `src/ir/loop_info.zig` (branch_targets, loop_headers, loop_end)
  computed for every parsed function.
- `src/ir/liveness.zig` (per-vreg live ranges) computed.
- `src/ir/verifier.zig` runs after every analysis pass; CI calls it
  on the spec corpus.
- `src/ir/const_prop.zig` (limited const folding).

**🔒 gate**: no.

### Phase 6 — JIT v1 ARM64 baseline

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

### Phase 7 — JIT v1 x86_64 baseline 🔒

**Goal**: x86_64 backend equal to ARM64; differential test gate.

**Exit criterion**:

- `src/jit_x86/{emit, inst, abi}.zig` (REX, ModR/M, SIB; SystemV +
  Win64 ABIs).
- spec test pass=fail=skip=0 via JIT on Linux x86_64 AND Windows
  x86_64.
- All 50 realworld samples pass via JIT on both archs.
- **Three-way differential test (`interp == jit_native`) on each
  host** — 0 mismatch. The two-platform local gate plus Windows-mini
  SSH gives `interp == jit_arm64 == jit_x86` transitively.

**🔒 gate**: yes — this is the most important gate of the project.

### Phase 8 — SIMD-128

**Goal**: SIMD-128 fixed-width ops on both backends.

**Exit criterion**:

- `simd.wast` spec test fail=skip=0 (both backends).
- SSE4.1 minimum baseline; runtime feature detection refuses to start
  on older x86 CPUs.
- SIMD smoke benches recorded against reference runtimes; no fixed
  numeric ratio target.

**🔒 gate**: no.

### Phase 9 — GC, EH, Tail call, memory64 (Wasm 3.0 完備) 🔒

**Goal**: WebAssembly 3.0 feature-complete.

**Exit criterion**:

- WasmGC: struct.new, array.new, ref.test, ref.cast, sub-typing.
- Exception Handling: try-table, throw, throw_ref. Stack frame
  unwinding.
- Tail Call: return_call, return_call_indirect, return_call_ref.
- memory64 lit up; existing load/store ops accept 64-bit offsets.
- All Phase-5 proposals' spec tests pass=fail=skip=0 (both backends).
- Bench: no unexplained regression vs Phase 8 baseline.

**🔒 gate**: yes.

### Phase 10 — WASI 0.1 full + bench infra

**Goal**: production-ready WASI 0.1 + complete bench harness.

**Exit criterion**:

- All 50 realworld samples pass on Mac + Linux.
- Windows realworld subset (25 samples, C+C++ tier as v1) passes.
- `bench/history.yaml` gets per-merge automatic recording on Mac
  natively, Linux via OrbStack, and Windows via `windowsmini` SSH
  (`scripts/run_remote_windows.sh`).
- `bash scripts/run_bench.sh --quick` works locally.

**🔒 gate**: no.

### Phase 11 — AOT compilation mode

**Goal**: `zwasm compile` produces `.cwasm`; `zwasm run *.cwasm`
loads in fewer-than-startup-of-JIT time.

**Exit criterion**:

- `.cwasm` format defined: header + serialised regalloc + machine
  code + relocation table.
- AOT and JIT outputs are differential-test-equivalent.
- Cross-compile (`zig build -Dtarget=x86_64-linux`) works; cross-
  produced `.cwasm` runs on the target.

**🔒 gate**: no.

### Phase 12 — C API full (wasm-c-api conformance) 🔒

**Goal**: wasm-c-api conformance test passes.

**Exit criterion**:

- All ~130 functions in `wasm.h` implemented.
- `wasi.h` and `zwasm.h` ABI surface complete.
- `test/c_api_conformance/` (wasmtime example port + zwasm-specific
  tests) fail=0.
- `examples/{c_host, zig_host, rust_host}/` all build and run on all
  3 OS.

**🔒 gate**: yes.

### Phase 13 — CI matrix infrastructure

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

### Phase 14 — Performance parity with v1 + ClojureWasm migration

**Goal**: zwasm v2 matches v1's bench performance and runs
ClojureWasm.

**Exit criterion**:

- v1's optimisations (W43 SIMD addr cache, W44 reg class, W45 SIMD
  loop persistence, W54-class loop-invariant magic-constant hoist,
  D116-D135 line items as applicable) are ported as **clean
  additions** onto the v2 substrate (since the slots are already in
  `ZirFunc`). No retrofits.
- Bench shows no unexplained regression vs zwasm v1 main.
- ClojureWasm CI green when its `zwasm` dependency points to a local
  path of `zwasm_from_scratch/` (via `build.zig.zon` `path = ...`).
  No commits to ClojureWasm side are required for v2-experimental
  validation.

**🔒 gate**: no, but extensive bench validation.

### Phase 15 — Public release v0.1.0 🔒

**Goal**: zwasm v2 replaces v1 as the recommended runtime.

**Exit criterion**:

- All Phase 0-14 exit criteria still hold.
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

## 10. CLI / FFI design

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

### 11.3 Differential testing (Phase 6+)

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
- Overnight campaign: nightly CI run (Phase 13+); duration TBD per
  budget.
- Crash files saved to `test/fuzz/corpus/crash_*` and uploaded to
  GitHub Release on failure (Phase 13+).

### 11.5 Three-OS gate

Local pre-push (A7, A8):

- Mac aarch64 native — `bash scripts/gate_merge.sh`.
- OrbStack Ubuntu x86_64 native — `orb run -m my-ubuntu-amd64 bash
  -c '... gate_merge.sh'`.
- Windows x86_64 native — `bash scripts/run_remote_windows.sh` (drives
  the `windowsmini` SSH host; pulls `origin/zwasm-from-scratch` on
  the remote clone at `~/Documents/MyProducts/zwasm_from_scratch`,
  then runs the requested `zig build` step).

CI matrix lights up in Phase 13.

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

- **Per-merge** (Phase 13+, automated CI): full hyperfine on Mac;
  Linux and Windows rows recorded by the matrix.
- **Per-merge** (Phase 0–12, manual): Mac via `bash
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
chore, test, bench, ci, build}, scope ∈ {p0, p1, ..., p15, all,
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
❌ Running one backend after Phase 7 without differential check
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
```

---

## 15. Future go/no-go decision points

- **End of Phase 5** — re-evaluate ZIR design: are the slot-based
  growth assumptions holding, or is a redesign needed before Phase
  6 JIT lands?
- **End of Phase 7** — is the differential test pass rate stable?
  If frequent diff failures persist, the JIT design is wrong, not
  the test.
- **End of Phase 9** — is the Wasm 3.0 feature-complete claim
  defensible? If the spec test corpus has unimplemented opcodes,
  Phase 10+ does not open.
- **End of Phase 14** — does ClojureWasm work on zwasm v2 with no
  measurable user-visible regression? If not, Phase 15 release is
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
  JIT, asserting identical output (§4.2 / Phase 6+).
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
