# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: 10.M cycle 69 — baked 11 more single-module multi-memory
  fixtures (no new substrate work). Spec runner shows
  `[multi-memory] manifests=22 module=38 return=330 (pass=309 fail=21)
  trap=220 (pass=220 fail=0) invalid=2 (pass=2) malformed=2 (pass=2)`
  — 533 passing directives. Mac aarch64 test-all + lint green.
- **D-188 FULLY DISCHARGED** (cycle 61). **D-194 / D-195(c)**
  DISCHARGED earlier. Active debt rows: 16 — all `blocked-by:`;
  zero `now`.

## Active bundle

- None. 10.M corpus expansion has saturated for single-module
  fixtures; remaining work is D-195(b) cross-module register (real
  bundle) OR pivot to D-188-sibling EH runtime path.

## Active task — cycle 70: next autonomous chunk

Cycle 70 candidates (ordered by deferred-bundle alternative):

1. **D-195(b) bundle open — cross-module `(register …)` runner
   registry** — ~3 cycle bundle. First cycle: bake-side
   `register` + module-id emission + manifest parser extension.
   Subsequent cycles: runner module_registry HashMap + custom
   import binding builder + invoke routing for `$module::field`.
   Closes ~10+ fixture instantiate-fails across multi-memory + EH
   + function-references corpora when complete.
2. **10.E EH standalone runtime path** — try_table.0 instantiate
   currently fails InstantiateFailed (post-validator-fix cycle 61);
   wire runtime EH dispatch. Multi-cycle bundle.
3. **Investigate `data0.{2,4,6}.wasm` ParseFailed** — wasm-tools
   itself fails on these; upstream bake quirk. Likely deferred to
   debt row + skipped in manifest.
4. **10.M completeness pass** — bake remaining ~10 multi-memory
   fixtures that use register (load1, imports0..4, linking0..3).
   Gated on (1).

Cycle 70 picks (1) — opens the D-195(b) bundle. First chunk =
bake-side register/module-id emission + manifest parser extension
(no runner behavior change yet).

## Larger §10 work (blocked / later)

- **10.M memory64 multi-memory** — substrate cycles 62-68 + corpus
  cycles 65-69 baked 22 manifests / 533 passing directives. Further
  expansion gated on D-195(b).
- **10.E EH** — validator side spec-correct (cycle 61); runtime EH
  dispatch + cross-module register (D-192) external-gated.
- **10.G WasmGC** — D-179-blocked (wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-69)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass=7 fail=0) exception=4(fail4)
[function-references] return=39(fail36) trap=4(fail4) invalid=18(pass=18 fail=0)
[multi-memory       ] return=330(pass=309 fail=21) trap=220(pass=220 fail=0)  <- +179r +196t (cycle 69)
                      invalid=2(pass=2) malformed=2(pass=2)
[wasm-3.0-assert    ] assert_return pass=677  assert_trap pass=425  assert_invalid pass=120 fail=0
```

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- ADR-0123 — Status: Proposed. Accept flip unblocks call_ref +
  return_call_ref impl + typed-ref parser (D-195 sub-gap a).
- D-179 — wabt 1.0.41+ blocks GC corpus + clang_wasm64 realworld.
- D-192 / D-195(b) — cross-module `(register …)` runner registry —
  cycle-70+ bundle target.
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0111 (memory64 + multi-memory design).
- ADR-0076 (D1 gate / D2 single-push / D3 ubuntu kick).
- `.dev/lessons/2026-05-29-gate-tail-vs-exit-code.md` — gate
  verification discipline.
- ROADMAP §10 row 10.M; `.dev/phase_log/phase10.md`.
