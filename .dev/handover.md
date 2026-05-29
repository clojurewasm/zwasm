# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc174 (`cbcd081b`) — **Wasm start section now EXECUTES** at
  instantiate (was validated-but-discarded; §4.5.4 invoke added to
  `instantiateInternal` after data init, trap→fail). **multi-memory
  393→396 (+3, start0 fixed)**, no regression, 0 panics. api/instance.zig
  cap 3000→3200 (ADR-0099 amend). cyc168/169 = Phase-10a (+2);
  **gc 62→345**.
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
- **Cycles-remaining**: open (RTT exec + array bulk ops DONE c149-158;
  next = survey densest remaining gc return-fail cluster)
- **Continuity-memo**: parse + i31 + struct/array narrowing/exec/const-
  expr + packed-validate all DONE (gc return →105). Substrate (don't
  rebuild): `feature/gc/` heap+type_info+i31+collector, struct_ops/
  array_ops registered (api/instance.zig:883-887), StorageType union
  (ADR-0125), ADR-0115/0116/0121/0124. **VERIFY by DIRECT binary run**;
  M3 attributes every compile FAIL (`grep "compile FAIL.*op=0x"`).
- **Exit-condition**: gc return ≥ 90 **EXCEEDED (116 at cyc148)**. Open
  target: maximise return (RTT exec) toward the corpus ceiling.

## Active task — cycle 175: gc D-198 coordinated cross-module landing — **NEXT**

On-bundle (10.G), observable, HIGH blast radius — the ADR-0126 Phase-10b
plan; fresh post-compact context = its "fresh-context cycle" precondition.
Flip the **3 cross-module type-subtyping fails** (45 exporter validate +
46/48/50 importer link) by landing TWO pieces TOGETHER (one alone is
non-observable per cyc171):
1. **Validator** — re-apply `gcCanonicalEqual` (recursive structural
   equality: finality + canonical supertypes + comptype, refs recurse,
   depth-32 coinductive cutoff) as an OR in `gcValTypeSubtype`'s
   concrete→concrete arm. **Verified SAFE c171** (fixture 45 validates,
   gc invalid HELD 57). See ADR-0126 cyc171 note.
2. **Linker** — `sigSubtype` (exporter actual <: importer declared:
   contravariant params / covariant results) replacing the EXACT
   `ValType.eql` at linker.zig ~527 (fixes 46/48/50 SignatureMismatch).
VERIFY FULL test-spec ALL proposals + assert_invalid: **gc invalid MUST
stay 57** (cyc122 regression mode), exit 0, 0 panics, no regression to
345/90/393/337/71/34. Then SEPARATELY trace the 2 FAILval (non-canonical
root cause, c172-FALSIFIED — `--fail-detail` per-assert ref.test/cast).

> If the coordinated landing regresses gc invalid → revert both, the
> linker sigSubtype likely over-accepts; narrow to func-import only.

## Larger §10 work (later bundles)

- **funcrefs** return 32/39 — 1 externref-elem (runner externref-arg) +
  `resolveFuncrefGlobals` (off spec-corpus path). **10.P close gate** =
  user touchpoint by construction.

## Spec runner observable (cycle-164, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=345/407 trap=90/100 invalid=57/60 malformed=1/1 skip=20  ← 10.G c169
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
