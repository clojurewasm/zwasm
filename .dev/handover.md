# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc177 (`5c41c273`) — **D-198 Phase-10b LANDED**: iso-recursive
  rec-group canonical equality (`sections.canonicalEqual` + `rec_span` at
  decode; positional intra-group / canonical inter-group refs) + funcref
  RTT (`FuncEntity.raw_typeidx` resolution in `ref.test`/`ref.cast`) +
  precise equivalence-class `canonical_ids`. **gc return 345→348 (+3)**:
  type-subtyping ref.test-on-funcref 348/360 pass; module 378 correctly
  stays 0 (no regression); invalid HELD 57. cyc174: start-exec → multi-mem
  396. **gc 62→348**.
- Earlier arc: cyc147-148 ADR-0125 packed (62→116); cyc146 ADR-0016 M3
  validate self-attribution (`compile FAIL [fn= off= op=]`) + subtypeCtx
  coercion; cyc144/145 GC blocktypes + br_on_cast; cyc141 rt.datas fix
  (multi-mem→393); cyc130-140 i31/struct/array + const-expr.
- Runner EXECUTES via interp; gc_heap + gc_type_infos + rt.datas all
  materialised at instantiate. Arrays use 8-byte uniform slots
  (type_info.slot_size); data-seg elements are NATURAL width.
- **Bundle 10.E-eh-tail CLOSED** cyc120 (`5db875b0`) — EH corpus FULLY
  GREEN 34/34 (cross-module propagation + caller-frame catch; ADR-0114
  full substrate cyc110–120; D-192 EH clause PROVEN). Lesson
  `eh-cross-module-tag-substrate-scope` has the journey.
- Mac+ubuntu green through cyc142 (`OK (HEAD=a763d44a)`).

## Active bundle

- **Bundle-ID**: 10.G-wasmgc (WasmGC spec corpus — the largest
  remaining §10 gap; follows the CLOSED 10.E EH chain)
- **Cycles-remaining**: open; next = the cyc176 3-piece landing (below).
- **Continuity-memo**: substrate DONE (don't rebuild): `feature/gc/`
  heap+type_info+i31+collector, struct_ops/array_ops registered, ADR-0115/
  0116/0121/0124/0125. **VERIFY by DIRECT binary run**; M3 attributes
  every compile FAIL (`grep "compile FAIL.*op=0x"`).
- **Exit-condition**: gc return ≥ 90 **EXCEEDED (345)**. Open target:
  maximise return toward the corpus ceiling (D-198 tail = cyc176).

## Active task — cycle 178: the 2 residual gc type-subtyping FAILsetup — **NEXT**

D-198 Phase-10b landed (cyc177, +3). Remaining gc return-fail = **2
FAILsetup** (type-subtyping `run`-asserts whose module fails to COMPILE,
even with the iso-recursive validator OR-arm). These compile (not run)
fails are the debt-row's "within-module cross-rec-group" cluster
(type-subtyping.9/12/21/24/39/45-class). cyc178:
1. **Identify the 2 modules** — the FAILsetup `run`-asserts in the
   type-subtyping `.wast` whose module silently fails compile. The
   compile failure is at `validateTypeSection`/`typeDefIsSubtype`
   (a `sub`/`sub final` conformance check), NOT a `run` — so it's a
   different path than the cyc177 `gcValTypeSubtype` OR-arm.
2. **Trace why** — `typeDefIsSubtype` (validator ~2925) uses
   `gcValTypeSubtype` for fields/params/results, which now has the
   canonical OR-arm; but the rejecting check may be the supertype
   *declaration* conformance (`$h sub $g2` across rec groups) needing
   the same iso-recursive treatment, or a finality/forward-ref rule.
3. Fix + verify FULL test-spec: gc invalid stays 57, no regression to
   348/396/337/71/34, exit 0, 0 panics. Add to ADR-0126 if it's a 5th
   distinct mechanism.

## Larger §10 work (later bundles)

- **funcrefs** return 32/39 — 1 externref-elem (runner externref-arg) +
  `resolveFuncrefGlobals` (off spec-corpus path). **10.P close gate** =
  user touchpoint by construction.

## Spec runner observable (cycle-164, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=348/407 trap=90/100 invalid=57/60 malformed=1/1 skip=20  ← 10.G c177 (iso-recursive)
[multi-memory       ] return=396/407 trap=238/238  ← cyc174 start-exec (+3 start0)
```

> Use `--fail-detail` (reliable per-assert), NOT the per-manifest
> breakdown (over-counts gc). Real gc residuals: i31(4) + type-sub(5) +
> ref_test(2).

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
