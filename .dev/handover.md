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
  heap object + catch_all_ref / catch_ref dispatch arms. New
  `feature/exception_handling/exception.zig` with Exception
  struct; Value.fromExceptionRef / refAsExceptionPtr helpers;
  Runtime.pending_exception now `?*Exception` + per-throw
  live_exceptions tracker freed at deinit. throwOp allocates;
  findAndDispatchCatch's catch_all_ref pushes [exnref] and
  catch_ref pushes [payload..., exnref] when tag_idx matches.
  2 new mvp_tests. Detail: phase_log §10.E。
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

## Active task — 10.E-exnref-b throw_ref impl

`throw_ref` (0x0A) pops an exnref and re-raises the wrapped
Exception via the same unwinder. Pop exnref → resolve via
`Value.refAsExceptionPtr` → write to `rt.pending_exception` →
re-enter `findAndDispatchCatch` on current frame; on miss
propagate Trap.UncaughtException. Refs: mvp.zig:throwRefOp,
value.zig:refAsExceptionPtr, feature/exception_handling/
exception.zig:Exception.

**Next sub-chunk candidates (names only, NO predictions)**:
- 10.E-exnref-b — throw_ref interp impl (the active task)
- 10.E-N-3 — production Runtime.tag_param_counts wiring in
  compileWasm (currently only tests populate the slot)
- 10.G-3 — heap-top reftype detection extension
- 10.G-4 — struct ops (needs GC heap impl first)
- 10.M-5b — SIMD memarg memory64 (validator + lower + codegen)
- 10.TC-3 — regalloc terminator-class + codegen tail-call

## Open questions / blockers

なし。impl 着手可。

## Key refs

- **ROADMAP §10**: [`ROADMAP.md`](./ROADMAP.md) lines 1338+
- **Phase 10 design plan**: [`phase10_design_plan_ja.md`](./phase10_design_plan_ja.md)
- **Sub-chunk log**: [`phase_log/phase10.md`](./phase_log/phase10.md)
