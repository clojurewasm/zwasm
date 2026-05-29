# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cyc152 (`f5265178`) — **ref.cast/cast_null** runtime
  type-test + `Trap.CastFailure` (reuses gcRefMatchesNonNull; abstract +
  concrete). gc trap 54→56. The c150 exit-code check caught an
  Instance.invoke Trap-classification @panic pre-commit (CastFailure
  wasn't listed). cyc149-151: ref.test abstract+concrete RTT +
  supertype_chain + crash fix. gc return 117.
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

## Active task — cycle 153: br_on_cast EXEC — **NEXT**

ref.test + ref.cast DONE. Last RTT lever. **VERIFY by full test-spec +
exit-code + panic grep** (lesson `runtime-exec-change-needs-testspec-
exitcode` — already caught 2 crashes c150/152).
- **br_on_cast / br_on_cast_fail EXEC**. The interp handler must live in
  the INTERP (Zone 2, where `doBranch` is at `interp/mvp.zig:285`) — a
  Zone-1 ops file can't import interp upward. Make
  `ref_test_ops.gcRefMatchesNonNull` pub; the interp handler pops the ref,
  matches against ht2 (`(instr.extra>>16)&0xFF`), and on match (br_on_cast)
  / mismatch (br_on_cast_fail) calls `doBranch(payload=labelidx)`, else
  falls through. Find where br/br_if register; add br_on_cast there.
  ZirInstr: payload=labelidx, extra = flags | ht1<<8 | ht2<<16. Unblocks
  br_on_cast.1/.2 (concrete subtype hierarchy) return assertions.
- **ref_test 33-fails** (return 68 pass=35): likely an `init`-op gap
  (any.convert_extern identity; ref.null none/nofunc/noextern) — step one
  invoke to localize (M3 covers compile, not exec mismatch).
No regression to 117 return / 56 trap / 57 invalid / 393 multi-mem.

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
