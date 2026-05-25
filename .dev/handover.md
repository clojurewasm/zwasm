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
- **10.E-1 = SHIPPED** (`ffb56dd7`): tag section parse skeleton。
- **10.E-2 = SHIPPED** (`390856f8` + `cec18589`): decodeTags +
  TagEntry + sections.zig FILE-SIZE-EXEMPT marker。
- **10.G-2 = SHIPPED** (`d5810162`): needs_gc_heap parse-time
  predicate (byte-scan type section).
- **10.E-3a = SHIPPED** (`c2238c9a`): BlockKind.try_table enum
  entry + validator labelType arm。
- **10.E-3b = SHIPPED** (`da8880a9`): try_table opcode 0x1F +
  catch-vec skeleton。
- **10.E-4 = SHIPPED 2026-05-25** (`753aec8f`): throw / throw_ref
  opcodes (0x08 / 0x0A) — validator + interp Trap.UncaughtException
  emission。
- **10.E-5a = SHIPPED 2026-05-25** (`da1cec05`): EH catch
  metadata storage + lowerer wire-up. Detail: phase_log §10.E。
- **10.E-5b = SHIPPED 2026-05-25** (`d8a4aa43`): interp throw
  unwinder (catch_all). `Label.block_idx` added; throwOp walks
  current frame's label stack, looks up LandingPad by block_idx,
  dispatches via doBranch on first catch_all match. catch_ /
  catch_ref / catch_all_ref + cross-frame unwind deferred to
  10.E-5c (post Module.tags wiring at 10.E-N). 4 new mvp_tests.
  Detail: phase_log §10.E。
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

## Active task — 10.E-N Module.tags wiring

Bring `Module.tags` (decoded at 10.E-2 / `390856f8` + `cec18589`)
through to the validator + interp side so:

- Validator's `opThrow` pops the tag's params from the operand
  stack (currently a TODO — only reads tag_idx and discards).
- Interp `throwOp` can pop the same params and stash them so the
  `catch_` / `catch_ref` matching at unwind time can push them on
  the catch label's stack post-restore. Enables 10.E-5c
  (catch_ + catch_ref dispatch) which currently fall through to
  Trap.UncaughtException by design.
- Validator's `validateCatchVec` adds tag_idx range check
  (currently `0x00 / 0x01` arms read tag_idx and discard the
  range validation).

Refs: `src/parse/sections.zig:decodeTags / TagEntry`,
`src/validate/validator.zig:opThrow / validateCatchVec`,
`src/interp/mvp.zig:throwOp / findAndDispatchCatch`,
`src/runtime/trap.zig:UncaughtException`.

**Next sub-chunk candidates (names only, NO predictions)**:
- 10.E-N — Module.tags wiring (the active task above)
- 10.E-5c — catch_ / catch_ref dispatch (after 10.E-N)
- 10.E-5d — cross-frame throw unwind (caller's try_table)
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
