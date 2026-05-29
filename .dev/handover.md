# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `04476dce` (cyc200, 10.TC-JIT IT-4). **Same-module JIT tail-call is
  PROVEN**: direct 0-arg (IT-2), indirect via table[0] (IT-3), and direct
  recursion-WITH-ARGS (IT-4, sum(5,0)=15 over 6 frame-reusing levels — the
  clang_musttail shape) all JIT-execute e2e via `runI32Export`. Root fix was
  the liveness terminator-class (`src/ir/analysis/liveness.zig`, ADR-0113 §A,
  IT-2); emit was already wired. **D-205's core predicate "implement JIT
  tail-call codegen" is met.** Mac test-all + ubuntu GREEN through IT-3; IT-4
  Mac test-all GREEN. Phase 10 CLOSE-ELIGIBLE (spec corpus interp-complete);
  path (b) completing the §10 JIT halves rather than deferring to Phase 11.
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
- **Step 0.7 on resume**: last ubuntu kick = cyc196 `OK (HEAD=517cb01a)`. cyc197
  (`544d4440` I2 script + `9996d478` handover) is DOCS/SCRIPT-only — not built by
  test-all — so the 517cb01a→9996d478 gap is a non-code-gap; ubuntu green holds,
  NO re-kick / revert needed. 10.G-gc + 10.H-multimem CLOSED cyc188.

## Active bundle

- **Bundle-ID**: 10.TC-JIT (D-205 discharge)
- **Cycles-remaining**: ~2 (IT-5 realworld result-check harness → IT-6 generate clang_musttail fixture)
- **Continuity-memo**: same-module tail-call codegen DONE + proven (direct 0-arg
  `ef34724c`, indirect `9a060476`, recursion-with-args `04476dce`). Remaining IN
  bundle = wire a realworld result-check harness so `clang_musttail` can be
  JIT-verified. Per cyc196 lesson: `runI32Export` can't do it (no full
  instantiation + no-arg-only → clang -O2 constant-folds), and `test-realworld-run`
  (`cli_run.runWasm`) fully instantiates but only checks instantiate+invoke
  (no result-check, globs `test/realworld/wasm/` not `p10/`). IT-5 = extend that
  harness: glob `p10/` + compare invoke result to a `.expect` file. clang→wasm
  recipe (cyc196 lesson): `PATH+=lld; NIX_HARDENING_ENABLE="" clang --target=wasm32
  -nostdlib -Wl,--no-entry -O2 -mtail-call`. OUT of bundle (separate debt):
  cross-module tail-call (`cross_module_tail_call.zig`, 10.TC-3f); `return_call_ref`
  (blocked-by `call_ref` JIT, 10.R).
- **Exit-condition**: `clang_musttail` realworld fixture JIT-result-checked via
  the new full-instantiate harness → bundle close; test-all GREEN, 0 panics.
  (same-module codegen — direct + indirect + recursion-with-args — already met.)

## Active task — 10.TC-JIT IT-5  **NEXT**

Extend the realworld run harness to result-check `p10/` fixtures: survey
`test/realworld/run_runner_jit.zig` (+ `cli_run.runWasm` / `test-realworld-run`
step), then add (a) globbing of `test/realworld/p10/**`, (b) per-fixture
`.expect` comparison (mirror the edge-case `.expect` format), and (c) generate
a non-folding `clang_musttail` `.wasm` (CPS/continuation shape per PROVENANCE.md
so clang -O2 can't const-fold the recursion). Confirm it JIT-runs the
`return_call` to the correct result. Lighter queued: refresh stale 10.P SKIP
rationales (I14/I21 reference resolved D-192/D-179).

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
