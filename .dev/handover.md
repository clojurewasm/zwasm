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
  retire impl-driven `SKIP-P10-MEM64-GAP`; remaining gap is
  toolchain-side. New `SKIP-P10-MEM64-REALWORLD-TOOLCHAIN`.
- **10.G-smoke-doc = SHIPPED 2026-05-26** (`dd3dd7d4`):
  retire `gc/struct` from SMOKE; wabt 1.0.40 wast2json doesn't
  support GC proposal type syntax. Awaits wabt bump.
- **10.TC-3a = SHIPPED 2026-05-26** (`7447be67`): ADR-0113 §A
  3-axis foundation. `Axis3` struct + `axisOf` helper in
  dispatch_collector; arm64+x86_64 `ops/wasm_1_0/call.zig` declare
  `is_terminator=false / n_successor_edges=1 / is_safepoint=true`.
  Defaults match regular-call shape so non-migrated ops classify
  sanely. 4 unit tests. Detail: phase_log §10.TC.
- **10.TC-3b = SHIPPED 2026-05-26** (`cbc3d587`): tail-call per-op
  file skeletons. 6 new files (arm64 + x86_64 × return_call /
  return_call_indirect / return_call_ref) declaring
  `is_terminator=true / n_successor_edges=0 / is_safepoint=false`
  per ADR-0112 D2/D7. emit stubs return `UnsupportedOp` pending
  shared `op_tail_call.zig` + `frame_teardown.zig`. 6 axisOf
  comptime tests. Files NOT yet in `collected_arch_ops` (no
  on-branch spike per architectural_spike.md). Detail:
  phase_log §10.TC.
- **10.TC-3c = SHIPPED 2026-05-26** (`23ae7da2`): frame_teardown.zig
  shared helper (ADR-0112 D3). arm64 emits ADD SP + LDP
  X29,X30,[SP],#16; x86_64 emits ADD RSP + POP RBP. shared/
  facade dispatches by `builtin.target.cpu.arch`. 10 unit
  tests (4 arm64 + 6 x86_64 byte-snapshot + 2 facade smoke).
  Safepoint-free invariant (ADR-0112 D7) held by no-alloc /
  no-host-call / no-signal-check emit body. Consumed by
  10.TC-3d op_tail_call.zig. Detail: phase_log §10.TC.
- **10.TC-3d = SHIPPED 2026-05-26** (`176b00f5`): per-arch
  op_tail_call.zig — emitTailJump foundation (BR X16 / JMP R11).
  Step (5) of ADR-0112 D3/D4. 6 unit tests. Detail:
  phase_log §10.TC.
- **10.TC-3e = SHIPPED 2026-05-26** (`2b6242c5`): same-module
  callee_rt restore — arm64 MOV X0, X19 / x86_64 MOV RDI, R15.
  4 unit tests. Detail: phase_log §10.TC.
- **10.E-codegen-1 = SHIPPED 2026-05-26** (`34f81932`):
  shared/exception_table.zig storage. HandlerEntry +
  ExceptionTable.lookup + Builder. 7 unit tests.
- **10.E-codegen-2 = SHIPPED 2026-05-26** (`3b0000ad`):
  shared/unwind.zig FP-walk per ADR-0114 D5. 7 unit tests.
- **10.E-codegen-3a = SHIPPED 2026-05-26** (`de2f79fe`):
  arm64/frame_chain.zig — AAPCS64 frame-prefix read
  (`[X29, #0]` = saved FP, `[X29, #8]` = saved LR). Returns
  null for `fp == 0` (top-of-Wasm-stack sentinel). 4 unit
  tests with synthetic 2-slot frame arrays.
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

## Active task — 10.E-codegen-3b x86_64 frame_chain.zig

10.E-codegen-3a (`de2f79fe`) landed arm64 frame_chain.zig. Next:
mirror for x86_64 — `src/engine/codegen/x86_64/frame_chain.zig`
reading the SysV/Win64 frame prefix planted by the prologue's
`PUSH RBP; MOV RBP, RSP`:
  [RBP, #0] = caller's saved RBP
  [RBP, #8] = caller's saved RIP (return address)

Same `loadFrame(fp) → ?RawFrameLink` shape as arm64; same
`fp == 0` sentinel; same INVARIANT (no alloc / host-call /
signal-check). 4 unit tests with synthetic 2-slot frame arrays.

Refs: ADR-0114 D6/D5, System V AMD64 §3.2.2, arm64/frame_chain.zig
(landed) for the mirror shape.

**Next sub-chunk candidates (names only, NO predictions)**:
- 10.E-codegen-3b — x86_64 frame_chain.zig (active above)
- 10.E-codegen-3c — zwasm_throw assembly stub per arch
- 10.E-codegen-4 — per-arch op_exception_handling.zig
- 10.TC-3f/g/h — tail-call follow-ons (deferred)
- 10.E-N-4 — c_api instantiate → interp Runtime tag_param_counts
- 10.G-4 — struct ops (needs GC heap impl first)
- 10.M-realworld — clang_wasm64 realworld fixture

## Open questions / blockers

なし。impl 着手可。

## Key refs

- **ROADMAP §10**: [`ROADMAP.md`](./ROADMAP.md) lines 1338+
- **Phase 10 design plan**: [`phase10_design_plan_ja.md`](./phase10_design_plan_ja.md)
- **Sub-chunk log**: [`phase_log/phase10.md`](./phase_log/phase10.md)
