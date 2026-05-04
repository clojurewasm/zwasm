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
- **Last commit**: `e7ad654` — feat(p7) §9.7 / 7.1 `regalloc.zig`
  greedy-local + verify post-condition re-derived. 499/499 unit
  tests / 3-host test-all green.
- **Branch**: `zwasm-from-scratch`, pushed.
- **Three-host parity**: Mac aarch64 + OrbStack Ubuntu + windowsmini
  all report identical test-all numbers (39/55 diff matched, 44/55
  realworld run, 1158 wast / 72 misc-runtime smoke / 5 wasmtime-misc
  runtime / 50 realworld parse / 9+3 spec / 2 wasi).

## Active task — §9.7 / 7.2 (`jit_arm64/{inst,abi}.zig`)

Per ROADMAP §9.7 / 7.2: `src/jit_arm64/{inst,abi}.zig` — ARM64
instruction encoder + AAPCS64 calling convention layout. Wires
the per-arch physical register inventory that maps `RegClass` →
specific X / D / V registers.

This row was previously `[x] 3c89984` and reverted at the Phase 6
reopen per ADR-0011. Treat the reverted tree as design-space
reference, not copy-paste source.

Substrate now in place from 7.0 + 7.1:
- `zir.RegClass` (6 named variants).
- `jit/reg_class.zig:info()` (per-class invariants).
- `jit/regalloc.zig:compute() / verify()` (slot-only allocator;
  per-class refinement hooks here at 7.2).

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
