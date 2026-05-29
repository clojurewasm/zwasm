# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc189 (consolidation, no src) — reassessed §10 state. Spec
  corpus mature: multi-mem 407 / memory64 337 / tail-call 71 / EH 34 all-
  green; gc 349/96/57. Remaining spec residuals: **3 gc invalid** (.10/.15/
  .16 global-init type-check, MISSING additive check — bounded, observable),
  gc .17 funcref-RTT (D-198 rabbit hole), cross-module sig (uncounted).
  §10 ROW close criteria also need **realworld/p10 fixtures** (skeleton):
  clang_wasm64 + clang_musttail autonomous (clang✓), emscripten/dart/
  ocaml/hoot tool-gated (emcc/dart✗). cyc188: multi-mem ALL-GREEN.
- Earlier arc: cyc177 iso-recursive canonicalEqual; cyc147-148 ADR-0125
  packed; cyc146 ADR-0016 M3 self-attribution; cyc130-140 i31/struct/array.
- Runner EXECUTES via interp; gc_heap + gc_type_infos + rt.datas all
  materialised at instantiate. Arrays use 8-byte uniform slots
  (type_info.slot_size); data-seg elements are NATURAL width.
- **Bundle 10.E-eh-tail CLOSED** cyc120 (`5db875b0`) — EH corpus FULLY
  GREEN 34/34 (cross-module propagation + caller-frame catch; ADR-0114
  full substrate cyc110–120; D-192 EH clause PROVEN). Lesson
  `eh-cross-module-tag-substrate-scope` has the journey.
- Mac+ubuntu green through cyc188 (`OK (HEAD=e7454fbf)`). No active bundle:
  10.G-gc + 10.H-multimem both CLOSED cyc188. Cross-module sharing substrate:
  D-199 memory + D-201 table/func.

## Active task — cycle 190: gc global-init type-check (3 invalid → 60/60) — **NEXT**

cyc189 DIAGNOSED (Explore): gc `type-subtyping.10/.15/.16` are invalid-
accepted because there is **NO `validateGlobals` at all** — global init-
exprs get only `init_expr.scanInitExpr` (structural), never a result-type-
vs-declared-type check. e.g. .10 `(global (ref 4) ref.func 0)`, func 0 is
type 6 (`sub 2`); type 2 ≢ type 0 (rec-group-distinct) ⇒ `(ref 6) <: (ref 4)`
false ⇒ must REJECT. This is a **new validation pass** (medium-blast: runs
on every module's globals), hence diagnose-then-implement-fresh.
**Wiring site**: `instantiate.zig:~353` (the func-body validate loop) —
`func_type_indices`, `global_entries`, `types_owned` are ALL already built
there; thread the global init-expr bytes into that scope (NOT the lighter
early block at 498-509, which only computes an `ntypes` count). One piece:
1. **const-expr type evaluator** (CONSERVATIVE — reject ONLY on a confidently-
   typed concrete mismatch; skip/accept any unrecognized form so an
   incomplete evaluator can't regress valid modules) — tree-walk init bytes:
   i32/i64/f32/f64/v128.const → scalar; `ref.null ht`→`(ref null ht)`
   (init_expr.readTypedRef); `ref.func i`→`(ref func_type_indices[i])`;
   `global.get j`→imported globals[j].type; struct.new/array.new*/array.
   new_fixed → `(ref null typeidx)`; ref.i31/any.convert_extern/extern.
   convert_any → fixed. Then `gcValTypeSubtype(result, declared,
   types_owned)` (validator.zig:2910; honors cyc177 `sections.canonicalEqual`
   rec-group identity; `types_owned` already in scope at ~353). Red test
   FIRST on .10/.15/.16 (all `ref.func` inits — fully evaluable).
**Bar**: gc invalid 57→60, return still 349 / trap 96, NO valid-module
regression — conservative design (skip unrecognized forms) bounds the
surface, but STILL re-run full gc + all 5 proposals: a mis-typed ref.func/
global.get could reject a valid global. If it trips a VALID module, REVERT
(accepting-invalid > rejecting-valid per project preference). Element-seg +
data-offset const-exprs share the same gap — note as follow-on, don't expand.

## §10 close map (cyc189 reassessment)

Feature impl rows (10.G/10.M/10.E/10.TC/10.R) are spec-corpus-mature but
ROADMAP-`[ ]`; their formal close needs realworld/p10 fixtures + 10.P.

- **realworld/p10** (skeleton, no `.wasm`): `clang_wasm64` + `clang_musttail`
  AUTONOMOUS (clang✓ in PATH, wasm-tools✓) — next major chunk after the
  spec residuals. `emscripten_eh` / `dart` / `wasm_of_ocaml` / `hoot` are
  TOOL-GATED (emcc/dart/ocaml absent) — self-provision via nix or defer.
- **gc .17** funcref-RTT (D-198 .17 rabbit hole) + **cross-module sig**
  (.30/.48/.50, uncounted, D-198/201) — deeper deferred edges.
- **funcrefs** 34/39 — 5 gated (externref-arg runner + resolveFuncrefGlobals
  off spec-corpus path); **10.P close gate** = user touchpoint by construction.

## Spec runner observable (cycle-164, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=349/407 trap=96/100 invalid=57/60 malformed=1/1 skip=20  ← 10.G c179 (typed call_indirect)
[multi-memory       ] return=407/407 trap=244/244  ← cyc188 ALL-GREEN (D-199/200/201 cross-module chain)
```

> Use `--fail-detail` (reliable per-assert), NOT the per-manifest breakdown
> (over-counts gc). Real gc residuals: i31(4) + type-sub(5) + ref_test(2).

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
