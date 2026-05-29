# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 129 (`0a3826ac`) — `ref.i31` result is non-null
  `(ref i31)`, not nullable `.i31ref` (opRefI31 spec fix). Unblocked
  i31.0's `global.set $1` into a non-null `(ref i31)` global. **gc
  ValidateFailed 50→49** (i31.0 now passes validate). test+lint green.
- cyc128 (`d6042f29`) scanInitExpr GC const-expr (0xFB) → i31.4
  validates (ValidateFailed 51→50); cyc127 (`e14380ec`) D-197 split
  (ParseFailed=0/ValidateFailed=51); cyc126 rec parse + finality fix
  (return 0→2, invalid 55→57); cyc124-125 subtype validate; ADR-0124.
- Runner EXECUTES via interp (`Instance.invoke` → `dispatch.run`), NOT
  JIT — so GC execution = interp/mvp handlers (~25 LOC for i31, no heap).
- cyc120 (`5db875b0`): cross-module EH propagation + caller-frame catch
  → **EH corpus FULLY GREEN 34/34** (bundle 10.E CLOSED; D-192 PROVEN).
- **Bundle 10.E-eh-tail CLOSED** — exit (return ≥ 33/34) met at 34/34;
  delta cyc119 (`9d5a6212`, *TagInstance: 31→32) + cyc120 (32→34).
  This completes the full EH cross-module substrate (cyc110–120,
  ADR-0114): parser→validator→instantiate-binding→*TagInstance
  identity→cross-module propagation. D-192 EH clause PROVEN.
- Mac green cyc120. ubuntu: cyc120 HEAD green (`OK (HEAD=40d7f0d0)`);
  cyc121-123 docs-only (survey/finding/ADR-0124, no kick).

## Active bundle

- **Bundle-ID**: 10.G-wasmgc (WasmGC spec corpus — the largest
  remaining §10 gap; follows the CLOSED 10.E EH chain)
- **Cycles-remaining**: ~5 (validate-attribute+fix → struct/array exec →
  RTT materialise → array-copy/fill → i31 exec)
- **Continuity-memo**: type-section PARSE complete (cyc124-126). cyc127
  proved all 51 remaining gc failures are VALIDATE (ParseFailed=0,
  ValidateFailed=51) — NOT execution (cyc126 guess wrong). Validator
  GC-op handlers live in `validator.dispatchPrefixFB` (~1315). Histogram
  + valid/invalid caveat in `lessons/2026-05-29-gc-corpus-block-is-
  validate-not-parse.md`. Substrate landed (don't rebuild): `feature/gc/`
  heap+type_info+i31+collector, ADR-0115/0116/0121/0124. The 5
  invalid-accepted (struct.3/4, array.1/3/4) in
  `lessons/2026-05-29-wasmgc-corpus-scope.md`. **VERIFY by DIRECT binary
  run**; compile FAILs now name the axis (ParseFailed/ValidateFailed).
- **Exit-condition**: gc corpus return pass ≥ 50/407 (first execution
  slice via struct/array) — refine as chunks land.

## Active task — cycle 130: wire i31 interp EXECUTION → first gc return pass — **NEXT**

i31.0 + i31.4 now VALIDATE; they fail at EXECUTION (interp has no 0xFB
GC handler — ref.i31/i31.get return Trap.Unreachable; global-init eval
of ref.i31 also missing). Chunk (target a real `gc return` pass):
(a) interp handlers in `src/interp/mvp.zig` for `.@"ref.i31"` (pop i32,
push `i31.i32ToI31Truncate(x) | 1` as anyref via `feature/gc/i31.zig`),
`.@"i31.get_s"` / `.@"i31.get_u"` (pop anyref; if null → Trap; else
decode via i31ToI32Signed/Unsigned). (b) Register them in the dispatch
table — `feature/gc/register.zig` is an empty stub (~line 58); wire the
3 interp fn-pointers (see how other ops register). (c) Global-init-expr
eval of ref.i31 (find the init-expr evaluator used at instantiate;
mirror the scanInitExpr opcode set). Red: a unit test invoking a
ref.i31+i31.get_u func via the interp. Observable: gc return pass ↑
(i31.0 `new`/`get_u`/`get_s` + i31.4 `get`). Watch: NO regression to 2
return / 57 invalid / 49 ValidateFailed. ValType: i31 lives in
Value.anyref (u32, low-bit-1 = i31 discriminant).

## Larger §10 work (later bundles)

- **Deferred funcrefs gaps** (post-EH): funcrefs return 32/39 — 1
  externref-elem (runner externref-arg parsing) + engine/cli_run
  `resolveFuncrefGlobals` (off spec-corpus path).
- **multi-memory** — return 387/407 (20 fails), trap 237/238 (1).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (cycle-120/121, verified by DIRECT binary run)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34/34 trap=2/2 invalid=7/7 exception=4/4  ✅ FULLY GREEN
[function-references] return=39(pass=32 fail=1) trap=4(pass) invalid=18(pass)
[gc                 ] return=407(pass=2 fail=382) trap=100(fail) invalid=60(pass=57 fail=3) malformed=1(pass) ParseFailed=0 ValidateFailed=49  ← 10.G (cyc129; i31.0+i31.4 validate, need exec)
[multi-memory       ] return=407(pass=387 fail=20) trap=238(pass=237 fail=1)
```

## Open questions / blockers

- D-197 (now-relevant at 10.G): `Engine.compile`/`frontendValidate`
  collapse specific errors to ParseFailed/bool — surfacing the real
  validate/decode error would make the gc 384-fail debugging precise.
  Discharge candidate this bundle.
- D-192: EH clause PROVEN (EH 34/34). funcrefs clause proven cyc108.

## Key refs

- ADR-0114 (EH `*TagInstance`, IMPLEMENTED cyc110–120); ADR-0115/0116/
  0121 (GC heap + type-info); ADR-0120/0123.
- `.dev/lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`
  (full EH journey) + `2026-05-29-zig-run-step-cache-stale-diag.md`.
- ROADMAP §10; `.dev/phase_log/phase10.md`.
