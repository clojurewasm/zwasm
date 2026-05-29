# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc159 (`5783f161`) — **ref.func in GC const-expr** global
  init (0xD2 in evalGlobalInitGc): **gc return 255→262 (+7)**, trap
  72→84 (+12, array_init_elem.3 instantiates → its traps run). Fixed
  the array_init_elem.3 InstantiateFailed. cyc158 array.init_data/elem
  + elem_types threading drove 249→255 (validator.zig cap 3000→3200,
  ADR-0099 amend). cyc157 array.copy 226→249. **gc return 62→262**
  across the session.
- cyc147-148 **ADR-0125 packed COMPLETE** (A union rename → B-validate
  decode → B-exec get_s/u): gc return 62→116, trap 18→54, ValidateFailed
  27→14, invalid 57 held. cyc146 ADR-0016 M3 + concrete-subtype coercion.
- cyc146 infra (`337eb386`): **ADR-0016 M3** validate self-attribution
  (`compile FAIL: … [fn= off= op=]`, retired op-probe) + concrete→concrete
  subtypeCtx coercion (ValidateFailed 29→27). cyc144/145: GC reftype
  blocktypes + br_on_cast/_fail validate.
- cyc141 array exec + rt.datas production fix (multi-memory +6→393);
  cyc138-140 struct/array const-expr + array.new_data/elem; cyc130-137
  i31/struct/array. gc return 0→…→62, trap 18, multi-memory 393.
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

## Active task — cycle 160: remaining GC return levers — **NEXT**

Array bulk ops DONE (c157-158); ref.func GC const-expr DONE (c159; gc
return 262/407). Module-level instantiate/compile FAILs remaining:
gc/type-subtyping.{45 ValidateFailed=D-198, 46 UnknownImport, 48/50
SignatureMismatch}. The bulk of the 90 return-fails are per-assert value
mismatches in compiling modules (not module-level FAILs) → SURVEY which
gc modules cascade the most (re-run binary, group by export). Levers:
- **type-subtyping 46/48/50** — UnknownImport + SignatureMismatch at
  instantiate (import/signature handling under rec-group/sub types).
- **ref.test/ref.cast concrete gaps** + **struct init-op gaps**.
- **extern.convert_any / any.convert_extern** (FB 26/27) exec.
- **D-198** (type-subtyping.45 rec-group iso-recursive) — deep/ADR.
VERIFY full test-spec + exit-code + panic grep (cyc150 lesson; DIRECT
binary). No regression to 262 return / 84 trap / 57 invalid / 393
multi-mem.

## Larger §10 work (later bundles)

- **funcrefs** return 32/39 — 1 externref-elem (runner externref-arg) +
  `resolveFuncrefGlobals` (off spec-corpus path). **10.P close gate** =
  user touchpoint by construction.

## Spec runner observable (cycle-159, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=32/39
[gc                 ] return=262/407 trap=84/100 invalid=57/60 malformed=1/1 skip=20  ← 10.G c159
[multi-memory       ] return=393/407 trap=238/238  ← cyc141 rt.datas fix
```

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
