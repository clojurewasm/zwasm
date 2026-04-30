# WebAssembly Proposal Phase Watch

> Reviewed quarterly. zwasm v2 implements all Phase 5 (= W3C
> Recommendation) proposals for v0.1.0; lower phases are watched and
> re-evaluated when they advance. Phase 4 non-web proposals are the
> v0.2.0 line.

Last reviewed: **2026-04-30**.

## Phase 5 — W3C Recommendation (zwasm v2 v0.1.0 MUST implement)

WebAssembly 3.0 (W3C Recommendation 2025-09):

| Proposal                                      | zwasm v2 phase | ZirOp prefix         |
|-----------------------------------------------|----------------|----------------------|
| MVP (i32/i64/f32/f64, control, memory)        | 1–2           | core                 |
| Multi-value (block params, multi-return)      | 1–2           | (sig-driven)         |
| Sign extension ops                            | 1–2           | core                 |
| Saturating float-to-int                       | 1–2           | core                 |
| Bulk memory                                   | 1–2           | core                 |
| Reference types                               | 1–2           | core                 |
| SIMD-128 (fixed-width)                        | 8              | `*x*.*` /  `v128.*`  |
| Memory64                                      | 9              | core (64-bit memarg) |
| Exception Handling (try-table, throw_ref)     | 9              | `eh_*`               |
| Tail Call (return_call, return_call_indirect) | 9              | `tail_*`             |
| WasmGC (struct/array/i31)                     | 9              | `gc_*`               |
| Function references                           | 9              | core                 |
| Extended const                                | 1–2           | (const-expr)         |
| Relaxed-SIMD                                  | 8              | `*.relaxed_*`        |

Plus v1 parity items at Phase 5:

- Wide arithmetic (i64x2 multiply, add-with-carry)
- Custom page sizes (memory.discard + memarg page-size variants)

## Phase 4 — Standardize (deferred to v0.2.0 for non-web items)

| Proposal                    | Status  | zwasm intent            |
|-----------------------------|---------|-------------------------|
| Threads (atomics, smem)     | Phase 4 | v0.2.0 (after WASI 0.2) |
| JS Promise Integration      | Phase 4 | **SKIP** (web-only)     |
| Web Content Security Policy | Phase 4 | **SKIP** (web-only)     |

## Phase 3 — Implementation (per-feature judgement)

| Proposal                         | Note                  | zwasm intent                    |
|----------------------------------|-----------------------|---------------------------------|
| ESM Integration                  | JS modules            | **SKIP**                        |
| Wide arithmetic (i64x2 mul, ADC) | BigInt-relevant       | Phase 8 alongside SIMD (v0.1.0) |
| Stack switching (continuations)  | Large; gates WASI 0.3 | v0.2.0+                         |
| Compact import section           | Size opt              | v0.2.0+                         |
| Custom page sizes                | memory tuning         | Phase 9 (v0.1.0)                |
| Custom Descriptors / JS Interop  | JS-only               | **SKIP**                        |

## Phase 2 — Proposed (watch only)

`Profiles`, `Relaxed Dead Code Validation`, `Numeric Values in WAT
Data Segments`, `Extended Name Section`, `Rounding Variants`,
`Compilation Hints`, `JS Primitive Builtins`. Re-evaluate quarterly.

## Phase 1 — Champion (watch only)

`Type Imports`, `Component Model` (v0.2.0 entry point),
`WebAssembly C and C++ API` (already adopted as ABI; ROADMAP §4.4),
`Flexible Vectors`, `Memory Control` (memory.discard), `Reference-
Typed Strings`, `Profiles` (Rossberg variant), `Shared-Everything
Threads`, `Frozen Values`, `Half Precision (FP16)`, `More Array
Constructors`, `JIT Interface` (interesting for self-JIT),
`Multibyte Array Access`, `Type Reflection` (likely demoted), `JS
Text Encoding Builtins` (skip).

## WASI roadmap

| WASI version   | zwasm phase   | Notes                                   |
|----------------|---------------|-----------------------------------------|
| 0.1 (preview1) | Phases 4 / 10 | de-facto baseline; complete in Phase 10 |
| 0.2 (preview2) | post-v0.1.0   | Component Model required                |
| 0.3            | post-v0.1.0   | async / streams; needs stack-switching  |

## Review log

- **2026-04-30** — initial table seeded from zwasm v1's
  `.dev/proposal-watch.md` and the pre-skeleton survey at
  `~/zwasm/private/v2-investigation/surveys/wasm-proposal-status.md`.
