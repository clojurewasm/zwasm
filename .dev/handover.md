# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc194 (`7bfc5d64`) — **restored wasm-2.0 wast-runner compile**
  (3 runners' empty-`sections.Types` literals missing `supertypes`/`finals`,
  latent since cyc126, masked by ubuntu cache until cyc193 regen). CRITICAL
  FINDING: `zig build test-all` was FALSELY-green (stale cache) since ~cyc177;
  the Mac per-chunk gate never builds these test-all-only exes. test-all now
  BUILDS but is **RED on 1 fail: wast_runner func.21** — non-null-local
  definite-assignment unimplemented (D-203; the bundle below greens it).
- cyc193 (`d3f56f4f`) assert_unlinkable directive (gc 3 pass/5 fail; 5 = D-202
  finality). cyc192 (`6a77cb19`) cross-module import subtyping. cyc190 gc
  global-init (invalid 60). gc residual: .17 (D-198) + 5 unlinkable (D-202).
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

- **Bundle-ID**: 10.Y-nonnull-local-init (D-203 — green test-all)
- **Cycles-remaining**: ~2
- **Continuity-memo**: cyc194 restored the wasm-2.0 wast-runner compile, but
  test-all is RED on 1 fail: `wast_runner func.21.wasm (invalid)` wrongly
  ACCEPTED. func.21 = `(local (ref 0))` non-nullable local read (`local.get 0`)
  before any `local.set` → INVALID per function-references definite-assignment
  (§validation), which `frontendValidate` does NOT track. **Must green test-all**
  (it's the merge gate; currently honestly-red after the cyc194 cache-unmask).
- **cyc195 IMPLEMENT**: non-null-local definite-assignment in the validator.
  Step 0 survey: how the validator tracks locals (`opLocalGet`/`opLocalSet`
  ~validator.zig:1339) + the control-stack (block/loop/if/else/end). Algorithm:
  init-bitset over locals; params + DEFAULTABLE locals (i32/i64/f32/f64/v128 +
  NULLABLE refs) start SET; non-defaultable (non-null `(ref $t)`) start UNSET;
  `local.set`/`local.tee` → set; `local.get`/`local.tee` of UNSET → reject
  (Error.UninitializedLocal or similar); at control merges, a local is SET only
  if set on ALL incoming paths (intersection — save bitset at block entry,
  intersect at branch/end). Red test FIRST: func.21 (+ a valid counter-case:
  non-null local set-then-get must PASS). Likely 1-2 cycles (control-flow merge
  is the subtle part).
- **Exit-condition**: `zig build test-all` GREEN on Mac + ubuntu (func.21
  rejected; wast_runner 1158/1158); NO regression to the 1157 currently-passing
  wasm-2.0 asserts or any other proposal; 0 panics. THEN pivot to realworld/p10
  (clang fixtures, §10 ROW close — the deferred cyc194 target).

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
