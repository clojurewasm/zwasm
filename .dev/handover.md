# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `e7666598` — feat(p10): wire declared-funcrefs bitset
  into frontendValidate (10.R cycle 60). `frontendValidate` now
  builds the declared-funcrefs bitset (globals init exprs +
  element segments + func-kind exports) and threads it through
  `validateFunctionWithMemIdxAndTags` → opRefFunc rejects
  `ref.func N` when N is not declared. Manual export scan tolerant
  of Wasm 3.0 `tag = 4` extension. Mac aarch64 test-all + lint
  green. D-188 bisect: `accepted_count` 4 → 2 (try_table.8 +
  try_table.10 only).
- **D-195 sub-gap (c) DISCHARGED** cycle 60 (`e7666598`). Remaining
  D-195 sub-gaps: (a) ADR-0123-blocked typed-ref parser, (b)
  cross-module `(register …)` runner registry.
- **Spec runner observable** — `[function-references] invalid=18
  (pass=18 fail=0)`; total wasm-3.0-assert `assert_invalid pass=116
  fail=2` (only try_table.8 + try_table.10 fail, both under D-188's
  EH validator gap).
- **D-194 DISCHARGED** cycle 58. Active debt rows: 17 — all
  `blocked-by:` with named barriers; zero `now`-status rows.

## Active bundle

- **Bundle-ID**: 10.R-function-references
- **Cycles-remaining**: 0 (autonomous portion EXHAUSTED across
  cycles 58 / 59 / 60). 5/5 ADR-independent null-ops JIT-green on
  both arches; function-references corpus wired; declared-funcrefs
  validator gate active.
- **Exit-condition**: MET (autonomous portion). Remaining 10.R work
  is external-gated:
  - ADR-0123 Accept flip → typed-ref parser → 12 modules' compile +
    call_ref / return_call_ref JIT impl.
  - D-192 / D-195(b) runner registry → 2 modules' instantiate.

## Active task — cycle 61: next autonomous chunk

Bundle 10.R is closed. Cycle 61 picks the next autonomous-eligible
chunk; ordered candidates:

1. **D-188 sub-gap — EH validator per-clause result-type rule**:
   the 2 remaining invalid-accepted fixtures (try_table.8 +
   try_table.10) root at the same gap — a try_table block declared
   with void / wrong result-type doesn't reject when its
   catch_ref / catch_all_ref clause pushes (exnref) onto the
   block's stack. Tighten the validator. ADR-0114-scope (10.E
   spec); independent of ADR-0120 / 0123.
2. **10.M memory64 multi-memory** — `memories:
   []MemoryInstance` plumbing per ROADMAP §10 row 10.M. No
   external blocker.
3. **D-195 sub-gap (b)** — cross-module `(register …)` runner
   registry; sibling to D-192. Would unblock 2 EH + 1 ref_func
   instantiate-fail modules.

Cycle 61 picks (1) by default — completes the D-188 close (the
last 2 invalid-accepted fixtures) and adds an EH-validator
permanent improvement that compounds when later EH return/trap
fixtures land via D-192 discharge.

## Larger §10 work (blocked / later)

- **10.M memory64** — spec passes; remaining = multi-memory
  (`memories: []MemoryInstance`) + clang_wasm64 realworld (D-179).
- **10.E EH** — blocked: exnref ValType (ADR §4 deviation) + runner
  cross-module register (D-188 / D-192). D-188 EH validator
  strictness sub-gap is cycle-61 autonomous target.
- **10.G WasmGC op-corpus** — D-179-blocked (wabt 1.0.41+).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (post-cycle-60 declared-funcrefs fix)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(fail2) exception=4(fail4)
[function-references] return=39(fail36) trap=4(fail4) invalid=18(pass=18 fail=0) <- (b) discharged
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
- ROADMAP §10 rows 10.R / 10.TC / 10.E; `.dev/phase_log/phase10.md`.
