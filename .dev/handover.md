# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `a3ed7a73` (cyc208). **funcref-call + tail-call JIT comprehensively done
  both arches** — call_ref + return_call_ref (+ direct/indirect/recursion return_call,
  + clang musttail) all JIT-execute, AND call_ref/return_call_ref null-funcref traps
  verified (cyc208, D-207 discharged). x86_64 return_call_ref verified on ubuntu @
  `42f309ca`. **D-205 + D-207 discharged; D-206 residual = cross-module tail-call only
  (needs a multi-module JIT test harness — no current runI32Export multi-module path).**
  Mac test-all + lint GREEN.
- Earlier: 10.TC same-module tail-call (direct/indirect/recursion + clang musttail
  → 15, cyc198-201); EH corpus 34/34 (ADR-0114); cyc190-196 gc global-init/subtyping.
  Phase 10 CLOSE-ELIGIBLE (spec corpus interp-complete); Runner EXECUTES via interp,
  gc_heap materialised at instantiate. 10.M memory64 + 10.E EH JIT largely done;
  10.G GC JIT = interp-only (extreme: regalloc stack-map, ADR-0113 §C).
- **Step 0.7 on resume**: cyc208 (null-trap fixtures, test-only ungated) kicks ubuntu
  @ `a3ed7a73` — verify next cycle (null-trap tests run on x86_64 too). Prior: cyc207
  `OK (HEAD=42f309ca)` GREEN — **x86_64 return_call_ref confirmed on both hosts**.

## Active task — reassess 10.P close-invariant SKIPs after the JIT-codegen progress  **NEXT**

The funcref-call + tail-call JIT work (cyc198-208) likely flips/refreshes some of
the 8 deferred `check_phase10_close_invariants.sh` SKIPs (e.g. the "JIT regalloc
3-axis / JIT codegen" SKIP — tail-call + call_ref JIT now done; the I14/I21 SKIP
rationales reference now-RESOLVED debt D-192/D-179). Step-0: run
`bash scripts/check_phase10_close_invariants.sh` + read the SKIP rationales; update
those whose blocking condition is now resolved (flip SKIP→PASS where the invariant
now holds, OR refresh the rationale text to the current barrier). Bounded
docs/script cleanup that re-measures Phase-10-close readiness. Remaining substantive
JIT item (debt-rowed, NOT this cycle): cross-module tail-call (D-206, multi-module
JIT harness); GC JIT (10.G, extreme — regalloc stack-map).

## §10 close map

Spec-corpus rows (10.G/10.M/10.E/10.TC/10.R) are mature but ROADMAP-`[ ]`;
formal close needs realworld/p10 + 10.P. Residual:
- **realworld/p10**: clang_musttail DONE (cyc201, JIT result-checked); clang_wasm64
  next-AUTONOMOUS (clang✓); emscripten/dart/ocaml/hoot TOOL-GATED.
- **gc .17** funcref-RTT (D-198 multi-mechanism rabbit hole) — deep defer.
- **funcrefs** 34/39 — 5 gated; **10.P close gate** = user touchpoint.

## Spec runner observable (cyc190, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=349/407 trap=96/100 invalid=60/60 ✅ malformed=1/1 skip=20  ← cyc190 invalid-axis closed
[multi-memory       ] return=407/407 trap=244/244  ← cyc188 ALL-GREEN (D-199/200/201 cross-module chain)
```
> gc residual: return=1 + trap=4 = type-subtyping.30/.48/.50 (the bundle).
> Use `--fail-detail` (reliable per-assert), NOT the per-manifest breakdown.

## Open questions / blockers

- D-197: parse/validate/instantiate split DONE cyc127. Specific
  validate-error surfacing is ad-hoc via the cyc143 op-probe (lesson
  `gc-type-subtyping-is-rtt-blocked`); permanent diag emitter = D-197 tail.
- D-192: EH clause PROVEN (EH 34/34). funcrefs clause proven cyc108.

## Key refs

- ADR-0114 (EH `*TagInstance`, IMPLEMENTED cyc110–120); ADR-0115/0116/
  0121 (GC heap + type-info); ADR-0120/0123.
- `.dev/lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`
  (full EH journey) + `2026-05-29-zig-run-step-cache-stale-diag.md`.
- ROADMAP §10; `.dev/phase_log/phase10.md`.
