# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc180 (investigated+reverted, no net src) — .17 `run`
  `InvokeFailed` is a MULTI-mechanism rabbit hole (runtime call_indirect
  exact-sig [verified fix known] + a further unidentified Trap.Unreachable);
  DEFERRED as low-ROI (1 fixture, ≥2 coordinated non-observable fixes, see
  D-198). **gc bundle effectively COMPLETE: 62→349 ret / 96 trap / 57 inv.**
  cyc179: typed call_indirect (+1); cyc178: ref.cast narrow (+6 trap);
  cyc177: iso-recursive canon (+3); cyc174: start-exec (multi-mem 396).
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

- **Bundle-ID**: 10.H-multimem-linking (multi-memory linking/import
  return-fails — the next observable §10 cluster after the gc corpus).
- **Cycles-remaining**: open; next = cyc181 multi-memory fail triage.
- **Continuity-memo**: gc bundle (10.G) delivered 62→349 ret / 96 trap /
  57 inv — substrate DONE (`feature/gc/` heap+type_info+i31+collector,
  ADR-0115/0116/0121/0124/0125/0126 iso-recursive canon). gc residual
  DEFERRED (D-198: .17 rabbit hole + cross-module sig). **VERIFY by DIRECT
  binary run**; M3 attributes every compile FAIL.
- **Exit-condition**: multi-memory return > 396 (reduce the 11-fail
  linking/imports cluster). gc return ≥ 90 was long EXCEEDED (349).

## Active task — cycle 181: multi-memory 11 counted return-fails — **NEXT**

gc bundle has delivered (62→349). Pivot to the next OBSERVABLE cluster:
multi-memory return=396/407, **fail=11** (counted) across linking0(1) /
linking1(2) / linking2(2) / linking3(2) / imports4(4) per the per-manifest
breakdown. Fresh investigation:
1. `--fail-detail` filtered to multi-memory → classify each fail
   (FAILsetup / FAILval / FAILtrap) + the failing manifest.
2. M3 `compile FAIL` / `instantiate FAIL` attribution (DIRECT binary,
   plain mode) for the setup fails; for FAILval trace the run-assert.
3. Likely a shared mechanism across linking0-3 (cross-module memory
   import/export or data-segment linking). Fix the densest cluster first.
Verify FULL test-spec: no regression to gc 349/96/57, exit 0, 0 panics.
**Deferred gc**: .17 rabbit hole + .30/.48/.50 uncounted cross-module sig
(D-198) — land as a focused bundle only if gc conformance is re-prioritised.

## Larger §10 work (later bundles)

- **funcrefs** return 32/39 — 1 externref-elem (runner externref-arg) +
  `resolveFuncrefGlobals` (off spec-corpus path). **10.P close gate** =
  user touchpoint by construction.

## Spec runner observable (cycle-164, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=349/407 trap=96/100 invalid=57/60 malformed=1/1 skip=20  ← 10.G c179 (typed call_indirect)
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
