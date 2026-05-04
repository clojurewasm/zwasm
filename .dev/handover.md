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
- **Last commit**: `e273149` — feat(p7) §9.7 / 7.0 `reg_class.zig`
  re-derived (b336e78 was reverted by ADR-0011). 490/490 unit
  tests / 3-host test-all green.
- **Branch**: `zwasm-from-scratch`, pushed.
- **Three-host parity**: Mac aarch64 + OrbStack Ubuntu + windowsmini
  all report identical test-all numbers (39/55 diff matched, 44/55
  realworld run, 1158 wast / 72 misc-runtime smoke / 5 wasmtime-misc
  runtime / 50 realworld parse / 9+3 spec / 2 wasi).

## Active task — §9.7 / 7.1 (`regalloc.zig` greedy-local)

Per ROADMAP §9.7 / 7.1: `src/jit/regalloc.zig` — greedy-local
allocator; `regalloc.verify(zir)` post-condition runs after every
alloc. Consumes 7.0's `RegClassInfo` + (later) per-arch register
inventories from 7.2.

This row was previously `[x] a6bf0e7` and reverted at the Phase 6
reopen per ADR-0011. Treat the reverted tree as design-space
reference, not copy-paste source.

Substrate now in place from 7.0:
- `zir.RegClass` has all 6 named variants (3 standard + 3 special-cache).
- `jit/reg_class.zig:info()` returns per-class invariants
  (width / spill alignment / is_special_cache).
- `comptime` length-match guards future variant drift.

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

- **D-006 (linking-errors / import-type validation gap)** carried
  into Phase 7+. The 9 fixtures currently pass for the wrong
  reason (manifest-discovery rejects before type-check would
  fire). The phase-7-or-later resolution path is documented in
  `.dev/debt.md` D-006 + `skip_embenchen_emcc_env_imports.md`
  "What v2 needs to fix this honestly" §.
- **D-014 (`Runtime.io` injection point design)** has its
  Phase-7-design-ADR barrier dissolving as Phase 7 begins. Step
  0.5 of the next /continue cycle should flip D-014 to `now`.
