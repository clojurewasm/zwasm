# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/debt.md` — discharge `Status: now` rows before the active
   task (`/continue` Step 0.5).
3. `.dev/lessons/INDEX.md` — keyword-grep for the active task's
   domain (`/continue` Step 0.4).
4. `.dev/decisions/0014_redesign_and_refactoring_before_phase7.md`
   — historical: §9.6 / 6.K block + Beta-vs-Alpha funcref
   rationale. Phase 7 builds on top of the Alpha pointer encoding.
5. `.dev/decisions/0011_phase6_reopen.md` — the original Phase 7
   pause (now lifted with Phase 6 close).

## Current state

- **Phase**: **Phase 7 IN-PROGRESS** — §9.7 / 7.0–7.2 closed; 7.3
  in multi-cycle build-out (i32+i64+f32+f64 numeric coverage +
  locals + control-flow-e1 done).
- **Last commit**: `82862e5` — feat(p7) §9.7 / 7.3 sub-f1
  (i32.load + i32.store + bounds-check trap stub; X28=vm_base
  / X27=mem_limit caller-supplied invariants). 650/650 unit /
  3-host green. Phase 6 close at `68843b0`.
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — §9.7 / 7.3 (`emit.zig` op coverage build-out)

Per ROADMAP §9.7 / 7.3 ("ZIR → ARM64 emit pass producing
function bodies"). Row remains `[ ]` until MVP op coverage
closes — exit gated by §9.7 / 7.4's spec test pass=fail=skip=0.

| Sub | Op group                                              | Status |
|-----|-------------------------------------------------------|--------|
| a   | prologue/epilogue + i32.const + end (skeleton)        | [x] `0463d69` |
| b1-5| i32 ALU + shifts + rotr/l + cmps + eqz + clz/ctz/popcnt | [x] `98554b4`〜`d33073f` |
| c   | locals (get/set/tee + frame slot allocation)          | [x] `5e89533` |
| d1-2| i64 const + ALU + shifts + cmps + eqz + clz/ctz/popcnt | [x] `d8ad4d6` + `a072df7` |
| d3-5| f32 + f64 const + ALU + cmps + unary + min/max + copysign | [x] `1ae712f`〜`1715fed` |
| e1  | control flow: block + loop + br + br_if (label stack) | [x] `0149028` |
| e2  | if / else / end (conditional branch + skip-else)      | [x] `06a7a65` |
| e3  | br_table (linear CMP/B.NE/B chain)                    | [x] `a9aef00` |
| f1  | i32.load + i32.store + bounds-check + trap stub        | [x] `82862e5` |
| f2  | i32 sub-byte load/store + i64/f32/f64 load/store      | [ ] **NEXT** |
| f3  | memory.size, memory.grow                               | [ ]    |
| g   | call / call_indirect + arg/return marshalling         | [ ]    |
| h   | numeric conversions (wrap/extend/trunc/convert/reinterpret) | [ ]   |

Numeric MVP op coverage (88 ops total): i32 25 + i64 25 + f32 19 + f64 19.
Plus 3 locals ops + end + 4 control-flow ops (block/loop/br/br_if).

## Open questions / blockers

- **D-014 (`Runtime.io` injection point design)**: barrier
  refined to "§9.7 / 7.3 emit pass first row touching Runtime".
  Currently 7.3 sub-a..e1 are pure code emit (no Runtime
  access). Sub-f (memory ops with bounds-check trap surface)
  is the first to need Runtime — D-014 dissolves there.
- **D-022 (Diagnostic M3 / trace ringbuffer)**: stays
  `blocked-by` until sub-f introduces trap surfaces.
- **D-026 (env-stub host-func wiring)**: 4 embenchen + 1
  externref-segment fixtures remain skip-ADR'd. The
  validator gap (D-006) is closed; what remains is the
  cross-module dispatch wiring for emcc-style env stubs
  (Phase 7.3 sub-g territory).

## Phase 6 close — archival snapshot

Phase 6 final tally (all in `git log`):
- 14 expanded rows in §9.6 task table (6.A〜6.J + 6.K.1〜6.K.8)
  all `[x]` with SHA pointers.
- 2 active skip-ADRs covering 5 deferred fixtures
  (embenchen + externref-segment).
- 14 active debt rows (all `blocked-by:` with named structural
  barriers); 12 of original 24 discharged this phase.
- 2 lessons recorded (Beta funcref rejection; auto-register
  spike regression).
- v1-class hyperfine baseline recorded as "Phase 6 close baseline"
  (26 fixtures: 9 shootout + 11 TinyGo + nbody + 5 cljw).
