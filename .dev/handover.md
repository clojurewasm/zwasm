# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 120 (`5db875b0`) — cross-module EH exception
  propagation + caller-frame catch. (1) cross_module thunk moves an
  uncaught throw's `Exception` from `source_rt.pending_exception` into
  the caller's rt; (2) `callOp` searches the CURRENT frame's try_table
  on `Trap.UncaughtException` (the thunk leaves no frame on rt, unlike
  a same-module ZIR callee). **exception-handling corpus FULLY GREEN:
  return 34/34, trap 2/2, exception 4/4, invalid 7/7** (direct-binary);
  no regression; test+lint green.
- **Bundle 10.E-eh-tail CLOSED** — exit (return ≥ 33/34) met at 34/34;
  delta cyc119 (`9d5a6212`, *TagInstance: 31→32) + cyc120 (32→34).
  This completes the full EH cross-module substrate (cyc110–120,
  ADR-0114): parser→validator→instantiate-binding→*TagInstance
  identity→cross-module propagation. D-192 EH clause PROVEN.
- Mac test+lint green cyc120. ubuntu: cyc119 HEAD green
  (`OK (HEAD=db24a086)`); cyc120 kick backgrounded.

## Active bundle

- **Bundle-ID**: 10.G-wasmgc (WasmGC spec corpus — the largest
  remaining §10 gap; follows the CLOSED 10.E EH chain)
- **Cycles-remaining**: ~survey + N (scope TBD by the survey)
- **Continuity-memo**: gc corpus = return 407 (pass=0 fail=384),
  trap 100 (fail), invalid 60 (pass=55 fail=5), malformed 1 (pass).
  Many gc/* `compile FAIL: ParseFailed` (struct/array/i31/ref_cast/
  type-subtyping decode + GC ZIR ops + heap + subtype lattice). exnref
  ValType (cyc112) + the `(ref $concrete) <: func` pre-GC assumption in
  `valTypeIsSubtypeFree` are GC-adjacent. ADR-0115/0116/0121 scope the
  GC heap + type-info substrate (partially landed: `gc_type_infos`,
  `materialiseGcTypes`). **First step = SURVEY** (cyc121): map the gc
  corpus failure classes (ParseFailed vs validate vs execute) by DIRECT
  binary run + categorize, like the cyc111 EH probe. **VERIFY runner
  deltas by DIRECT binary run** (zig-build stderr cache/lossy — D-197).
- **Exit-condition**: gc corpus return pass ≥ 50/407 (first meaningful
  execution slice) — refine after the survey.

## Active task — cycle 121: WasmGC corpus survey

EH is done (34/34). Pivot to gc. Probe the gc corpus by DIRECT binary
run: how many gc/* `compile FAIL: ParseFailed` vs reach validate/execute
+ fail? Categorize the failure classes (struct.new / array.new / i31 /
ref.cast / ref.test / type-subtyping / br_on_cast). Identify the
smallest first execution slice (likely a parse/decode gap shared across
many — like exnref was for EH). Survey the existing GC substrate
(`feature/gc/` heap + type_info, ADR-0115/0116/0121) + what
`valTypeIsSubtypeFree` assumes. Deliverable: a scoped multi-step plan in
a new `.dev/lessons/2026-05-29-wasmgc-corpus-scope.md`, mirroring the
EH cyc115 survey. No code this cycle unless a 1-line parse gap is
trivially obvious; the survey de-risks the multi-cycle GC implementation.

## Larger §10 work (later bundles)

- **Deferred funcrefs gaps** (post-EH): funcrefs return 32/39 — 1
  externref-elem (runner externref-arg parsing) + engine/cli_run
  `resolveFuncrefGlobals` (off spec-corpus path).
- **multi-memory** — return 387/407 (20 fails), trap 237/238 (1).
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (cycle-120, verified by DIRECT binary run)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34/34 trap=2/2 invalid=7/7 exception=4/4  ✅ FULLY GREEN
[function-references] return=39(pass=32 fail=1) trap=4(pass) invalid=18(pass)
[gc                 ] return=407(pass=0 fail=384) trap=100(fail) invalid=60(pass=55 fail=5) malformed=1(pass)  ← 10.G
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
