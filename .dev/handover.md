# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc197 (`544d4440`) — **PAUSED at user request** (clean stop). Reassessed
  the Phase-10-close path + implemented 10.P invariant **I2** (real spec-corpus
  feature-completeness check; was a stub-skip). **KEY: Phase 10 is formally
  CLOSE-ELIGIBLE** — `check_phase10_close_invariants.sh` = 16 PASS / 8 SKIP /
  0 FAIL. Spec corpus feature-complete (all 5 proposals green via interp). The
  8 SKIPs are deferred follow-ups (NOT close-blockers): cross fixtures, JIT
  regalloc 3-axis (EH/GC JIT codegen), realworld toolchains (clang proven cyc196;
  Dart/hoot gated), bench/widget close-cycle items.
- cyc196 (`086c2991`) first clang-realworld fixture (clang_smoke; pipeline proven).
  Realworld-clang findings: JIT can't run `return_call` (D-205); runI32Export
  doesn't instantiate; → non-trivial clang fixtures need harness work.
- cyc195 non-null-local definite-assignment → **test-all GREEN** (gate restored,
  bundle 10.Y closed). cyc194 restored wast-runner compile. cyc190-193: gc
  global-init / import subtyping / assert_unlinkable. gc residual: .17 (D-198)
  + 5 unlinkable (D-202). All Mac+ubuntu green through cyc195.
- Earlier arc: cyc177 iso-recursive canonicalEqual; cyc147-148 ADR-0125
  packed; cyc146 ADR-0016 M3 self-attribution; cyc130-140 i31/struct/array.
- Runner EXECUTES via interp; gc_heap + gc_type_infos + rt.datas all
  materialised at instantiate. Arrays use 8-byte uniform slots
  (type_info.slot_size); data-seg elements are NATURAL width.
- EH corpus FULLY GREEN 34/34 (ADR-0114 substrate cyc110-120; lesson
  `eh-cross-module-tag-substrate-scope` has the journey).
- Mac+ubuntu green through cyc190 (`OK` exit 0). 10.G-gc + 10.H-multimem
  CLOSED cyc188. Cross-module sharing substrate: D-199 memory + D-201 table/func.

## Resume target — cycle 198 (loop PAUSED by user at cyc197)

**Decision point (user-relevant)**: Phase 10 is formally CLOSE-ELIGIBLE (10.P
0 FAIL). The spec corpus is feature-complete via INTERP; the remaining ROADMAP-
scoped work is the **JIT codegen for the 3.0 features** (tail-call D-205 / EH /
GC — the 10.TC/E/G JIT halves) + realworld/cross fixtures + the 8 deferred 10.P
SKIPs. Two paths:
- **(a) Close Phase 10 now** — interp-feature-complete; defer JIT codegen +
  realworld/cross to Phase 11. This DEFERS the JIT halves out of 10.TC/E/G
  scope → needs a §18 ADR (§9 phase-scope change) + audit_scaffolding phase-
  boundary pass + the close ceremony (widget DONE, §10 SHA backfill, Phase 11
  open).
- **(b) Grind JIT codegen in-scope** — complete 10.TC/E/G JIT halves
  (multi-cycle each; start JIT tail-call D-205, the most self-contained,
  unblocks clang_musttail). In-scope autonomous default; no ADR.
**Autonomous default if resuming without user steer**: (b) — open a bundle for
JIT tail-call (D-205); Step-0 survey the engine/codegen tail-call dispatch
(where `return_call` → UnsupportedOp), regalloc terminator-class (ADR-0113 §A),
op_tail_call.zig. **Bar**: any chosen path keeps test-all GREEN, 0 panics.
Also queued (lighter): refresh the other stale 10.P SKIP rationales (I14/I21
reference resolved D-192/D-179).

## §10 close map (after this bundle)

Spec-corpus rows (10.G/10.M/10.E/10.TC/10.R) are mature but ROADMAP-`[ ]`;
formal close needs realworld/p10 + 10.P. Residual after the bundle:
- **realworld/p10** (skeleton): clang_wasm64 + clang_musttail AUTONOMOUS
  (clang✓), emscripten/dart/ocaml/hoot TOOL-GATED — next major chunk.
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
