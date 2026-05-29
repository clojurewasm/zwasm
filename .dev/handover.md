# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc191 (diagnosis, no src) — confirmed gc `.30/.48/.50`
  SignatureMismatch = cross-module import-subtyping gap (`checkImportTypeMatches`
  instantiate.zig:1649 exact `eql`; Wasm 3.0 §4.5.10 needs func subtyping).
  Deep edge → OPENED bundle (see below); D-198 refined.
- cyc190 (`0f06df6e`, ubuntu-verified green) — **gc global-init type-check
  landed**: `validator.constExprResultType` + `validateGlobalInits` (GC-aware,
  ADR-0126) in `frontendValidate`. **gc invalid 57→60 fail=0**; ZERO regression
  (gc return 349 / trap 96 + all 5 proposals unchanged; assert_invalid 191→194).
  Remaining gc fails: **return=1 + trap=4 = .30/.48/.50** (the bundle below).
  §10 ROW close also needs realworld/p10 (clang_wasm64+clang_musttail
  autonomous; emcc/dart/ocaml/hoot tool-gated) — after the gc edges.
- Earlier arc: cyc177 iso-recursive canonicalEqual; cyc147-148 ADR-0125
  packed; cyc146 ADR-0016 M3 self-attribution; cyc130-140 i31/struct/array.
- Runner EXECUTES via interp; gc_heap + gc_type_infos + rt.datas all
  materialised at instantiate. Arrays use 8-byte uniform slots
  (type_info.slot_size); data-seg elements are NATURAL width.
- EH corpus FULLY GREEN 34/34 (ADR-0114 substrate cyc110-120; lesson
  `eh-cross-module-tag-substrate-scope` has the journey).
- Mac+ubuntu green through cyc190 (`OK` exit 0). 10.G-gc + 10.H-multimem
  CLOSED cyc188. Cross-module sharing substrate: D-199 memory + D-201 table/func.

## Active bundle

- **Bundle-ID**: 10.X-xmodule-import-subtype (D-198 .30/.48/.50)
- **Cycles-remaining**: ~2-3
- **Continuity-memo**: gc `type-subtyping.30/.48/.50` fail at instantiate with
  `SignatureMismatch` because `checkImportTypeMatches` (instantiate.zig:1649-
  1654) compares cross_module func sigs with exact `sp.eql(wp)`. Wasm 3.0
  §4.5.10 external matching uses func SUBTYPING (contravariant params /
  covariant results, §3.3). Binding carries `source_rt` (exporter Runtime —
  exporter types reachable) + flat `source_signature`. Results are self-ref
  CONCRETE refs (`(ref null 1)`, `(ref 0)`); each fixture imports the SAME name
  under multiple subtype-related sigs (e.g. .30 imports `M.f1` as type 0 AND
  type 1). **Fix is MONOTONIC-SAFE**: keep `eql` fast-path, add subtype
  FALLBACK — can only widen acceptance, so the green 407 multi-mem + 34 EH
  cross-module imports (all pass `eql`) are unaffected by construction.
- **cyc191 RESOLVED the pivotal unknown**: M (`.29`, `register M` at manifest
  L53-54) and importer `.30` have **IDENTICAL type sections** (type 0 `(func
  (result funcref))`, type 1 `(sub 0 (func (result (ref null 1))))`, type 2
  `(sub 1 …(ref null 2))`). .30 imports `M.f1` (actual type 1) declared as
  type 0 — type 1 <: type 0, so exact `eql` wrongly rejects. Spec cross-module
  subtype tests duplicate type defs → indices align.
- **cyc192 IMPLEMENT**: func subtyping in the `.cross_module` arm — params
  CONTRAVARIANT `subtype(want_p, src_p)`, results COVARIANT `subtype(src_r,
  want_r)` (Wasm 3.0 §3.3.5.1), `eql` stays the fast-path. Expose a `pub`
  helper from validator.zig (mirror cyc190 `validateGlobalInits`) since
  `gcValTypeSubtype` is private there. **Correctness note (no-workaround)**:
  do NOT just reuse importer `types` for the source's concrete-ref indices —
  that only works because these fixtures duplicate types. The あるべき論
  solution decodes the exporter's types via `source_rt` and compares concrete
  refs cross-module structurally (generalize `canonicalEqual` across two
  `Types`). If the cross-module structural compare balloons, a same-space
  first cut is acceptable ONLY with a D-NNN row naming the gap.
- **Exit-condition**: gc return 349→350 + trap 96→100 (.30/.48/.50 instantiate
  OK + assertions pass); NO regression to multi-mem 407 / EH 34 / invalid 60 /
  all 5 proposals; 0 panics; exit 0. If after 2-3 cycles the cross-module
  structural compare proves a deeper rabbit hole, close-pivot to realworld/p10.

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
