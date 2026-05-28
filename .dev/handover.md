# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 105 (`6e58b534`) — element `ref.func` init-expr
  accepts concrete typed-funcref segment types (`(ref $sig)`, not just
  abstract funcref). **function-references ParseFailed 1 → 0 — ALL 15
  modules now compile**; return pass **12 → 24**. Bundle
  10.R-funcrefs-tail-2 exit-condition (ParseFailed=0) MET.
- Prior: 104 unreachable-polymorphism (`8304714d`); 103 typed-ref
  table/elem decode + bound (`d24ad2da`); 102 ref.func typed +
  bundle-1 close (`7b9218c2`); 101 ref.as_non_null 0xD4 (`c82e8124`);
  100 Gate 4 (`2fa216b9`).
- Mac aarch64 test + lint green (cycle 105). ubuntu x86_64 SSH gate:
  cycle-104 HEAD confirmed green; cycle-105 kick backgrounded —
  Step 0.7 next resume verifies.

## Active bundle

- **Bundle-ID**: 10.R-funcrefs-exec (follow-up; cycles 106+)
- **Cycles-remaining**: ~3
- **Continuity-memo**: bundle 10.R-funcrefs-tail-2 CLOSED cycle 105 —
  function-references ParseFailed 3→0 (all modules compile), return
  pass 7→24 (delta across cycles 100-105). NEXT surface: the **15
  function-references return fails** (24/39 pass) — modules that now
  compile but mis-execute. These are runtime/codegen gaps (call_ref
  dispatch + sig check, ref.func runtime value, br_on_null/non_null +
  ref.as_non_null runtime semantics, typed-table get/set). **Step 0
  each cycle**: probe which assert_return directives fail + why (the
  spec runner reports per-directive return pass/fail; add a probe to
  name the failing export + actual-vs-expected), then fix the
  highest-yield runtime op.
- **Exit-condition**: function-references return pass-rate ≥ 32/39
  (currently 24/39) — i.e. clear at least half the 15 remaining
  return fails via runtime/codegen fixes.

## Active task — cycle 106: probe + fix highest-yield function-references return fail

All 15 modules compile (ParseFailed=0); 15 assert_returns still fail
at execution. **Step 0 (probe)**: instrument the wasm-3.0-assert
runner (or a focused test) to print which function-references exports
fail assert_return + the actual-vs-expected values, to localize the
runtime gap (likely `call_ref` dispatch / sig-mismatch trap, or
`ref.func` producing a runtime funcref the table/call path mishandles).
Then fix the highest-yield runtime/codegen op with a focused red test
(prefer a `test/edge_cases/p10/funcrefs/` fixture or an interp/codegen
unit test). Smallest red test per the localized execution gap.

## Larger §10 work (later bundles)

- **10.E EH spec corpus (Gate 1 / D-192)** — try_table.1.wasm imports
  `test::e0` tag + `test::throw` func from try_table.0.wasm; runner
  registry needs tag + func cross-module binding. Gate 2 (exnref byte
  `0x69` standalone + `ValType.exnref` pub-const) folds in here.
- **10.G WasmGC** — corpus baked (568 directives) but impl=0%; ZIR ops
  + heap impl + subtype lattice. NOTE: `valTypeIsSubtypeFree`'s
  `(ref $concrete) <: func` rule assumes pre-GC (all concrete = func
  type); 10.G must refine once struct/array heads enter module_types.
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-105)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass) exception=4(fail4)
[function-references] return=39(pass=24 fail=15) trap=4(pass=4) invalid=18(pass) ParseFailed=0 (10→7→6→3→1→0)
[gc                 ] return=407(fail) trap=100(fail) invalid=60(pass=55 fail=5) malformed=1(pass)
[multi-memory       ] return=407(pass=371 fail=36) trap=238(pass=237 fail=1)
```

## Open questions / blockers

- ADR-0120 / ADR-0123: Accepted; impl autonomous. ADR-0123 D4
  (ref.func typed) landed cycle 102.
- D-192: cross-module register substrate. New bundle after
  10.R-funcrefs-tail-2 closes.
- D-186 (return_call_ref): discharge predicate met by ADR-0123 D4 +
  cycle-102 opRefFunc typed push.

## Key refs

- ADR-0120 (Accepted — EH payload), ADR-0123 (Accepted — typed-ref;
  D4 ref.func typed landed cycle 102).
- `.dev/lessons/2026-05-28-funcrefs-tail-error-classes.md` (gate
  inventory + cycle-101/102 re-probe maps).
- ROADMAP §10; `.dev/phase_log/phase10.md`.
