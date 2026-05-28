# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `af477394` — fix(p10): cycle-51b fix-forward for
  D-180-class miss in x86_64 ref.as_non_null. Cycle-51 ubuntu kick
  FAILED (`expected Error.Trap, found 0` on Linux x86_64): my new
  bounds_fixups.append in ref_as_non_null.zig triggered the trap
  stub's R15 write, but R15 was uninit because the op wasn't in
  `usage.zig::usesRuntimePtr` whitelist. Added it → ubuntu re-kick
  GREEN at `af477394`. **ref.as_non_null JIT is now truly complete
  on both arches.** Lesson recorded:
  `.dev/lessons/2026-05-28-d180-detector-misses-bounds-fixups.md`.
- **D-193 FULLY DISCHARGED** (cycle 47, `eccab477`): all ~23
  Mac-aarch64-only test gates cleared over cycles 41-47; D-180-hazard
  coverage gap gone; 0 `skip.blocker(.@"D-193")` sites repo-wide.
- **Active debt rows**: 17 — all `blocked-by:` with named barriers.
  Zero `now`-status rows.

## Active bundle

- **Bundle-ID**: 10.R-function-references
- **Cycles-remaining**: ~2
- **Continuity-memo**: ADR-0123 (Proposed) — call_ref/return_call_ref
  gated on Accept. **ref.as_non_null JIT COMPLETE** (cycles 50-51:
  `86e5bfaf` handlers + dispatch + count tests at 350/397; `529e7b53`
  trap-on-null execution test in entry.zig passes Mac aarch64).
  Identity-passthrough liveness model confirmed working: ref.as_non_null
  pops src vreg, null-checks reg, pushes src back (no new vreg, no
  MOV); the next consumer reads from src's slot unchanged. The trap
  fires through bounds_fixups → generic trap stub → trap_flag=1 →
  Error.Trap. **NEXT chunk — br_on_null + br_on_non_null JIT emit**
  (other 2 ADR-independent null-ops). Same recipe family, but the
  CMP/null-check branches into a LABEL fixup (br_if machinery) instead
  of bounds_fixups (trap). Bundle them together — both have identical
  shape (null-check + conditional br). Survey first: read br_if's emit
  to understand label fixup machinery + how label-value passing
  works on the null-taken branch (br_on_null passes the label's
  values which sit BELOW the ref on the stack; br_on_non_null passes
  the ref itself as the branch value when non-null). After br_on_null
  family, the 3 ADR-independent null-ops are all JIT-emit-green; the
  bundle exit-condition (function-references spec return/trap fixtures
  run for the 3 ops) becomes the spec-runner wiring chunk (final pre-
  ADR-Accept cycle). call_ref/return_call_ref impl waits for ADR-0123
  Accept flip (still in open-questions).
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
