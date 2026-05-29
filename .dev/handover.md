# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc187 (diagnosis, no src) — root-caused the last multi-mem
  fail (linking0): **cross-module TABLE imports are UNSUPPORTED**
  (`linker.zig:487` rejects `.table`; no `defineTable`) → the
  uninstantiable module's table import fails early → its `elem` write
  never reaches Mt's shared table → `call(7)` UninitializedElement.
  Fix = cross-module table sharing, mirror D-199 (D-201b, cyc188).
  Earlier: D-201a re-exported-import invoke (cyc186 +2), D-200
  assert_uninstantiable (cyc184 +2/+6), D-199 shared memory (cyc182 +6);
  gc COMPLETE 62→349. **multi-mem 406/407 ret / 244 trap.**
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

## Active task — cycle 188: cross-module table imports (D-201b) — **NEXT**

Last multi-memory fail (linking0). Cross-module TABLE imports are
unsupported (`linker.zig:487` rejects `.table`). Implement, mirroring
D-199 memory sharing:
1. **Linker registry** — add `table_alias` to the `Payload` union +
   `defineTable(module, name, *TableInstance)` (capture the exporter's
   live `*TableInstance` / shared refs). Mirror `defineMemory`/`MemoryAlias`.
2. **Binding build** (`linker.zig:487` `.table` arm) — was
   `ImportKindMismatch`; build the `.table` `TableImport` from the alias
   (share the refs / instance).
3. **Runner register** (`spec_assert_runner_wasm_3_0.zig`) — on `register`,
   define exported tables (mirror the `defineMemory` register path,
   loop exports of kind table).
4. **Sharing**: ensure the importer's `rt.tables[slot]` aliases the
   exporter's live refs so elem writes persist (instantiate.zig:1383
   already value-copies; verify the binding carries live refs).
**Bar**: linking0 `call(7)→0` → **multi-mem 407 ALL-GREEN**, no regression
to gc 349/96/57, exit 0, 0 panics. HIGH-ish (cross-module table). If a
rabbit hole, defer. (Deferred: gc .17 + cross-module sig per D-198.)

## Larger §10 work (later bundles)

- **funcrefs** return 32/39 — 1 externref-elem (runner externref-arg) +
  `resolveFuncrefGlobals` (off spec-corpus path). **10.P close gate** =
  user touchpoint by construction.

## Spec runner observable (cycle-164, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=349/407 trap=96/100 invalid=57/60 malformed=1/1 skip=20  ← 10.G c179 (typed call_indirect)
[multi-memory       ] return=406/407 trap=244/244  ← cyc186 re-exported-import invoke (+2); 1 fail left (linking0)
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
