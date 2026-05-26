# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `908414b2` — fix(p10): frontendValidate threads tags
  for EH module compile (10.E open). try_table.0.wasm now compiles
  green; opens the 10.E bundle's compile path. Runtime dispatch is
  the multi-cycle scope.
- **ROADMAP §10 progress**: 7/13 DONE, 4 IN-PROGRESS, 2 Pending.
- **Active debt rows**: 17 — all `blocked-by:` with named
  structural barriers. Zero `now`-status rows.

## Active bundle

- **Bundle-ID**: 10.E-EH-compile-runtime
- **Cycles-remaining**: ~5 (estimate; spec runner EH 40 dirs all
  root here)
- **Continuity-memo**: try_table.0.wasm compiles (this cycle).
  Next steps: (1) try_table interp body — push exception_handler
  frame on entry, pop on end / branch out; (2) throw interp body —
  unwind operand stack + raise Trap.UncaughtException with
  tag_idx + payload; (3) interp dispatch loop catches
  Trap.UncaughtException, walks frame stack looking for matching
  handler, transfers control to landing pad; (4) extend
  invokeInstanceExpectException to convert returned-with-exception
  outcome.
- **Exit-condition**: wasm-3.0-assert/exception-handling/try_table
  manifest's first concrete assert_return (`simple-throw-catch
  args=1 -> i32:23`) passes in spec runner.

## Spec runner observable (HEAD `908414b2`)

```
[memory64           ] return=337 (pass=337 fail=0  ) trap=205 (pass=205 fail=0  ) invalid=83  (pass=83  fail=0) exception=0  skip=0
[tail-call          ] return=31  (pass=31  fail=0  ) trap=0   (pass=0   fail=0  ) invalid=10  (pass=10  fail=0) exception=0
[exception-handling ] return=34  (pass=0   fail=34 ) trap=2   (pass=0   fail=2  ) invalid=7   (pass=5   fail=2  ) exception=4 (pass=0 fail=4)
[gc                 ] (no corpus — D-179 wabt)
[function-references] return=0   (pass=0   fail=0  ) trap=0   (pass=0   fail=0  ) invalid=12  (pass=12  fail=0) exception=0
total: return pass=368 fail=34; trap pass=205 fail=2; invalid pass=110 fail=2; exception pass=0 fail=4
```

assert_invalid 110/2 (was 111/1) — try_table.8 newly false-accepted
alongside try_table.10; both share the catch_ref/catch_all_ref
typing gap, both close together when 10.E per-clause result-type
unification lands.

Recent commits this resume:
- `908414b2` fix — frontendValidate threads tags for EH (10.E open).
- `3b9026b7` chore — close D-191; retarget at 10.E.
- `755d33d2` fix — wast baker emits invoke action directives (D-191).
- `c09cc64f` chore — retarget at D-191.
- `bf0ac870` fix — memory.grow pages_max + void-result asserts (+19).

## Next sub-chunk candidates (names only)

- **10.E IT-1: try_table interp body** — push exception_handler
  frame; pop on end / branch out. First substrate step of the bundle.
- **10.E IT-2: throw interp body** — raise Trap.UncaughtException
  with tag_idx + payload tucked in Runtime.eh_payload_buf.
- **10.E IT-3: interp unwinder** — dispatch.run catch of
  UncaughtException; walk handler stack; transfer to landing pad.
- **D-188 final (try_table.8 + try_table.10)** — per-clause
  catch_ref result-type unification. Closes alongside 10.E
  validator strictness.
- **10.R-4 / 10.R-5 (call_ref / return_call_ref)** — blocked-by
  D-186 (typed-funcref Value shape ADR).
- **10.G WasmGC** — large multi-cycle bundle.
- **10.M-realworld** — toolchain-blocked (D-179 wabt 1.0.41+).

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- 10.G-4 (struct ops) — blocked-by GC heap impl.
- 10.M-realworld — toolchain-blocked (D-179).
- 10.P close gate — user touchpoint by construction.
- D-186 — `return_call_ref` blocked-by 10.R-3/4/5.
- D-188 — 2 now (try_table.8 + try_table.10); blocked-by 10.E
  validator strictness.

## Key refs

- ADR-0017, ADR-0026, ADR-0109, ADR-0111 (memory64 design),
  ADR-0112, ADR-0113 §A, ADR-0114 D1/D5/D6, ADR-0119, ADR-0120.
- ROADMAP §10, Phase log `.dev/phase_log/phase10.md` Row 10.T /
  10.TC / 10.E / 10.M.
- Lessons (recent): `.dev/lessons/INDEX.md` entries 2026-05-26
  (shared-facade-host-dispatched) + 2026-05-28 (5 EH lessons).
