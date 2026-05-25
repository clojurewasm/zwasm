# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8 (ARCHIVED-IN-PLACE 2026-05-25; cite-only).
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24)。
- **10.D = CLOSED 2026-05-25**: 全 7 ADR (0111-0117) Accepted、
  impl rows unlocked。
- **10.M sub-chunks 1..fixture-2 = SHIPPED**: memory64 impl
  (parser/validator widening + Runtime.memories[] + MemArgExtra +
  codegen wrap-checks + v2_0 gate + edge_cases fixtures)。
- **10.R sub-chunks 1..5 = SHIPPED**: ref.as_non_null /
  br_on_null / br_on_non_null / call_ref / return_call_ref。
  parent row `[ ]` 留め — `(ref $sig)` typed reftype precision
  が 10.G で typed catalogue 拡張時に validator を引き締めるまで
  scope 不完全。
- **10.TC-1 = SHIPPED** (`a83e095f`): return_call + return_call_indirect
  interp impl + tailReturn helper。
- **10.TC-1b = SHIPPED** (`b7562e5c`): validator unit test
  coverage (6 tests)。
- **10.G-i31-helpers = SHIPPED** (`e79bb7a1`): pack/unpack helpers
  under `feature/gc/i31.zig`。
- **10.G-i31-ops = SHIPPED** (`52a6c225`): 3 i31 ops interp impl
  + Value helpers + 0xFB GC prefix dispatcher。
- **10.G-2 = SHIPPED** (`d5810162`): needs_gc_heap parse-time
  predicate.
- **10.E interp-side = COMPLETE 2026-05-26** (10.E-1..3b /
  10.E-4 / 10.E-5a..d / 10.E-N-1..3 / 10.E-exnref-a..b; last
  SHA `d2f8e5c7`): tag-section parser → throw/throw_ref →
  try_table catch metadata + all 4 catch flavors dispatch +
  cross-frame unwind + exnref + production tag_param_counts.
  Detail: phase_log §10.E (15 entries).
- **10.G-3 = SHIPPED 2026-05-26** (`8bebcc76`): detectNeedsGcHeap
  scans heap-top reftype bytes across sections. Detail:
  phase_log §10.G。
- **10.M-5b = SHIPPED 2026-05-26** (`37771003`): SIMD lane-memarg
  bit-6 memidx decode. Detail: phase_log §10.M。
- **10.M-spec-corpus = SHIPPED 2026-05-26** (`3d6aba35`): bake 5
  additional memory64 wast manifests. Detail: phase_log §10.M。
- **10.M-realworld-doc = SHIPPED 2026-05-26** (`5327f5ff`):
  retire impl-driven `SKIP-P10-MEM64-GAP` from clang_wasm64
  PROVENANCE; remaining gap is toolchain-side (needs emcc
  -sMEMORY64=1). New token `SKIP-P10-MEM64-REALWORLD-TOOLCHAIN`.
- **Mac `zig build test-all`**: green (scope=unclear)。

## Phase 10 progress

ROADMAP §10 = 13-row task table。
- DONE (7/13): 10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.T / 10.D
- IN-PROGRESS:
  - 10.M (7/8 sub-chunks; spec-corpus + realworld + 5b deferred)
  - 10.R (5/5 ops shipped; parent close gated on 10.G typed reftype)
  - 10.TC (1/N sub-chunks; 3 interp tail-call ops done; codegen +
    cross-module + spec corpus + regalloc terminator-class 残)
- Pending: 10.E / 10.G / 10.P

## Active task — 10.TC-3 codegen tail-call (regalloc terminator)

memory64 spec corpus expansion (10.M-spec-corpus) shipped this
cycle. EH + memory64 + GC parse-time predicate are at a clean
stopping point. Pivot back to Tail Call codegen — ADR-0113 §A
regalloc terminator-class extension + per-arch
`op_tail_call.zig` codegen. Architectural-grade work; expect
multi-cycle spike-first per `.claude/rules/architectural_spike.md`.
Refs: ADR-0112, ADR-0113 §A, `src/engine/codegen/{arm64,x86_64}/`.

**Next sub-chunk candidates (names only, NO predictions)**:
- 10.TC-3 — regalloc terminator-class + codegen tail-call
  (the active task above)
- 10.E-codegen — ADR-0114 D3-D6 codegen-side EH (exception_table,
  FP-walk unwind, zwasm_throw trampoline, op_exception_handling)
- 10.E-N-4 — c_api instantiate → interp Runtime tag_param_counts
  wiring (only needed once Wasm-with-throw exercises the interp
  Runtime via c_api)
- 10.G-4 — struct ops (needs GC heap impl first)
- 10.M-realworld — clang_wasm64 realworld fixture

## Open questions / blockers

なし。impl 着手可。

## Key refs

- **ROADMAP §10**: [`ROADMAP.md`](./ROADMAP.md) lines 1338+
- **Phase 10 design plan**: [`phase10_design_plan_ja.md`](./phase10_design_plan_ja.md)
- **Sub-chunk log**: [`phase_log/phase10.md`](./phase_log/phase10.md)
