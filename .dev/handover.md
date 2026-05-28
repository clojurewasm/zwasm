# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `c786a2d8` — docs(p10): **ADR-0123** (10.R function-
  references typed-funcref representation, Proposed) (cycle 48).
  Docs-only — code unchanged from `89403a63` (already ubuntu-green
  `OK (HEAD=89403a63)`). **No ubuntu kick this cycle** (non-code-gap;
  Step 0.7 next cycle: c786a2d8 is docs-only, nothing new to verify).
- **D-193 FULLY DISCHARGED** (cycle 47, `eccab477`): all ~23
  Mac-aarch64-only test gates cleared over cycles 41-47; D-180-hazard
  coverage gap gone; 0 `skip.blocker(.@"D-193")` sites repo-wide.
- **Active debt rows**: 17 — all `blocked-by:` with named barriers.
  Zero `now`-status rows.

## Active bundle

- **Bundle-ID**: 10.R-function-references
- **Cycles-remaining**: ~5
- **Continuity-memo**: ADR-0123 (Proposed) decides the representation —
  sig type-index rides in `ZirInstr.payload` (mirrors call_indirect),
  type stack stays generic funcref, runtime sig-dispatch (null-trap +
  `IndirectCallTypeMismatch`), static typed-ref + nullability narrowing
  deferred to 10.G. **call_ref / return_call_ref impl is gated on
  ADR-0123 Accept** (user flip). The 3 null-manipulation ops
  (ref.as_non_null / br_on_null / br_on_non_null) are
  representation-independent (generic-ref null-check) and proceed NOW.
- **Exit-condition**: function-references spec return/trap fixtures run
  (not just invalid=12); the 5 ops execute under interp + JIT on both
  arches. (Autonomous portion: 3 null-ops JIT green; call_ref family
  after ADR Accept.)

## Active task — 10.R: JIT-emit the null-manipulation ops

Survey done (cycle 48): the 3 null-ops are parsed+validated+interpreted
(generic reftype) but **JIT-stubbed**; call_ref/return_call_ref are
parse-only (gated on ADR-0123). Per ADR-0123 D2 the null-ops are
representation-independent → unblocked.

**NEXT chunk** — JIT-emit `ref.as_non_null` (arm64 + x86_64). Smallest
red: a JIT-compiled function using ref.as_non_null currently hits the
unregistered-handler path (dispatch slot null per survey). Emit a
null-check: if the popped ref (`Value.ref` u64, null=0) is 0 → branch
to the trap stub (`NullReference`); else leave it in place (identity).
Register the emit handler in the dispatch table (likely via
`feature/function_references/register.zig`, currently an empty
placeholder — wiring it is part of this chunk). Then `br_on_null` +
`br_on_non_null` (null-conditional branch, reuse br_if fixup machinery)
as the following chunk. Mind the D-193 lesson: no arm64-pinned byte
asserts — test via execution or comptime per-arch.

## Trivial follow-up (2-min, opportunistic)

- `src/test_support/skip.zig` `Blocker.@"D-193"` enum variant is now
  unused (0 call sites). Remove it when next touching skip.zig — the
  pre-commit gate passed with it present, so not urgent.

## Larger §10 work (blocked / later)

- **10.M memory64** — spec passes; remaining = multi-memory
  (`memories: []MemoryInstance`) + clang_wasm64 realworld (D-179).
- **10.E EH** — blocked: exnref ValType (ADR §4 deviation) + runner
  cross-module register (D-188 / D-192).
- **10.G WasmGC op-corpus** — D-179-blocked (wabt 1.0.41+). Substrate
  landed end-to-end (parse + struct/array ops + β mark-sweep + roots).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (HEAD `96a17d5a`; gate-only cycles unchanged)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=31  trap=0   invalid=10  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(fail2) exception=4(fail4)
[function-references] invalid=12 (all pass)   <- return/trap fixtures not yet run (10.R target)
```

## Open questions / blockers

- ADR-0120 — Status: Proposed pending user flip to Accepted.
- ADR-0123 — Status: Proposed. Accept flip unblocks call_ref /
  return_call_ref impl (the 3 null-ops proceed without it). Low-risk
  decision (avoids ValType overhaul; defers typed-ref to 10.G).
- D-179 — wabt 1.0.41+ blocks GC corpus + clang_wasm64 realworld.
- D-188 / D-192 — EH blocked on exnref ValType + cross-module register.
- 10.P close gate — user touchpoint by construction.

## Key refs

- ADR-0122 (test skip categorization) — D-193 discharge complete.
- ADR-0115 / ADR-0116 (GC heap / roots+RTT+i31) — check for
  function-references typing coverage during 10.R survey.
- ADR-0076 (D1 gate / D2 single-push / D3 ubuntu kick).
- ROADMAP §10 rows 10.R / 10.TC; `.dev/phase_log/phase10.md`.
