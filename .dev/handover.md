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
- **Last commit**: `81445a4` — feat(p7) §9.7 / 7.3 sub-h4
  (reinterpret bit-casts: 4 ops via FMOV W↔S / X↔D, encoders
  reused). Sub-h3 (trapping trunc with NaN/range checks) is the
  last remaining sub-h row before §9.7 / 7.3 closes and the 7.4
  spec gate fires. 708/708 unit / 3-host green. Phase 6 close at
  `68843b0`.
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
| f2  | sub-byte + i64/f32/f64 load/store (23 ops total)      | [x] `fb5da38` |
| f3  | memory.size + memory.grow (skeleton; grow returns -1) | [x] `129b93f` |
| g1  | call (no-arg skeleton + BL fixup list)                | [x] `3cf4b77` |
| g2  | call_indirect skeleton (X26=table_base; LDR-LSL3/BLR) | [x] `a49d4c2` |
| g3a | sig-table threading + result-type-aware capture        | [x] `7ac65d1` |
| g3b | AAPCS64 arg marshalling (X0..X7 + V0..V7)             | [x] `e25a9a5` |
| g3c | call_indirect bounds + sig checks (typeidx side-array) | [x] `b870a90` |
| h1  | integer width: wrap_i64 + extend_i32_s/u                | [x] `7a0c0ca` |
| h2  | int↔float convert (8 ops: f32/f64.convert_i32/i64.s/u + demote/promote) | [x] `b8dd126` |
| h5  | sat_trunc (Wasm 2.0; 8 ops via FCVTZS/U direct)         | [x] `e17254e` |
| h4  | reinterpret (4 ops: bit-cast via existing FMOV W↔S/X↔D) | [x] `81445a4` |
| h3  | trapping trunc (8 ops: NaN check + range bounds + FCVTZ) | [ ] **NEXT** |

Numeric MVP op coverage (88 ops total): i32 25 + i64 25 + f32 19 + f64 19.
Plus 3 locals ops + end + 4 control-flow ops (block/loop/br/br_if).

## Open questions / blockers

- **D-014 (`Runtime.io` injection point design)**: caller-supplied
  invariant set is now substantial (X24..X28 = typeidx_base,
  table_size, funcptr_base, mem_limit, vm_base). Phase 7 follow-up
  wires Runtime structurally; the JIT compile() shape is ready to
  receive it. D-014 has accumulated enough surface area that
  dissolving it lands as its own dedicated cycle (post-7.3 close).
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
