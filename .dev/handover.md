# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: 10.M-D195b cycle 75 — spectest.print* funcs +
  per-memidx memory exports. `[multi-memory] return=407 (pass=382
  fail=25) trap=238 (pass=237 fail=1)`. Mac aarch64 test-all + lint
  green.
- **D-188 FULLY DISCHARGED** (cycle 61). **D-194 / D-195(c)**
  DISCHARGED earlier. **D-195(b) memory + func + spectest stubs
  WIRED** (cycles 71-75). Active debt rows: 16 — all `blocked-by:`;
  zero `now`.

## Active bundle

- None.

## Active task — cycle 76: next autonomous chunk

Remaining ~25 multi-memory return fails trace to:
- spectest.global_i32 / table imports (need defineGlobal/defineTable
  on the Linker — D-178 territory; ~6 fixtures)
- linking1/linking2 cross-module register-by-name (complex; ~5
  fixtures)
- corrupted upstream fixtures (data0.{2,4,6}, imports1.0, imports2.3/4)

Cycle 76 candidates:

1. **Investigate remaining UnknownImports** — `wasm-tools print` the
   failing fixtures' imports + count by name (e.g., spectest.global_i32
   vs spectest.table). Decide which substrate piece unblocks the most.
2. **10.E EH runtime path** — try_table.0 instantiate. Pivot away
   from 10.M; multi-cycle bundle.
3. **`Linker.defineGlobal`** — minimal API extension for
   spectest.global_i32 (D-178 partial discharge). 1 cycle.
4. **Bake remaining 10.G or 10.E spec fixtures** — both gated on
   ADR-0123 / D-179.

Cycle 76 picks (1) — diagnostic survey to inform next bundle. The
remaining fails are heterogeneous; sorting them clarifies highest
yield.

## Larger §10 work (blocked / later)

- **10.M memory64 multi-memory** — 37 manifests / 619 passing
  directives. Remaining work clusters at spectest globals/tables
  + cross-module register-by-name + corrupted-upstream fixtures.
- **10.E EH** — validator spec-correct (cycle 61); runtime EH
  dispatch + cross-module register (D-192) external-gated.
- **10.G WasmGC** — D-179-blocked (wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-75)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass=7 fail=0) exception=4(fail4)
[function-references] return=39(fail36) trap=4(fail4) invalid=18(pass=18 fail=0)
[multi-memory       ] return=407(pass=382 fail=25) trap=238(pass=237 fail=1)  <- +14r +1t (cycle 75)
                      invalid=2(pass=2) malformed=2(pass=2) skip=56
[wasm-3.0-assert    ] assert_return pass=750  assert_trap pass=442  assert_invalid pass=120 fail=0
```

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- ADR-0123 — Status: Proposed. Accept flip unblocks call_ref +
  return_call_ref impl + typed-ref parser (D-195 sub-gap a).
- D-179 — wabt 1.0.41+ blocks GC corpus + clang_wasm64 realworld.
- D-178 — Linker.defineGlobal / defineTable missing. Blocks
  spectest globals/table pre-register (cycle 76+).
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0111 (memory64 + multi-memory design).
- ADR-0076 (D1 gate / D2 single-push / D3 ubuntu kick).
- `.dev/lessons/2026-05-29-gate-tail-vs-exit-code.md`.
- ROADMAP §10 row 10.M; `.dev/phase_log/phase10.md`.
