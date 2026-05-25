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
- **10.E-1 = SHIPPED 2026-05-25** (`ffb56dd7`): tag section
  (id=13) parse skeleton。SectionId.tag enum + seen array bump +
  orderIndex extension (tag between memory(5) and global(6) per
  Wasm 3.0 EH §4.5)。3 new tests (accept empty, canonical order,
  out-of-order rejection)。Entry decoding + try_table opcode +
  throw / throw_ref + interp unwinder land in 10.E-N。
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

## Active task — 10.TC tail-call continued

`phase10_design_plan_ja.md` tail-call section + ROADMAP §10 10.TC
row。

**10.TC sub-chunk progress**:

- 10.TC-1 [x] SHIPPED `a83e095f` (return_call + return_call_indirect
  interp + tailReturn dedup)
- 10.TC-1b [x] SHIPPED `b7562e5c` (validator unit tests; 6 cases)
- **10.TC-2 (deferred to post-codegen)**: spec corpus full wire-up
  needs JIT codegen for return_call/_indirect/_ref — `runner.compileWasm`
  goes through codegen which doesn't yet have these op handlers。spec
  corpus は `test/spec/wasm-3.0-assert/tail-call/` に import 済みだが
  実行は codegen 後。**Adopt RunnerCallbacks 経由の interp-only spec
  runner is large** (spec_assert_runner_base ~4000 LOC + per-proposal
  ~2000 LOC specialization)。
- **10.TC-3 NEXT**: regalloc terminator-class 拡張 (ADR-0113 §A) +
  `op_tail_call.zig` codegen 着手。複数 sub-chunk にわたる codegen
  heavy。

**Phase 10 candidates** (parallelisable):
- **10.E-2 NEXT**: Tag-entry decoding into `Module.tags[]`
  (attribute byte + typeidx vec) + Module.tags field on
  Module struct + decoder unit tests. Foundation for try_table
  + throw / throw_ref which need to resolve tag references.
- 10.E-3: try_table opcode parse + validator skeleton
- 10.E-4: throw / throw_ref interp (frame unwinding)
- 10.G-2: Module.needs_gc_heap parse-time detector
- 10.G-3: struct ops (most-impactful next GC slice; needs heap)
- 10.M-5b: SIMD memarg memory64 (validator + lower + codegen)
- 10.TC-3: regalloc terminator-class + codegen tail-call

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
