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
  x86_64 are all gated. Mac runs locally; Linux x86_64 and Windows
  x86_64 are verified through SSH hosts (`ubuntunote` native +
  `windowsmini`) per ADR-0049 + ADR-0067 — plus, eventually,
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
| P11 | **Three OS first-class**                     | macOS aarch64, Linux x86_64, Windows x86_64 are all gated locally (Mac native + `ubuntunote` SSH + `windowsmini` SSH per ADR-0049 + ADR-0067).                                              |
| P12 | **Differential testing is the oracle**       | Every test that runs a wasm module asserts `interp == jit` on the host's native backend. The two-platform gate (and Phase 14's CI matrix) gives `interp == jit_arm64 == jit_x86` transitively. |
| P13 | **Day-one ZIR sized for the full target**    | All Wasm 3.0 ops + Phase 3-4 proposal ops + JIT pseudo-ops are reserved as `ZirOp` slots from day 1. Implementation is staged; the type is not.                                                |
| P14 | **Optimisation lands last in commit order**  | Phases 1-10 = simplest correct implementation. Phase 15 = port v1's optimisation work (W43 / W44 / W45 / W54-class) onto the v2 substrate, where the slots already exist.                      |

### 2.1 Architecture rules (verifiable)

| #   | Rule                                                                                                                                                     | Verified by                                         |
|-----|----------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------|
| A1  | Lower zones do not import upper zones                                                                                                                    | `scripts/zone_check.sh --gate`                      |
| A2  | One file ≤ 1,000 lines (soft) / ≤ 2,000 lines (hard)                                                                                                   | `scripts/file_size_check.sh`                        |
| A3  | Cross-arch backends do not import each other (`engine/codegen/arm64` ↔ `engine/codegen/x86_64`) per ADR-0023                                            | `scripts/zone_check.sh --gate`                      |
| A4  | `ZIR.verify()` runs after every analysis pass                                                                                                            | Inline in `src/ir/verifier.zig`; called per pass    |
| A5  | Differential test gates every wasm-execution test (Phase 7+)                                                                                             | `zig build test-all`                                |
| A6  | ADR is required for: layer/contract change, ZIR shape change, C ABI surface change, phase order change, regression allowance, tier promotion             | Reviewer checklist; pre-merge audit                 |
| A7  | Mac native + `ubuntunote` SSH (Linux x86_64 native) = local pre-push gate per ADR-0049 + ADR-0067                                                       | `.githooks/pre_push`                                |
| A8  | Windows x86_64 native verified via SSH (`windowsmini`) before any v0.1.0 release                                                                         | `scripts/run_remote_windows.sh` (Phase 15+)         |
| A9  | Bench history is append-only                                                                                                                             | `bench/history.yaml` reviewed at every merge        |
| A10 | Spec test fail=0 / skip=0 is a merge gate (Phase 2+)                                                                                                     | `zig build test-spec`                               |
| A11 | All paths are `snake_case`; no hyphens in file or directory names                                                                                        | Reviewer; convention                                |
| A12 | Feature opcodes are added through dispatch-table registration, not pervasive build-time `if` branches                                                    | §4.5 design                                        |
| A13 | v1 regression suite (test/wasmtime_misc/wast/ + 50 realworld + ClojureWasm guest) stays green from Phase 6 onward (ADR-0008; renamed per ADR-0012 §6.B) | `zig build test-wasmtime-misc-basic` + Phase-6 gate |

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
  per-merge recording (Mac directly, Linux via `ubuntunote` SSH,
  Windows via `windowsmini` SSH per ADR-0049 + ADR-0067).

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

| Tier        | Definition                    | zwasm intent                                     |
|-------------|-------------------------------|--------------------------------------------------|
| **Phase 5** | W3C Recommendation (Wasm 3.0) | **MUST** — implement in Phases 1–10 for v0.1.0 |
| **Phase 4** | Standardize                   | **Deferred to v0.2.0** for non-web items         |
| **Phase 3** | Implementation phase          | Per-feature judgement; mostly post-v0.1.0        |
| **Phase 2** | Proposed                      | Watch only                                       |
| **Phase 1** | Champion                      | Watch only                                       |

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

| Phase | State       | First open `[ ]` task                                                                       |
|-------|-------------|---------------------------------------------------------------------------------------------|
| 0     | DONE        | —                                                                                          |
| 1     | DONE        | —                                                                                          |
| 2     | DONE        | —                                                                                          |
| 3     | DONE        | —                                                                                          |
| 4     | DONE        | —                                                                                          |
| 5     | DONE        | —                                                                                          |
| 6     | DONE        | —                                                                                          |
| 7     | DONE        | —                                                                                          |
| 8     | DONE        | JIT optimisation foundation 🔒 (per ADR-0019)                                                |
| 9     | IN-PROGRESS | Wasm 1.0 + 2.0 (incl. SIMD) **literal 100%** (skip-impl == 0 across spec + edge_cases + realworld + differential) on 3 hosts + Phase 10 substrate readiness (build-option DCE across all layers; per ADR-0056 + ADR-0065 + ADR-0071 + ADR-0073) |
| 10    | PENDING     | GC, EH, Tail call, memory64 (Wasm 3.0 completion) 🔒                                          |
| 11    | PENDING     | WASI 0.1 full + bench infra (incl. SIMD per-op gap analysis, moved from §9.10 per Track A) |
| 12    | PENDING     | AOT compilation mode                                                                        |
| 13    | PENDING     | C API full (wasm-c-api conformance) 🔒                                                       |
| 14    | PENDING     | CI matrix infrastructure                                                                    |
| 15    | PENDING     | Performance parity with v1 + ClojureWasm migration                                          |
| 16    | PENDING     | Public release v0.1.0 🔒                                                                     |

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

### Phase 0 — Phase 8b — archived

Phase 0 through Phase 8b are all `DONE` per the §9 Phase Status widget
at the top of §9 (line ~1175). Their detailed task tables (Phase 0
through 8b.6, with row-level `[x]` SHA pointers and exit-criterion
prose) were extracted to
[`.dev/archive/roadmap_phase0_8.md`](../archive/roadmap_phase0_8.md)
during scaffolding-compression chunk §9.12-A / A5c (master plan §9.12-A;
2026-05-19). The archive is **historical record only** — no row is
load-bearing for Phase 9 or later work.

Brief summary of what each phase delivered (full detail in the archive):

- **Phase 0** — Repo skeleton + 3-host bootstrap + git hooks
  + zone_check / file_size_check gates. 🔒 gate cleared.
- **Phase 1** — Frontend MVP: parse + validate + lower Wasm Core 1.0
  → ZIR; full ZirOp enum declared (P13).
- **Phase 2** — Interpreter MVP: threaded-code interpreter; Wasm 2.0
  spec corpus fail=0/skip=0; 5+ realworld samples run. 🔒 gate cleared.
- **Phase 3** — wasm-c-api C ABI: `wasm_module_new` / `_instance_new` /
  `_func_call` / `_global_set` exposed.
- **Phase 4** — WASI 0.1 minimal (fd_read/write, environ, exit,
  clock). 🔒 gate cleared.
- **Phase 5** — ZIR analysis layer: loop_info, liveness, const_prop
  passes; lower pass framework.
- **Phase 6** — v1 conformance baseline: full spec-test wiring +
  Phase 7 prep + skip_*.md discipline. 🔒 strict-close gate cleared
  (per ADR-0012 §6.J).
- **Phase 7** — JIT v1 ARM64 baseline: arm64 emit + regalloc + ABI;
  Wasm 2.0 SIMD-128 ARM64 implementation; 100% PASS on ARM64.
  Hard transition gate §7.13 cleared into Phase 8.
- **Phase 8** — JIT optimisation foundation: x86_64 emit parity +
  differential test; bench infra; coalesce/regalloc scaffolds +
  AOT skeleton (§9.8b). 🔒 8b.6 closed Phase 8.

The detailed task tables (Phase 0 task list / Phase 1 task list /
etc.) live in the archive; phase-internal sub-chunk records are in
[`.dev/phase_log/`](phase_log/) per ROADMAP §18.3 + ADR-0014.


### Phase 9 — Wasm 1.0 + 2.0 (incl. SIMD) completion on 3 hosts

**Goal** (per ADR-0056 + ADR-0065): Wasm 1.0 base spec
(including the Module / Instance / Store / linker layer +
`(register ...)` cross-module binding + host imports +
start-trap propagation) AND Wasm 2.0 (including SIMD-128
fixed-width ops on both backends) complete on Mac aarch64 +
OrbStack Linux x86_64 + windowsmini Win x86_64.

**Exit criterion** (per ADR-0056 2026-05-17 amend, 4-category
`skip-impl == 0` predicate):

- **Cat I** — validator / parser spec-rule enforcement at 0
  (already).
- **Cat II** — spec-test harness multi-result entry helpers
  at 0 (`entry.zig` `FuncRet_<types>` + `dispatchMultiResult
  <shape>` runner arms).
- **Cat III** — Wasm 1.0 runtime instance binding at 0
  (Store + Instance registry, cross-module import linker,
  cross-module call dispatch, host import binding spectest
  family, start-trap propagation, `(register ...)` runner
  directive) per ADR-0065.
- **Cat IV** — windowsmini Windows SEH bridge for
  `assert_trap` recovery (D-084 / D-136 / D-028 cohort);
  Phase 9 batch-end sweep per ADR-0049.
- JIT covers all Wasm 2.0 ops (no hidden-skip dispatch
  fallthroughs); `test-all` wires `test-edge-cases`,
  `test-realworld-run-jit`, `test-wasmtime-misc-runtime`;
  bench infra clean (no script bugs, no dead error paths,
  no schema drift); ADR-0029 Path B `skip-impl == 0`
  enforcement real (gates the runner, not just narrative).
- SSE4.1+SSE4.2 minimum baseline (per ADR-0041 §5 amend at
  9.7-m); runtime feature detection refuses to start on
  older x86 CPUs.
- SIMD smoke benches recorded against reference runtimes;
  no fixed numeric ratio target.

**🔒 gate**: no (Phase 9 itself); the post-Phase-9 substrate
audit at §9.12 IS a hard gate per ADR-0062.

#### §9.9 task list (initial expansion; refines as the phase progresses)

| #       | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Status                               |
|---------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------|
| 9.0     | Open §9.9 inline + flip Phase Status widget (Phase 8 = DONE; Phase 9 = IN-PROGRESS).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | [x] (this commit)                    |
| 9.1     | Step 0 survey: SIMD-128 op catalogue + ARM64 NEON / x86_64 SSE4.1 encoding strategy across wasmtime / wasmer / zware / v1 zwasm. Headlines: 415 op variants across 59 spec test files; cranelift ISLE-DSL-based (unsuitable for Zig); winch single-pass visitor (closer analog, but SIMD currently a no-op macro); wasmer singlepass minimal SIMD coverage; v1 zwasm's parallel `simd_xreg` cache flagged in W54 post-mortem as anti-pattern. Three divergences identified: (a) one ZirOp per operation (shape-as-variant), (b) reuse FP-class register pool, (c) spec-fidelity float ops. Survey lands at `private/notes/p9-9.1-simd-survey.md`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | [x] (this commit)                    |
| 9.2     | ADR-0041 — SIMD-128 design framing: shape-as-variant ZirOp catalogue (171 variants pre-declared in zir.zig cover ~415 spec ops) + FP-class register pool reuse with shape-tag axis (per `single_slot_dual_meaning.md`) + feature-register pattern via `feature/simd_128/register.zig` (per ADR-0023 §4.5) + NEON IEEE-754 spec-fidelity strategy + SSE4.1 minimum baseline confirmed (PMULLD / PINSRB-W-D / PBLENDVB required). Spill-frame packing optimisation deferred to Phase 15 alongside ADR-0038 class-aware allocation.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | [x] (this commit; ADR-0041 Accepted) |
| 9.3     | Validator extension: SIMD value type (`v128`) + per-op type signatures via the prefix-`0xFD` dispatch (mirrors prefix-`0xFC` shape). MVP catalogue covers v128.const + v128.load/store + splat (per shape) + extract/replace_lane (per shape) + binop/unop/relop ranges + any_true. Per ADR-0041 Revision 2: validator's static-dispatch reality (not central DispatchTable consultation) acknowledged; full dispatch-table-driven validator is a Phase 14+ structural refactor. 10 unit tests cover happy-path + type-mismatch + truncated-immediate + unknown-sub-opcode rejection.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | [x] (this commit)                    |
| 9.4     | IR extension: SIMD ZirOp activation + lower paths via `emitPrefixFD` in `src/ir/lower.zig` (mirroring `emitPrefixFC` shape) — MVP catalogue covers v128.{const,load,store,load*x*_*,store,load*_splat,load*_zero,not} + i8x16.{shuffle,swizzle,splat,extract/replace_lane*} + i16x8/i32x4/i64x2/f32x4/f64x2 splats + extract/replace_lane variants + `i32x4.add` (representative binop). Adds `Allocation.shapeTag(vreg)` API + `ShapeTag` enum + `Allocation.shape_tags: ?[]const ShapeTag` field per ADR-0041 §"Decision" / 2 (separate-axis shape disambiguation per `single_slot_dual_meaning.md`). 9.4 MVP returns `.scalar` by default; 9.5+ ARM64 NEON emit populates `shape_tags` when the function contains v128 ops. 13 unit tests cover lower + ShapeTag round-trips + shuffle lane bound check + truncated immediate + unknown sub-opcode rejection.                                                                                                                                                                                                                                                                                                                             | [x] (this commit)                    |
| 9.5     | ARM64 emit (NEON): SIMD load/store + lane access + integer arithmetic.. Sub-chunks 9.5-a..* recorded in [`.dev/phase_log/phase9.md`](../phase_log/phase9.md#row-95--arm64-emit-neon--load-store--lane-access--int-arith) (extracted 2026-05-11; ROADMAP per §18 stays a now-snapshot).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | [x]                                  |
| 9.6     | ARM64 emit (NEON): SIMD comparison + shuffle + float arithmetic + conversion.. Sub-chunks 9.6-a..* recorded in [`.dev/phase_log/phase9.md`](../phase_log/phase9.md#row-96--arm64-emit-neon--cmp--shuffle--fp-arith--convert) (extracted 2026-05-11; ROADMAP per §18 stays a now-snapshot).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [x]                                  |
| 9.7     | x86_64 emit (SSE4.1+SSE4.2 baseline per ADR-0041 §5 amend at 9.7-m): SIMD load/store + lane access + integer arithmetic. Sub-chunks 9.7-a..* recorded in [`.dev/phase_log/phase9.md`](../phase_log/phase9.md#row-97--x8664-emit-sse41sse42-baseline) (extracted 2026-05-11; ROADMAP per §18 stays a now-snapshot).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | [x]                                  |
| 9.8     | x86_64 emit (SSE4.1): SIMD comparison + shuffle + float arithmetic + conversion. **Scope absorbed by §9.7 per ADR-0044** — these op families landed inside §9.7's progressive expansion (9.7-k..n compares; 9.7-o FP compares; 9.7-p..q FP arith; 9.7-ab..ae conversions; 9.7-ar shuffle; 9.7-aj..aq pairwise extadd; etc.). All 237 v128 ZirOps now have x86_64 handlers (verified by zir.zig:184-288 vs emit.zig grep). Closing as scope-merged routine status update.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [x] (per ADR-0044)                   |
| 9.9     | **Wasm 1.0 + 2.0 (incl. SIMD) 100% PASS** per ADR-0056 (2026-05-17 + 2026-05-18 amends) + ADR-0065 (2026-05-18 amend): `skip-impl == 0` literally across **Cat I + Cat II + Cat III** on **Mac + ubuntunote**. Cat IV (windowsmini SEH bridge + reconcile) **moved to row §9.13-0** per ADR-0049 + ADR-0056 (2026-05-18 amendments) — the 3-host invariant is preserved, the windowsmini gate just shifts position to AFTER §9.12 substrate audit cleanup, BEFORE §9.13 Phase-10 entry gate. JIT covers all Wasm 2.0 ops (no hidden-skip dispatch fallthroughs); `test-all` wires `test-edge-cases`, `test-realworld-run-jit`, `test-wasmtime-misc-runtime`; bench infra clean; ADR-0029 Path B enforcement real. Discharge tracked across umbrella row + per-category rows 9.9-II / 9.9-III; sub-chunks recorded in [`.dev/phase_log/phase9.md`](../phase_log/phase9.md#row-99--simdwast-spec-test-wiring) per ADR-0014 + §18.3. Execution playbook: [`.dev/phase9_close_plan.md`](../phase9_close_plan.md).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | [x]                                  |
| 9.9-II  | **Cat II — Multi-result entry helpers** per ADR-0065. Drain ~1400 multi-result `skip-impl` directives (48 manifest-level lines spread across func / if / call / br / block / loop corpora) by adding `extern struct FuncRet_<types>` definitions in `entry.zig`, `callXX_yy() Error!FuncRet_<types>` helpers, `dispatchMultiResult<shape>(...)` arms in `spec_assert_runner_non_simd.zig`, and `(arg_kinds, result_kinds_tuple)` entries in the distiller's `supported` set. Highest-impact shapes first: `(i64,i64,i32)→(i64,i32)` add64_u_with_carry family (8 manifests), then `()→(i32,i32)` + `(i32)→(i32,i32)`, `()→(i32,i64)`, `()→(i32,f64)`, `(i32)→(i32,i32,i64)`, `()→(i32,i32,i32)`, long-tail. Sub-chunks 9.9-II-* recorded in `phase_log/phase9.md`.                                                                                                                                                                                                                                                                                                                                                                                                                     | [x] `fb063b09`                       |
| 9.9-III | **Cat III — Wasm 1.0 instance / store / linker / cross-module / host-imports / start-trap** per ADR-0065. Drain 144 directives (136 cross-module + 4 host imports + 2 start-trap + 2 link-typecheck) by implementing: Store + Instance registry (`Store.register(name, *Instance)`), cross-module import linker (resolve `(import "M" "f" ...)` at instantiation; verify import-type ≡ export-type for `link-typecheck` cases), cross-module call dispatch (funcref carries originating-instance pointer; `call_indirect` works through cross-module-populated table entries), host import binding (spectest `print_i32` family bound to runner-provided host function pointers), start-trap propagation (instantiation fails if start function traps), spec_assert runner `(register ...)` directive handler with per-session instance map. Step 0 surveys before any sub-chunk: v1 zwasm Store/Instance/linker (read-only; no copy per `no_copy_from_v1.md`), wasmtime `crates/runtime/`, zware `src/`, prior `~/zwasm/private/v2-investigation/`. Sub-chunks 9.9-III-* recorded in `phase_log/phase9.md`. Likely 1–2 sub-ADRs (`0066_*` / `0067_*`) for Store / Instance lifetime model. | [x] `2dbd3f15`                       |
| 9.9-IV  | **Moved to §9.13-0** per ADR-0049 + ADR-0056 + ADR-0065 (2026-05-18 amendments). Originally read as "Cat IV windowsmini batch reconcile sweep AT §9.9 close"; user 2026-05-18 confirmation re-slots this to §9.13-0 (post-§9.12 substrate audit, pre-§9.13 Phase-10 entry). Row preserved for citation lineage; content moved to §9.13-0 below. No §9 renumber per ADR-0014.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | [~] moved to §9.13-0                  |
| 9.10    | **Moved to Phase 11** per Phase 10 prep Track A Option (3) (see `.dev/phase10_prep/track_a_9.10_scope.md` §3.3 + §7 + ADR-0043 Revision history 2026-05-12 row). SIMD per-op gap analysis (3× threshold; v1 D122 ≈ 43× gap reference; AVX / MOVAPS-peephole / SIMD-coalescing candidate list) folds into Phase 11's bench-infra cohort alongside D-074's `-Dwith-bench-compare` flag + wazero/wasmer flake additions — the natural carrier per D-074 barrier statement. Row number preserved (no §9 renumber per ADR-0014).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | [~] moved to Phase 11                |
| 9.11    | Phase-9 boundary `audit_scaffolding` pass + SHA backfill.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x] `f06a3c9b`                       |
| 9.12-pre | **ADR drafts + 3 Q3 spikes (autonomous prep for §9.12 collab gate)** per [`phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) §5.3. Drafts: ADR-0070 (libc dependency policy) / ADR-0071 (Phase 9 substrate audit resolution = Q2 P14 sharpening + Q3 adoption + Q4 boundary) / ADR-0072 (comment-as-invariant rule) / ADR-0073 (build-option DCE consistent substrate across all layers) + ADR-0050 amend (skip-impl one-way ratchet) + ADR-0023 §4.5 amend (per-op file pattern formal adoption). Spikes: `q3-zig-inline-switch/` (no compile-time wall at 581 tags; +1.9% .text vs plain) + `q3-interp-dispatch-bench/` (perf-null at production N=581; adoption proceeds on design-quality axes) + `q3-build-option-dce-poc/` (DCE substrate works literally per `nm` + `xxd` evidence). Exit: 6 ADRs landed with `Status: Proposed` + 3 spike measurement reports under `private/spikes/q3-*/`. | [x]                                  |
| 9.12    | **Phase 9 completion substrate re-examination — CLEARED** ([`.dev/phase9_completion_substrate_audit.md`](../phase9_completion_substrate_audit.md)). Collab review per ADR-0062 completed 2026-05-19: Q2 P13 = Accept (re-eval at §9.12-B if op gaps surface); Q2 P14 = Amend (sharpen + Structural cohesion caveat per ADR-0071); Q2 §4.5 = Amend (per-op file pattern; ADR-0023 §4.5 amend); Q2 §4.6 = Accept (4-layer DCE; ADR-0073); Q3 = **Hypothesis C** (per-op file + comptime collector + inline switch); Q4 = Decision + minimal PoC (i32.add in C pattern across 6 builds; §9.12-B for remaining ops); Q5 = 5 deliverables (ADR-0072 + new rules + lint + D-133 sweep) + **dedup sweep of existing rules/lints** in §9.12-C; Q6 = ADR-0070 (libc 3-category + 5 deliverables in §9.12-D; forward-looking management). ADRs 0070 / 0071 / 0072 / 0073 → Accepted; ADR-0023 §4.5 amend + ADR-0050 D-5/D-6 amend confirmed. ROADMAP §14 forbidden list amended (Unconscious libc fanout / skip-impl regression). Phase Status widget wording updated. Hard-gate cleared; §9.12-A self-resume.                                                                                                                                                                                                                                                                                                                                                                      | [x]                                  |
| 9.12-A  | **Iteration-speed scaffolding compression + don't-give-up enforcement layer construction** per [`phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) §5.3 + §7. Compression: ROADMAP Phase 0-8 narrative archive (-800-1000 LOC); `continue/SKILL.md` compression (-300 LOC); archive closed phase gates / old audits / closed spikes. Enforcement (9 items): build-option DCE enforcement (`scripts/check_build_dce.sh` + `audit §K.1`); per-op file completeness (`dispatch_collector.zig` comptime check); skip-impl one-way ratchet (`scripts/check_skip_impl_ratchet.sh` + `skip_impl_history.yaml`); anti-fallback (`.claude/rules/no_fallback_on_failure.md` + grep script); spike lifecycle (rule + audit); chunk-close literal exit gate; Q3 C consistency audit (skill); progress tracker yaml; feature_level comptime verification. Reorganise + consolidate the existing 8 gates. Exit: cold-start load -40%; gate_commit average -20%; all 9 enforcements installed as pre-commit/pre-push hooks. | [x]                                  |
| 9.12-B  | **Q3 C adoption completion + build-option DCE extension across all layers** per [`phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) §5.3. Per-op file migration for all ops (remaining 4 Wasm 1.0 placeholders + Wasm 2.0 `multi_value.zig` + SIMD-128 relocate); central collector + dispatcher (`dispatch_collector.zig` + rewrite 5 dispatchers to inline switch + collector consumption); build-option DCE extension across all layers (CLI args declarative form / C API `comptime @export` filter + `wasm.h` preprocessor gate / WASI syscall feature_level metadata). Exit: `test-all` green for all 6 build-option combinations (`-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2}`); `check_build_dce.sh` 0; per-op file completeness comptime check passes. | [x]                                  |
| 9.12-C  | **Q5 hygiene landings** per [`phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) §5.3 + §3.5. `.claude/rules/comment_as_invariant.md` (new); extend `abi.zig` comptime disjointness check (convert table/memory emit scratch to named-constant arrays); D-133 sweep (route arm64 op_table/op_memory hardcoded X10/X11/X12 through named-constants); add stress axes section to `.claude/rules/edge_case_testing.md`; strengthen `audit §G` grep; strengthen `.claude/rules/bug_fix_survey.md` + inline `/continue` Step 4 checklist; new `.claude/rules/runtime_instance_layer.md` (Cat III code zone rule). **Dedup sweep**: in the same chunk, integrate existing `no_workaround.md` / `bug_fix_survey.md` / `audit_scaffolding §G` greps so they do not overlap or restate the new rules (per ADR-0071 §Q5 note + ADR-0072 Revision history). Exit: D-133 closed; comment_as_invariant rule auto-load functioning; audit grep detections 0; no rule-duplication remains. | [ ]                                  |
| 9.12-D  | **Q6 libc dependency boundary** per [`phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) §5.3 + §3.6. ADR-0070 Accepted (3 categories: necessary / replaceable / convenience); `.claude/rules/libc_boundary.md` auto-load; ROADMAP §14 amendment (forbid unconscious libc fanout); `scripts/check_libc_boundary.sh` + extend `audit §G.5`; sample migration `std.c.{write,_exit,getenv,munmap}` → `std.posix.*` (~5-10 sites). Exit: `bash scripts/check_libc_boundary.sh` 0; `test-all` green on all hosts. | [ ]                                  |
| 9.12-E  | **★ Wasm 2.0 complete 100% (skip-impl 243 → 0 + 4 comprehensive test suites green)** — primary Phase 9 completion exit per [`phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) §5.3 + §2.2. SKIP-CROSS-MODULE-IMPORTS 100 (imports/elem/data/linking/table*/memory*/global) discharge via relaxed `hasUnbindableImports()` reject condition + per-shape resolver; SKIP-NO-LINK-TYPECHECK 26 via `Instance.checkImportType()` + `applyAssertUnlinkable` callback; SKIP-VALIDATOR-GAP SIMD 50 (simd_lane lane-index range + simd_align alignment immediate range); exports non-invoke-action 1 (action dispatcher `get`/`set`); D-079 v128 cross-module imports (ii) via ADR-0052 §3 globals extension. Comprehensive tests: spec (skip-impl == 0) + edge_cases + realworld (Wasm 2.0 scope; emcc family deferred to Phase 11) + differential vs wasmtime. Exit: `spec_assert_runner_non_simd: N passed, 0 failed, 495 skipped (= 0 skip-impl + 495 skip-adr)` Mac+ubuntunote bit-identical; `simd_assert_runner: 13301 passed, 0 failed, 390 skipped (= 0 skip-impl + 390 skip-adr)` Mac+ubuntunote bit-identical; 4 testsuites green; ratchet 0 maintained. | [ ]                                  |
| 9.12-F  | **Phase-9-eligible debt cohort** per [`phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) §5.3. D-094 (x86_64 multi-result indirect-result-buffer; verify dissolution via D-140/D-148 chain or discharge); D-090 (lower.zig type-stack walker); D-062 (arm64 v128 9th+ stack overflow); D-141 (file_size_check WARN; mostly dissolved by Q3 C adoption, individual ADRs for the remainder); D-081 (emit.zig source split; verify dissolution by Q3 C); D-055 (emit_test_*.zig migration). Exit: debt active rows < 15. | [ ]                                  |
| 9.12-G  | **Phase 10 prep substrate** per [`phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) §5.3. ZirOp Wasm 3.0 slot ↔ Wasm spec number mapping table `.dev/wasm_3_0_zirop_mapping.md` (collector machine-generate); extend `src/instruction/wasm_3_0/` placeholders to cover all Phase 10 features (GC/EH/tail-call/memory64/multi-memory/typed func refs); `src/api/instance.zig` (1424 LOC) health + helper extraction + minimal c_api Instance-path test coverage (D-139 pulled forward); add CLI `--invoke` mode (prerequisite for Phase 11 bench); `include/wasm.h` upstream diff check; `zone_check.sh --gate` migration (info → enforce); new `.dev/architecture/zone_layout.md`. Exit: all Phase 10 feature ZirOps reject with `Error.UnsupportedOpForBuildLevel` at `comptime`; `zone_check --gate` 0; c_api basic path tests landed. | [ ]                                  |
| 9.12-H  | **Bench baseline (Mac-only Wasm 2.0 + wasmtime comparison)** per [`phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) §5.3. Extend `scripts/run_bench.sh --compare=wasmtime` + `--capture-rss`; on Mac aarch64 ReleaseSafe run 26 fixtures × hyperfine `--warmup 3 --runs 5`; add separate `runtime: zwasm` / `wasmtime` rows to `bench/results/history.yaml`; partial D-074 resolution (wazero/wasmer/bun/node + `-Dwith-bench-compare` flag deferred to Phase 11). Exit: "p9-close: Wasm-2.0 baseline (Mac aarch64)" row in history.yaml; zwasm vs wasmtime mean_ms ratio documented. | [ ]                                  |
| 9.12-I  | **ADR + lesson + private/ closure** per [`phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) §5.3. D-149 discharge (ADR Phase-9 cohort SHA backfill 75 → 0); ADR Status canonical pass (~22-25 entries from `Accepted` → `Closed (Phase X DONE)`); skip-ADR Status wording cleanup (skip_cross_module_register canonical, skip_cross_module_action close candidate); Lesson Citing backfill; scan for Lesson promotion candidates (decide ADR conversion for 3+ citations). Exit: `check_adr_history.sh --gate` 0; `check_lesson_citing.sh` 0; ADR `Accepted` count < 30. | [ ]                                  |
| 9.13-0  | **Cat IV — windowsmini reconcile sweep + cross-platform sweep (relocated from §9.9-IV per ADR-0049 + ADR-0056 + ADR-0065 2026-05-18 amends; scope expanded per [`phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) §5.3)**. Items: D-084 Win64 v128 marshal residual; D-136 Win64 SEH bridge for `assert_trap` recovery (likely small C/asm shim alongside Zig); D-028 windowsmini SSH test-runner IPC flake re-evaluate; any Windows-platform-specific issues surfacing from §9.9-III cross-module / host-import code OR §9.12 substrate audit cleanup. Sequence: inventory blocking items; pick implementation path per item; land in batch (single chunk if mechanical, multi-chunk if SEH bridge alone is substantial). Exit: windowsmini full `test-all` green including `spec_assert_runner_non_simd`, bit-identical with Mac + ubuntunote. windowsmini per-chunk gate stays deferred per ADR-0049 until this row opens. Sub-chunks recorded in `phase_log/phase9.md`. Runs autonomously by the `/continue` loop AFTER §9.12 substrate audit hard-gate clears (= §9.12 [x]); §9.13 Phase-10 entry hard-gate requires this row [x] for the 3-host invariant to hold.                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [ ]                                  |
| 9.13    | 🔒 Phase 10 entry gate review ([`.dev/phase10_transition_gate.md`](../phase10_transition_gate.md)) — collaborative review per Track D; runs **after** §9.13-0 windowsmini reconcile (which itself runs after the substrate audit 9.12 clears, since 9.12's outcome may amend Phase 10 scope AND windowsmini reconcile scope).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | [ ]                                  |

### Phase 10 — GC, EH, Tail call, memory64 (Wasm 3.0 completion) 🔒

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
- **SIMD per-op gap analysis vs (wasmtime, wazero, wasmer)** —
  carried over from §9.10 per Track A Option (3) (see
  `.dev/phase10_prep/track_a_9.10_scope.md` + ADR-0043 Revision
  history 2026-05-12 row): identify ops where v2 lags by > 3× the
  median of (wasmtime, wazero, wasmer) and file Phase 15 debt
  entries naming the candidate optimisation (AVX path adoption
  gated on CPUID, MOVAPS preamble peephole at op_simd binop
  sites, SIMD-specific coalescing). v1 reached "adequate for
  embedded" but explicitly accepted ~43× gap to wasmtime (D122);
  v2 inherits this gap as starting point and Phase 11's gap
  analysis produces the profile that drives Phase 15
  SIMD-specific work scope beyond v1 W43/W44/W45 porting. Folds
  into the D-074 bench-infra cohort (`-Dwith-bench-compare` build
  flag, wazero/wasmer in `flake.nix`, per-op SIMD micro-bench
  corpus, gap-analysis script) — single design pass.

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
ClojureWasm. **Per ADR-0043** (2026-05-12 Track A migration —
§9.10's gap-analysis carrier moved to Phase 11): Phase 15 SIMD
work absorbs (a) v1 W43/W44/W45 ports onto the v2 substrate as
documented below and (b) bench-driven SIMD-specific
optimisations surfaced by Phase 11's per-op gap analysis (AVX
path adoption gated on CPUID, MOVAPS preamble peephole at
op_simd binop sites, SIMD-specific coalescing — concrete
candidates filed as debt entries by Phase 11). The "v1 parity"
target is the floor, not the ceiling: exceeding v1's ~43× gap
to wasmtime (per v1 D122 self-assessment) is in scope where
Phase 11's gap profile + a feasibility-supported
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
❌ Runtime feature-flag branching (Wasmer / Cranelift-style toggle)
   in main code paths; `if (comptime build_options.<feature>)` and
   `inline for + continue` DCE idioms are permitted per ADR-0071 §Q2
   P14 sharpening + ADR-0073, but must follow the structural-cohesion
   caveat (prefer block / module-level over inline scatter; see
   ADR-0071 §"Structural cohesion caveat")
❌ Unconscious libc fanout (new `std.c.*` / `@extern("c")` /
   `pthread_*` call sites outside ADR-0070's `necessary` set without
   ADR amendment; see ADR-0070, rules/libc_boundary.md)
❌ Changes increasing skip-impl counts without an `exempt: <ADR-NNNN>`
   row in `bench/results/skip_impl_history.yaml` (see ADR-0050 D-5/D-6
   amend; the ratchet substrate gates pre-push)
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
  changes — defined narrowly as **scope or exit-criterion changes
  in §1, §2, §4, §5, §9 phase rows, §11 layers, §14 forbidden
  list**. "Load-bearing" means another file's behaviour, a
  phase's gate criterion, or what closes a §9 row changes
  because of the edit.
- Accumulating sub-chunk prose into a §9 row's description or
  status cell. The row text records *scope* (what closes the
  row) and the close-out marker (`[x]` / `[ ]` / SHA); per-sub-
  chunk records belong in **commit messages** and, if grouping
  by row helps cold-resume readers, in
  **`.dev/phase_log/<phase>.md`** referenced from the row. Rows
  that already accumulated log prose are migrated lazily as
  encountered. Canonical example: §9.9 row 9.7 + 9.9 →
  `phase_log/phase9.md` (extracted 2026-05-11; ROADMAP rows now
  carry just scope + pointer).
- Adding a "revision history" section back to this document — the
  trail is git log + ADRs.
- Editing principle text in §2 without an ADR (always load-bearing).
- "Quiet" renumbering of `§N` headings; if a renumber is unavoidable,
  it gets its own ADR and a sweep of every `§N.M` reference under
  `.claude/`, `.dev/`, and source comments.

### 18.3a What counts as routine (no ADR required)

These edits proceed without an ADR because they don't change any
load-bearing claim:

- `[ ]` → `[x]` flip on a row whose **scope text is unchanged**.
- Backfilling a SHA pointer on an `[x]` row.
- Advancing the Phase Status widget (`PENDING` → `IN-PROGRESS` →
  `DONE`).
- Inline-expanding the **next** phase's task table when its
  phase first opens (one-time per phase).
- Pointing a row at a `phase_log/<phase>.md` entry that already
  exists (migration of accumulated log prose into the phase log).

The trigger for "load-bearing per §18.3" is whether the edit
changes *what closes the row*, not whether the row is currently
open or closed.

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
