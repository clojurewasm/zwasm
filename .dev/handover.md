# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: 10.R cycle 59 close — function-references spec
  return/trap fixtures wired (`br_on_null`, `br_on_non_null`,
  `ref_as_non_null`, `ref_null`, `ref_is_null`, `ref_func` ×
  baked manifests + .wasm fixtures via
  `scripts/regen_spec_3_0_assert.sh`). Runner observable bumped
  from `manifests=1 invalid=12` to `manifests=7 module=15
  return=39 trap=4 invalid=18`. Per-module `compile/instantiate
  FAIL: <reason>` stderr emit added so silent skips no longer mask
  gaps. Mac aarch64 `zig build test` + lint green.
- **10.R bundle — autonomous portion COMPLETE** (2026-05-29):
  5 of 5 ADR-0123-independent null-ops JIT+tested on both arches
  (ref.as_non_null + br_on_null + br_on_non_null × {arm64,
  x86_64}) AND function-references corpus wired beyond the
  12-invalid baseline.
- **D-195 filed** covering the cycle-59 corpus pass-rate gap:
  (a) typed-ref ValType bytes `0x63` / `0x64` parser (ADR-0123-
  blocked; 12 modules ParseFailed); (b) cross-module `(register
  …)` runner gap (sibling to D-192; 2 modules); (c) `ref.func N`
  declared-funcref-set validator gap (ADR-independent; 2 invalid-
  accepted: ref_func.4 / ref_func.5). The D-188 bisect now pins
  `accepted_count == 4` (extended to ref_func.4 + ref_func.5).
- **D-194 DISCHARGED** cycle 58. Active debt rows: 17 — all
  `blocked-by:` with named barriers; zero `now`-status rows.

## Active bundle

- **Bundle-ID**: 10.R-function-references
- **Cycles-remaining**: 0 (autonomous portion exhausted)
- **Continuity-memo**: All ADR-0123-independent autonomous work
  done. Remaining 10.R work is **bucket-3-style external-gated**:
  ADR-0123 Accept flip unblocks (a) typed-ref parser + (b)
  call_ref / return_call_ref JIT impl, which together flip most
  of the `return=39 fail=36` and `trap=4 fail=4` counts.
- **Exit-condition**: MET (autonomous portion). Bundle closes
  with a pivot to either: cycle-60 = work the ADR-0123-independent
  sub-gap (c) of D-195 (ref.func declared-funcref-set validator),
  OR pick a different §10 row whose blockers are dissolved (see
  §"Next chunk" below).

## Next chunk — cycle 60 candidate set (autonomous-eligible)

Three concrete next-chunk candidates ordered by smallest red:

1. **D-195 sub-gap (c)** — `ref.func N` declared-funcref-set
   validator. Spec rule: `N` must appear in the elements section
   or `(elem declare ...)` clause; current validator accepts
   unrestricted `ref.func`. Smallest red: ref_func.4 / ref_func.5
   pinned by D-188 bisect at `accepted_count == 4`; tighten the
   validator → count drops to 2 (try_table.8 + try_table.10
   remain on D-188's EH gap). ADR-0123-independent.
2. **D-192 sub-gap — cross-module `(register …)` runner**:
   sibling to D-195 (b). Unblocks try_table.1 (EH) + ref_func.1
   (function-references). Spec runner needs a named-module
   registry keyed by the wast `(register "name")` directive.
3. **10.M memory64 multi-memory** — `memories:
   []MemoryInstance` plumbing per ROADMAP §10 row 10.M. No
   external blocker.

Cycle 60 picks (1) by default — smallest diff + best observable
delta (drops invalid-fail from 4 to 2).

## Larger §10 work (blocked / later)

- **10.M memory64** — spec passes; remaining = multi-memory
  (`memories: []MemoryInstance`) + clang_wasm64 realworld (D-179).
- **10.E EH** — blocked: exnref ValType (ADR §4 deviation) + runner
  cross-module register (D-188 / D-192).
- **10.G WasmGC op-corpus** — D-179-blocked (wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-59 corpus expansion)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(fail2) exception=4(fail4)
[function-references] return=39(fail36) trap=4(fail4) invalid=18(pass=16 fail=2)
                                                       ^^^^^^^^^^^^^^^^^^^^^^^^
                                                       cycle-59 expansion (was: invalid=12 pass=12)
```

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- ADR-0123 — Status: Proposed. Accept flip unblocks call_ref +
  return_call_ref impl + typed-ref parser (D-195 sub-gap a).
- D-179 — wabt 1.0.41+ blocks GC corpus + clang_wasm64 realworld.
- D-188 / D-192 — EH blocked on exnref ValType + cross-module register.
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0122 (test skip categorization) — D-193 discharge complete.
- ADR-0076 (D1 gate / D2 single-push / D3 ubuntu kick).
- ROADMAP §10 rows 10.R / 10.TC; `.dev/phase_log/phase10.md`.
