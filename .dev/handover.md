# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8 (ARCHIVED-IN-PLACE 2026-05-25; cite-only).
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24)。
- **10.D = CLOSED 2026-05-25**: 全 7 ADR (0111-0117) Accepted、
  impl rows unlocked。
- **10.M-1 = SHIPPED 2026-05-25** (`063e80e8`): parser+validator
  memory64 widening。
- **10.M-2 = SHIPPED** (`939b7bbe`): Runtime data shape (MemoryInstance +
  memories[] + setMemory0Bytes alias)。
- **10.M-3 = SHIPPED** (`f0809d0c`): MemArgExtra packed + bit-6 memidx decode。
- **10.M-4a = SHIPPED** (`60ec148f`): codegen memidx==0 invariant assert (D3 anchor)。
- **10.M-4b = SHIPPED 2026-05-25** (`d651d40b`): arm64 i64 idx_type wrap-check
  emit + `memory0_idx_type` plumbing (ADR-0111 D4)。`compileOne` / `compile`
  に 9th/12th param 追加、`engine/compile.zig` で memory section から idx_type
  抽出。arm64 `emitMemOpI64`: X-form addr load (`encOrrReg`) + 4-lane MOVZ+MOVK
  offset materialise。comptime + runtime 2-stage gate (`build_options.wasm_level
  >= .v3_0` AND `ctx.memory0_idx_type == .i64`)。i32 fast-path byte-identical
  (existing 9 emit_test_memory tests). 2 new tests for i64 path。
  x86_64 は signature 受理のみ (param discard); 本体は 10.M-4c。
- **Mac `zig build test`**: green (substrate baseline)。

## Phase 10 progress

ROADMAP §10 = 13-row task table。
- DONE (7/13): 10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.T / 10.D
- IN-PROGRESS: 10.M (sub-chunk 1/6 shipped)
- Pending: 10.R / 10.TC / 10.E / 10.G / 10.P

## Active task — 10.M memory64 impl

Per ADR-0111 (Accepted)。`phase10_design_plan_ja.md` §3.1 source-of-truth。

**Sub-chunk progress**:

- 10.M-1 [x] SHIPPED `063e80e8` (parser+validator widening)
- 10.M-2 [x] SHIPPED `939b7bbe` (Runtime.memories[] + setMemory0Bytes alias)
- 10.M-3 [x] SHIPPED `f0809d0c` (MemArgExtra packed + bit-6 memidx decode)
- 10.M-4a [x] SHIPPED `60ec148f` (codegen memidx==0 invariant assert; D4 anchor)
- 10.M-4b [x] SHIPPED `d651d40b` (arm64 i64 wrap-check + memory0_idx_type plumbing)
- **10.M-4c NEXT**: x86_64 i64 idx_type emit (R10 MOV imm64 4-lane analogue)。
  arm64/op_memory.zig::emitMemOpI64 と同じ comptime + runtime 2-stage gate
  shape を x86_64/op_memory.zig に。`emitMemOp(allocator, ..., op, offset, func_idx)`
  legacy signature が `ins` を受けないため、`emitI32Load` wrapper か `emitMemOp`
  自体に idx_type 引き渡しが必要 (1 引数追加で良い)。
- 10.M-4d (optional): `lower_simd.zig::emitMemargLane` の memidx 抽出
  (現在 align bit-6 を破棄中)。load_lane/store_lane の multi-memory 対応
  (parser-only; codegen は同様 deferred)。
- 10.M-5: spec corpus + edge_cases + `realworld/p10/clang_wasm64/` green。
- 10.M-close: `-Dwasm=v2_0` symbol-absence gate を `scripts/check_phase10_close_invariants.sh` に追加。
- 10.M-5: spec corpus + edge_cases + `realworld/p10/clang_wasm64/`
  green。
- 10.M-close: `-Dwasm=v2_0` symbol-absence gate を
  `scripts/check_phase10_close_invariants.sh` に追加 (ADR-0111
  Revision 補強)。

**ADR-0113 callsite_metadata refactor**: 10.M は memory64 で
bounds_fixups を **触らない** (ADR-0111 D6 ↔ orthogonal)。

## Open questions / blockers

なし。impl 着手可。

## Key refs

- **ROADMAP §10**: [`ROADMAP.md`](./ROADMAP.md) lines 1338+
- **Phase 10 design plan**: [`phase10_design_plan_ja.md`](./phase10_design_plan_ja.md) §3.1
- **ADR-0111** (Accepted): [`decisions/0111_memory64_design.md`](./decisions/0111_memory64_design.md)
- **10.M-1 survey**: `private/notes/p10-10M-1-survey.md`
- **Sub-chunk log**: [`phase_log/phase10.md`](./phase_log/phase10.md)
