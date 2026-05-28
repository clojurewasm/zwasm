# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: 10.M-D195b cycle 72 — bundle CLOSES. Cross-module
  invoke routing via `$M::field` lands. `load1` fully green
  (15/15 assert_returns pass). Spec runner
  `[multi-memory] return=330 (pass=324 fail=6) trap=220 (pass=220
  fail=0)`. Mac aarch64 test-all + lint green.
- **D-188 FULLY DISCHARGED** (cycle 61). **D-194 / D-195(c)**
  DISCHARGED earlier. Active debt rows: 16 — all `blocked-by:`;
  zero `now`.

## Active bundle

- None — 10.M-D195b-cross-module-register closed cycle 72.

## Active task — cycle 73: next autonomous chunk

Cycle 73 candidates (ordered by deferred-bundle alternative):

1. **D-195 sub-gap (b) extension** — cross-module FUNC imports
   (data0.3 / data0.5 still UnknownImport). Bundle 10.M-D195b
   covered memory imports only; func cross-imports would need
   Linker.defineFunc with cross-module routing (more involved
   than defineMemory; need to surface the exported func +
   thunk through the Linker entry). Smaller scope than the
   memory bundle (the substrate is already there per ADR-0066);
   1-2 cycles.
2. **10.E EH runtime path** — standalone EH return path
   (try_table.0 instantiate). Multi-cycle bundle.
3. **10.M completeness pass** — bake remaining ~5 multi-memory
   fixtures (imports0..4, linking0..3, simd_memory*). The
   register substrate landed cycle 70-72 should unblock most.
   1-2 cycles.

Cycle 73 picks (3) — high-yield, low-risk; the bundle close opens
up several previously-blocked fixtures.

## Larger §10 work (blocked / later)

- **10.M memory64 multi-memory** — substrate cycles 62-68; corpus
  65-72 expansion landed (22 manifests / 564 passing directives).
  Remaining work = ~5 fixtures gated on cross-module FUNC imports
  + 3 ParseFailed corrupted-upstream fixtures.
- **10.E EH** — validator side spec-correct (cycle 61); runtime EH
  dispatch + cross-module register (D-192) external-gated.
- **10.G WasmGC** — D-179-blocked (wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-72)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass=7 fail=0) exception=4(fail4)
[function-references] return=39(fail36) trap=4(fail4) invalid=18(pass=18 fail=0)
[multi-memory       ] return=330(pass=324 fail=6) trap=220(pass=220 fail=0)  <- +5 via $M:: routing (cycle 72)
                      invalid=2(pass=2) malformed=2(pass=2) skip=15
[wasm-3.0-assert    ] assert_return pass=692  assert_trap pass=425  assert_invalid pass=120 fail=0
```

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- ADR-0123 — Status: Proposed. Accept flip unblocks call_ref +
  return_call_ref impl + typed-ref parser (D-195 sub-gap a).
- D-179 — wabt 1.0.41+ blocks GC corpus + clang_wasm64 realworld.
- D-192 / D-195(b) — memory bundle done; func cross-imports
  remain (cycle 73+ candidate).
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0111 (memory64 + multi-memory design).
- ADR-0076 (D1 gate / D2 single-push / D3 ubuntu kick).
- `.dev/lessons/2026-05-29-gate-tail-vs-exit-code.md`.
- ROADMAP §10 row 10.M; `.dev/phase_log/phase10.md`.
