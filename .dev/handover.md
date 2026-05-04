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

- **Phase**: **Phase 7 IN-PROGRESS** — Phase 6 closed at
  `68843b0` (3-host green; mandatory audit fired; widget flipped
  6=DONE / 7=IN-PROGRESS).
- **Last commit**: `d33073f` — feat(p7) §9.7 / 7.3 sub-b5
  (i32.popcnt via V-register SIMD). i32 MVP op coverage in
  emit.zig now substantively complete (25 ops). 566/566 unit /
  3-host green. Earlier this cycle: 7.3 sub-a/b1/b2/b3/b4;
  7.0/7.1/7.2; D-006 + bench v1-class baseline.
- **Branch**: `zwasm-from-scratch`, pushed.
- **Three-host parity**: Mac aarch64 + OrbStack Ubuntu + windowsmini
  all report identical test-all numbers (39/55 diff matched, 44/55
  realworld run, 1158 wast / 72 misc-runtime smoke / 5 wasmtime-misc
  runtime / 50 realworld parse / 9+3 spec / 2 wasi).

## Active task — §9.7 / 7.3 (`emit.zig` op coverage build-out)

Per ROADMAP §9.7 / 7.3 ("ZIR → ARM64 emit pass producing
function bodies"). Skeleton landed at `0463d69` (prologue +
epilogue + i32.const + end → returns 42 in X0 verified). Row
remains `[ ]` until MVP op coverage closes — exit gated by
§9.7 / 7.4's spec test pass=fail=skip=0. Sub-progression
(planned for subsequent cycles, not separate ROADMAP rows):

| Sub | Op group                                              | Status |
|-----|-------------------------------------------------------|--------|
| a   | prologue/epilogue + i32.const + end (skeleton)        | [x] `0463d69` |
| b1  | i32 binary ALU (add/sub/mul/and/or/xor) — W-variant   | [x] `98554b4` + `3e10901` |
| b2  | i32 shifts (shl/shr_s/shr_u) — W-variant              | [x] `3e10901` |
| b3  | i32 rotl/rotr + 10 cmp ops + eqz                      | [x] `a76c647` |
| b4  | i32 clz + ctz                                          | [x] `de7a76c` |
| b5  | i32 popcnt (V-register CNT/ADDV/UMOV/FMOV pattern)    | [x] `d33073f` |
| c   | local.get/set/tee + local frame slot allocation        | [ ] **NEXT** |
| d   | i64 + f32 + f64 const + ALU                           | [ ]    |
| e   | control flow (block/loop/if/else/end/br/br_if/br_table) | [ ]   |
| f   | memory load/store + bounds-check trap surface          | [ ]    |
| g   | call / call_indirect + arg/return marshalling          | [ ]    |

D-014 (Runtime.io injection point) stays `blocked-by` until
sub-f or sub-g — those are the first sub-rows that need trap
surface or host-call dispatch, both of which require Runtime
access. Sub-b (pure ALU) does not.

D-022 (Diagnostic M3 / trace ringbuffer) likewise stays
`blocked-by` until sub-f introduces trap surfaces.

## Phase 6 close — closing snapshot

Phase 6 final tally:
- 14 expanded rows in §9.6 task table (6.A〜6.J + 6.K.1〜6.K.8)
  all `[x]` with SHA pointers.
- 2 active skip-ADRs covering 5 deferred fixtures
  (`skip_embenchen_emcc_env_imports.md`,
  `skip_externref_segment.md`).
- 14 active debt rows (all `blocked-by:` with named structural
  barriers); 8 rows discharged this phase. `.dev/debt.md` is
  current.
- 2 lessons recorded
  (`2026-05-04-beta-funcref-encoding-rejected.md`,
  `2026-05-04-autoregister-spike-regression.md`).

## Open questions / blockers

(Phase 6 cleanliness sweep 2026-05-04 closed: D-006, D-023, D-024,
D-025. Plus D-001/2/3/4/5/8/13/15/19 from earlier cycles. 12 of
the original 24 audit-noted debts discharged this Phase 6 cycle.)

- **D-026 (env-stub host-func wiring)** is the new sharper
  successor to D-006's embenchen portion: 4 embenchen `_*1.wasm`
  + 1 externref-segment fixture remain skip-ADR'd. Validator
  gap (D-006) is closed; what remains is implementation-side
  cross-module dispatch for emcc-style env stubs.
- **D-014 (`Runtime.io` injection point design)**'s barrier
  was refined this cycle to "§9.7 / 7.3 emit pass (or earliest
  JIT row that touches Runtime)". Phase 7.0 + 7.1 don't touch
  Runtime; D-014 stays blocked-by until 7.3.
