# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `908414b2` — fix(p10): frontendValidate threads tags
  for EH module compile (10.E open). Cycle-1 slice of the
  10.E-EH-compile-runtime bundle closed; deeper EH path
  structurally blocked (file D-192 this cycle).
- **ROADMAP §10 progress**: 7/13 DONE, 4 IN-PROGRESS, 2 Pending.
- **Active debt rows**: 18 — all `blocked-by:` with named
  structural barriers. Zero `now`-status rows. (D-192 filed; bundle
  10.E-EH-compile-runtime pivots from "exit-condition unreachable"
  to debt-tracked.)

## Spec runner observable (HEAD `908414b2`)

```
[memory64           ] return=337 (pass=337 fail=0  ) trap=205 (pass=205 fail=0  ) invalid=83  (pass=83  fail=0) exception=0  skip=0
[tail-call          ] return=31  (pass=31  fail=0  ) trap=0   (pass=0   fail=0  ) invalid=10  (pass=10  fail=0) exception=0
[exception-handling ] return=34  (pass=0   fail=34 ) trap=2   (pass=0   fail=2  ) invalid=7   (pass=5   fail=2  ) exception=4 (pass=0 fail=4)
[gc                 ] (no corpus — D-179 wabt)
[function-references] return=0   (pass=0   fail=0  ) trap=0   (pass=0   fail=0  ) invalid=12  (pass=12  fail=0) exception=0
total: return pass=368 fail=34; trap pass=205 fail=2; invalid pass=110 fail=2; exception pass=0 fail=4
```

EH return/trap/exception all 0/N — root at try_table.1.wasm
compile (uses exnref ValType byte 0x69 + cross-module `test::e0`
tag imports). Both blockers structural; per D-192.

Recent commits this resume:
- `908414b2` fix — frontendValidate threads tags for EH (10.E open).
- `3b9026b7` chore — close D-191; retarget at 10.E.
- `755d33d2` fix — wast baker emits invoke action directives (D-191).
- `c09cc64f` chore — retarget at D-191.
- `bf0ac870` fix — memory.grow pages_max + void-result asserts (+19).

## Active task — bucket-3 prep next survey for next tractable single-cycle slice

The remaining 10.E EH return/trap/exception path is gated on
ADR-grade work (exnref ValType, runner registry) — multi-cycle
prep + ADR flips. ROADMAP §10 IN-PROGRESS rows that AREN'T
blocked at the moment:

- **10.M** memory64 — corpus FULLY GREEN (closed by D-191).
- **10.TC** tail-call — corpus FULLY GREEN (closed by D-187).
- **10.E** EH — gated per D-192.
- **10.R** typed-funcref — gated per D-186.

Phase 10 unblocked work is sparse. Next survey: scan
ROADMAP §10 task tables for chunks that don't have a `blocked-by`
debt row pointing at them; if all remaining work is gated, surface
bucket-3 stop.

## Next sub-chunk candidates (names only)

- **ROADMAP §10 task table audit** — scan for any `[ ]` row not
  covered by a current `blocked-by:` debt row.
- **10.G WasmGC** — large multi-cycle bundle (still on the
  schedule; needs D-179 wabt bump for corpus bake).
- **ADR work to unblock D-192**: file exnref ValType ADR
  (Wasm 3.0 §3.3.10 typed reference extension; affects
  `ir/zir.zig::ValType` + parser valtype switch + validator).

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- 10.G-4 (struct ops) — blocked-by GC heap impl.
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.
- D-186 — `return_call_ref` blocked-by 10.R-3/4/5.
- D-188 — 2 now (try_table.8 + try_table.10); blocked-by 10.E
  validator strictness.
- **D-192 (new)** — EH runtime path blocked-by exnref ValType +
  cross-module register support.

## Key refs

- ADR-0017, ADR-0026, ADR-0109, ADR-0111 (memory64 design),
  ADR-0112, ADR-0113 §A, ADR-0114 D1/D5/D6, ADR-0119, ADR-0120.
- ROADMAP §10, Phase log `.dev/phase_log/phase10.md` Row 10.T /
  10.TC / 10.E / 10.M.
- Lessons (recent): `.dev/lessons/INDEX.md` entries 2026-05-26
  (shared-facade-host-dispatched) + 2026-05-28 (5 EH lessons).
