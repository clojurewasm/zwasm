# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc149 (`09907dca`) — **ref.test/test_null abstract RTT**:
  real runtime type-test (i31 low-bit / struct,array via ObjectHeader.kind
  / hierarchy tops match non-null / bottoms reject). Pure `gcAbstractMatch`
  unit-tested. gc return holds 116 (ref_test fixtures blocked END-TO-END
  by their `init` ops — separate gap, not ref.test). No regression.
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
- **Cycles-remaining**: ~3 (packed DONE c147-148; next = RTT exec:
  ref.test/cast abstract+concrete type-test, then br_on_cast branch)
- **Continuity-memo**: parse + i31 + struct/array narrowing/exec/const-
  expr + packed-validate all DONE (gc return →105). Substrate (don't
  rebuild): `feature/gc/` heap+type_info+i31+collector, struct_ops/
  array_ops registered (api/instance.zig:883-887), StorageType union
  (ADR-0125), ADR-0115/0116/0121/0124. **VERIFY by DIRECT binary run**;
  M3 attributes every compile FAIL (`grep "compile FAIL.*op=0x"`).
- **Exit-condition**: gc return ≥ 90 **EXCEEDED (116 at cyc148)**. Open
  target: maximise return (RTT exec) toward the corpus ceiling.

## Active task — cycle 150: RTT exec tail + ref_test end-to-end — **NEXT**

ref.test/test_null abstract DONE (c149). Remaining RTT levers (236 gc
return-fails; abstract ref.test correct but ref_test fixtures need their
`init` to run). To get a return delta, pick ONE + verify by direct-binary
run on a `/tmp/x/gc/{ref_test,ref_cast,br_on_cast,...}` corpus copy:
- **ref_test end-to-end blocker**: ref_test.0's `init` uses
  any.convert_extern / extern.convert_any (ref_convert_ops.zig identity —
  check), struct.new_default, array.new_default, `ref.null none/nofunc/
  noextern`. Find which exec-traps/mismatches (the runner prints
  assert mismatches; or step a single invoke). Likely a small gap that
  unblocks the whole ref_test.0 return set + makes c149's ref.test visible.
- **ref.cast / ref.cast_null EXEC**: reuse `gcRefMatchesNonNull`; trap on
  mismatch — needs a new `Trap.CastFailure` (widen `runtime/trap.zig`;
  blast radius: trap_surface c_api map + spec-runner trap-reason). Spec
  reason string "cast failure".
- **Concrete-$idx RTT**: thread `Types.supertypes` → `TypeInfo.supertype_
  chain` at `materialiseGcTypes` (~1016); then `gcAbstractMatch` concrete
  branch walks the chain instead of coarse-true.
- **br_on_cast/_fail EXEC**: wire interp (reuse match + `doBranch` from
  `interp/mvp.zig:285`; ZirInstr extra packs flags|ht1|ht2, payload=label).
No regression to 116 return / 54 trap / 57 invalid / 393 multi-mem.

## Larger §10 work (later bundles)

- **funcrefs** return 32/39 — 1 externref-elem (runner externref-arg) +
  `resolveFuncrefGlobals` (off spec-corpus path). **10.P close gate** =
  user touchpoint by construction.

## Spec runner observable (cycle-144, DIRECT binary run)

```
[memory64           ] return=337  (all pass)   [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=32/39
[gc                 ] return=62/407 trap=18/100 invalid=57/60 ParseFailed=0 ValidateFailed=31  ← 10.G c144
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
