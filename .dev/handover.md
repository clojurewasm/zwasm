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
- **Last commit**: `4389a50` — feat(p7) §9.7 / 7.2 jit_arm64
  `inst.zig` (encoder, 13 ops + tests) + `abi.zig` (AAPCS64
  inventory + slotToReg). 521/521 unit / 3-host green. Earlier
  same cycle: 7.0 (`e273149`), 7.1 (`e7ad654`); D-006/D-023/D-024/
  D-025 discharged + bench v1-class baseline.
- **Branch**: `zwasm-from-scratch`, pushed.
- **Three-host parity**: Mac aarch64 + OrbStack Ubuntu + windowsmini
  all report identical test-all numbers (39/55 diff matched, 44/55
  realworld run, 1158 wast / 72 misc-runtime smoke / 5 wasmtime-misc
  runtime / 50 realworld parse / 9+3 spec / 2 wasi).

## Active task — §9.7 / 7.3 (`jit_arm64/emit.zig` ZIR→ARM64)

Per ROADMAP §9.7 / 7.3: `src/jit_arm64/emit.zig` — ZIR → ARM64
emit pass producing function bodies. Consumes:
- `jit/regalloc.compute()` for slot assignments per vreg.
- `jit_arm64/inst.enc*` for fixed-width u32 encodings.
- `jit_arm64/abi.slotToReg / isCallerSaved / isCalleeSaved` for
  per-arch wiring.

This row also dissolves D-014's barrier ("§9.7 / 7.3 emit pass
or earliest JIT row that touches Runtime"). The Runtime.io
injection-point design needs its decision here (or before).
Step 0.5 of the next /continue cycle should flip D-014 to `now`
and discharge alongside.

7.3 is also the row where Diagnostic M3 (interp trap location +
trace ringbuffer per ADR-0016) becomes more useful since JIT
trap surfacing inherits from interp's machinery — D-022 may
flip to `now` here too.

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
