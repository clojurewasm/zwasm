# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc164 (`9070800d`) — **general const-expr items in element
  segments** (array.new/array.new_fixed/struct.new) + array.new_elem
  materialisation via evalGlobalInitGc. Fixes gc/array.8 (array-of-
  arrays): **gc return 335→339 (+4)**, trap 88→90, invalid 57 held; no
  funcref-elem regression. exit 0, 0 panics. cyc163 `--fail-detail`
  diagnostic (use it, NOT the over-counting breakdown). cyc161 externref
  args (+58); cyc162 abstract subtyping (+15). **gc 62→339** session.
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

## Active task — cycle 165: i31.3/i31.4 (table-init-expr + const-expr global.get) — **NEXT**

Reliable `--fail-detail` (`<bin> test/spec/wasm-3.0-assert --fail-detail`)
gc residuals: **i31=4** (i31.3/i31.4 instantiate-fail) + **type-subtyping=5**
(D-198 rec-group, deeper) + **ref_test=2** (ref_test_eq exp=0 got=2 =
eq-on-externalized-host precise gap; test-canon InvokeFailed).

- **i31.3** (`$i31ref_of_global_table_initializer`): `(table $t 3 3
  (ref i31) (ref.i31 (global.get $g)))` — **table-with-init-expr**
  (`0x40 0x00 reftype limits expr` encoding). decodeTables doesn't
  handle the 0x40 prefix → decode fails. Needs: parser (TableEntry
  init_expr field) + instantiate (eval init_expr, fill table) +
  const-expr global.get-of-import. 3 asserts.
- **i31.4** (`$i31ref_of_global_global_initializer`): `(global i31ref
  (ref.i31 (global.get $g0)))` — const-expr global.get in
  evalGlobalInitGc (thread imported globals; mirror cyc159 ref.func).
  1 assert. (Both share the const-expr global.get machinery.)
VERIFY full test-spec + exit-code + panic grep (cyc150 lesson; DIRECT
binary; `--fail-detail` for per-assert truth). No regression to 339
return / 90 trap / 57 invalid / 393 multi-mem / 34 funcrefs.

## Larger §10 work (later bundles)

- **funcrefs** return 32/39 — 1 externref-elem (runner externref-arg) +
  `resolveFuncrefGlobals` (off spec-corpus path). **10.P close gate** =
  user touchpoint by construction.

## Spec runner observable (cycle-164, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=339/407 trap=90/100 invalid=57/60 malformed=1/1 skip=20  ← 10.G c164
[multi-memory       ] return=393/407 trap=238/238  ← cyc141 rt.datas fix
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
