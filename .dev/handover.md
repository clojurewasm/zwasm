# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8 (ARCHIVED-IN-PLACE 2026-05-25; cite-only).
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24)。
- **10.D = CLOSED 2026-05-25**: 全 7 ADR (0111-0117) Accepted、
  impl rows unlocked。
- **10.M-1 = SHIPPED 2026-05-25** (commit `063e80e8`): parser+validator
  memory64 widening。`MemoryEntry.idx_type` + u64 limits + Wasm 3.0
  §5.4.4 4-bit flag (`0x04`/`0x05` accepted under `wasm_level >= .v3_0`、
  `Error.Memory64Unsupported` otherwise)。`ImportPayload.memory` /
  `ImportShape.memory` cascade、`engine/compile.zig` per-idx_type page
  cap、spec_assert_runner ヘルパ widening (`@intCast` 仮 narrow @
  resetGrowableMemory)。Mac `test-all` GREEN / lint clean。
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
- **10.M-2 NEXT**: runtime refactor `memory: []u8 → memories: []MemoryInstance`
  (~80 call site cascade per ADR-0111 Consequences)。`Runtime.memory`
  + `Memory.grow` + `instantiate.zig` の単一 memory 仮定を外し、
  `MemoryInstance { bytes: []u8, idx_type, pages_min, pages_max }`
  に置き換える。`memories[0]` ショートカットを `memidx == 0` の
  ZirOp emit が読む。`current_mem_bytes` (spec runner) も u64
  widening。multi-memory > 1 reject (instantiate.zig:582) を
  `wasm_level >= .v3_0` で external lift。
- 10.M-3: `MemArg extra: packed struct(u32) { align_pow2: u5, memidx: u8, _: u19 }`
  per Wasm 3.0 §5.4.6 (parser + lowerer wire-up)。
- 10.M-4: codegen — arm64/x86_64 で i64 wrap-check + 64-bit offset
  materialise (X17 MOVZ+MOVK 4-lane / R10 MOV imm64)。**i32
  fast-path byte-identical** を `emit_test_memory.zig` で機械検証。
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
