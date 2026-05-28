# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: 10.E cycle 79 — survey + first runtime fix:
  `sections.decodeExports` now recognises kind=4 (tag) and drops
  the export entry (keeps ExportDesc at 4 variants; tag refs go
  through the tag section directly). `try_table.0.wasm` now
  instantiates cleanly. Exception-handling corpus pass-rate
  unchanged because asserts target `try_table.1` which still
  ParseFails pending exnref ValType (D-192 / ADR-0120 Proposed).
- **D-188 / D-194 / D-195(c) DISCHARGED** earlier. **D-195(b)
  memory + func + spectest + globals + init-expr global.get
  WIRED** (cycles 71-78). Active debt rows: 17 — all
  `blocked-by:`; zero `now`.

## Active bundle

- None.

## Active task — cycle 80: next autonomous chunk

The cycle-79 EH survey identifies the next gap clearly: ALL EH
return/trap/exception assertions target `try_table.1.wasm` which
needs the `exnref` ValType (byte 0x69) at the parser layer.
That's ADR-0120 Proposed territory + an ADR-grade §4 ValType
deviation. Cycle 80 autonomous candidates:

1. **ADR-0120 user-flip prep — surface the gating** — the
   `try_table.1` ParseFailed is the last structural barrier
   to flipping `[exception-handling] return=0/34 → ~30/34`.
   ADR-0120 is Proposed; the user touchpoint is the Accept
   flip. Per `STOP_BUCKETS.md` bucket 3 (autonomous prep
   walked) → write the autonomous prep memo: ADR-0120 amendment
   refining the impl plan ahead of the Accept flip. Not a
   bucket-3 stop yet (other candidates exist).
2. **10.TC tail-call expansion** — `[tail-call] return=31 trap=0
   invalid=10` all pass. Bake more upstream tail-call fixtures
   (~95 in upstream corpus; we have 1 baked). Pure infra cycle.
3. **10.G WasmGC** — D-179-blocked.

Cycle 80 picks (2) — 10.TC fixture expansion. Pure infrastructure
chunk; surfaces any remaining tail-call substrate gaps.

## Larger §10 work (blocked / later)

- **10.E EH** — runtime EH dispatch + cross-module register
  (D-192) external-gated on ADR-0120 Accept (`exnref` ValType).
  Validator + codegen + tag-kind exports all wired; runtime
  unwind path is the next bundle once exnref lands.
- **10.M memory64 multi-memory** — autonomous substantially done.
- **10.G WasmGC** — D-179-blocked (wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-79; counts unchanged)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass=7 fail=0) exception=4(fail4)
[function-references] return=39(fail36) trap=4(fail4) invalid=18(pass=18 fail=0)
[multi-memory       ] return=407(pass=382 fail=25) trap=238(pass=237 fail=1)
                      invalid=2(pass=2) malformed=2(pass=2) skip=56
[wasm-3.0-assert    ] assert_return pass=750  assert_trap pass=442  assert_invalid pass=120 fail=0
```

(try_table.0 instantiate trace gone from stderr; numeric counts
unchanged because asserts target try_table.1 which still
ParseFails.)

## Open questions / blockers

- ADR-0120 — Status: Proposed; user Accept flip unblocks
  ~30 EH spec directives (the largest single yield available).
- ADR-0123 — Status: Proposed. Accept flip unblocks call_ref +
  return_call_ref impl + typed-ref parser (D-195 sub-gap a).
- D-179 — wabt 1.0.41+ blocks GC corpus + clang_wasm64 realworld.
- D-192 — EH cross-module register-as form; subsumed by ADR-0120
  + exnref ValType bundle.
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0114 (EH design).
- ADR-0120 (10.E-payload-prop — Proposed).
- ADR-0076 (D1 gate / D2 single-push / D3 ubuntu kick).
- `.dev/lessons/2026-05-29-gate-tail-vs-exit-code.md`.
- ROADMAP §10 row 10.E / 10.TC; `.dev/phase_log/phase10.md`.
