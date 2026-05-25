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
- **10.E-1..3b = SHIPPED** (`ffb56dd7` / `390856f8` `cec18589` /
  `c2238c9a` / `da8880a9`): tag-section parser + TagEntry +
  BlockKind.try_table + try_table opcode parse skeleton.
  Detail: phase_log §10.E。
- **10.E-4 = SHIPPED** (`753aec8f`): throw / throw_ref opcodes
  (validator + interp Trap.UncaughtException emission).
- **10.E-5a = SHIPPED** (`da1cec05`): EH catch metadata storage
  + lowerer wire-up. Detail: phase_log §10.E。
- **10.E-5b = SHIPPED** (`d8a4aa43`): interp throw unwinder
  (catch_all only). Detail: phase_log §10.E。
- **10.E-N-1 = SHIPPED 2026-05-26** (`aa60df61`): Module.tags
  wiring through validator. Detail: phase_log §10.E。
- **10.E-5c = SHIPPED 2026-05-26** (`3cbb12aa`): interp catch_
  dispatch (tag-equality + payload push); bundles 10.E-N-2
  Runtime.tag_param_counts. Detail: phase_log §10.E。
- **10.E-5d = SHIPPED 2026-05-26** (`82be1d75`): cross-frame
  throw unwind via Runtime.pending_exception slot + invoke()
  post-popFrame catch retry. Detail: phase_log §10.E。
- **10.E-exnref-a = SHIPPED 2026-05-26** (`49cf7157`): Exception
  heap object + catch_all_ref / catch_ref dispatch arms.
  Detail: phase_log §10.E。
- **10.E-exnref-b = SHIPPED 2026-05-26** (`e448356d`): throw_ref
  interp impl (re-raise via exnref). Detail: phase_log §10.E。
- **10.E-N-3 = SHIPPED 2026-05-26** (`d2f8e5c7`): production
  tag_param_counts wiring through `CompiledWasm`.
  Detail: phase_log §10.E。
- **10.G-3 = SHIPPED 2026-05-26** (`8bebcc76`): detectNeedsGcHeap
  extends parse-time predicate to scan heap-top reftype bytes
  (anyref / eqref / i31ref / exnref) across type / global /
  table / element / code sections. 7 new tests. Detail:
  phase_log §10.G。
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

## Active task — 10.M-5b SIMD memarg memory64

10.M-4b note deferred SIMD memarg parse/lower to 10.M-5b:
`validator_simd.zig::readSimdMemarg` + `lower_simd.zig::
emitMemargLane` still hardcode the 2-uleb shape. Extend both
to consume the Wasm 3.0 memarg encoding (align bit 6 signals
memidx LEB follows), mirroring the 10.M-3 scalar MemArgExtra
wiring. Refs: validator_simd.zig:readSimdMemarg,
lower_simd.zig:emitMemargLane, zir.MemArgExtra (already exists),
ADR-0111 D4.

**Next sub-chunk candidates (names only, NO predictions)**:
- 10.M-5b — SIMD memarg memory64 (the active task above)
- 10.TC-3 — regalloc terminator-class + codegen tail-call
- 10.E-codegen — ADR-0114 D3-D6 codegen-side EH (exception_table,
  FP-walk unwind, zwasm_throw trampoline, op_exception_handling)
- 10.E-N-4 — c_api instantiate → interp Runtime tag_param_counts
  wiring (only needed once Wasm-with-throw exercises the interp
  Runtime via c_api)
- 10.G-4 — struct ops (needs GC heap impl first)

## Open questions / blockers

なし。impl 着手可。

## Key refs

- **ROADMAP §10**: [`ROADMAP.md`](./ROADMAP.md) lines 1338+
- **Phase 10 design plan**: [`phase10_design_plan_ja.md`](./phase10_design_plan_ja.md)
- **Sub-chunk log**: [`phase_log/phase10.md`](./phase_log/phase10.md)
