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
- **10.TC-1 = SHIPPED 2026-05-25** (`a83e095f`): return_call +
  return_call_indirect interp impl + tailReturn helper refactor
  (10.R-5 returnCallRef も同 helper 使うよう dedup)。lower 0x12/0x13、
  validator opReturnCall + opReturnCallIndirect (checkResultsMatchFnReturn
  helper)、interp mvp.zig 各ハンドラ。4 unit tests in trap_audit.zig。
- **Mac `zig build test-all`**: green (scope=unclear → test-all)。

## Phase 10 progress

ROADMAP §10 = 13-row task table。
- DONE (7/13): 10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.T / 10.D
- IN-PROGRESS:
  - 10.M (7/8 sub-chunks; spec-corpus + realworld + 5b deferred)
  - 10.R (5/5 ops shipped; parent close gated on 10.G typed reftype)
  - 10.TC (1/N sub-chunks; 3 interp tail-call ops done; codegen +
    cross-module + spec corpus + regalloc terminator-class 残)
- Pending: 10.E / 10.G / 10.P

## Active task — 10.TC tail-call continued

`phase10_design_plan_ja.md` tail-call section + ROADMAP §10 10.TC
row。

**10.TC sub-chunk progress**:

- 10.TC-1 [x] SHIPPED `a83e095f` (return_call + return_call_indirect
  interp + tailReturn dedup; return_call_ref refactored to use same
  helper)
- **10.TC-2 NEXT**: spec corpus wire-up — `scripts/import_proposal_corpus.sh`
  で tail-call spec testsuite (95 wast per row text) を
  `test/spec/wasm_3_0_proposals/tail_call/` 配下に import し、
  `spec_assert_runner_wasm_3_0.zig` から走らせて Mac + ubuntu で
  interp パス確認。codegen は次 sub-chunk なので interp-only でも
  spec assertions の大半は通る見込み。
- 10.TC-3+: regalloc terminator-class 拡張 (ADR-0113 §A) +
  `op_tail_call.zig` 新規 + `frame_teardown.zig` helper + codegen
  arm64/x86_64 経路 + `cross_module_tail_call.zig` (ADR-0066 thunk
  不再利用 per row text) + EH × TC cross fixture。複数 sub-chunk
  にわたる codegen heavy。

**Other Phase 10 candidates** (after 10.TC-2):
- 10.M-5b: SIMD memarg memory64
- 10.M-spec-corpus: memory64 spec testsuite
- 10.E EH: regalloc N-successor callsite + `feature/exception_handling/`
- 10.G GC: typed reftype catalogue (unlocks 10.R parent close)
- 10.P close

**ADR-0113 callsite_metadata refactor**: 10.M は memory64 で
bounds_fixups を **触らない** (ADR-0111 D6 ↔ orthogonal)。

## Open questions / blockers

なし。impl 着手可。

## Key refs

- **ROADMAP §10**: [`ROADMAP.md`](./ROADMAP.md) lines 1338+
- **Phase 10 design plan**: [`phase10_design_plan_ja.md`](./phase10_design_plan_ja.md)
- **Sub-chunk log**: [`phase_log/phase10.md`](./phase_log/phase10.md)
