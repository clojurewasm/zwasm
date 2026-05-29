# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `97ca5e0e` (cyc203; 10.R-call_ref-JIT IT-1). **arm64 JIT `call_ref`
  executes** — `ref.func $double; call_ref $sig` → 42 via `runI32Export`. liveness
  `call_ref` arm + `op_call.emitCallRef` (null-check + `funcentity_funcptr_offset`
  deref + BLR; no type-check, validator guarantees subtype) + `emit.zig` dispatch.
  Mac test-all GREEN, lint clean. Test aarch64-gated (x86_64 mirror = D-207).
- **10.TC-JIT bundle CLOSED** cyc201: same-module tail-call codegen proven (direct
  0-arg/indirect/recursion-with-args) + real clang `musttail` fixture JIT-checked
  → 15. D-205 discharged; residuals D-206 (cross-module TC + return_call_ref).
- Phase 10 CLOSE-ELIGIBLE (spec corpus interp-complete). Earlier: cyc190-196 gc
  global-init/subtyping + clang_smoke; EH corpus 34/34 (ADR-0114). Runner EXECUTES
  via interp; gc_heap materialised at instantiate. 10.M memory64 + 10.E EH JIT
  largely done; 10.G GC JIT = interp-only (extreme effort, regalloc stack-map).
- **Step 0.7 on resume**: cyc203 (IT-1, code) kicks ubuntu @ `97ca5e0e` — verify
  next cycle. Prior: cyc201 (IT-5) `OK (HEAD=81eeb6fa)` GREEN; cyc202 docs-only.

## Active bundle

- **Bundle-ID**: 10.R-call_ref-JIT
- **Cycles-remaining**: ~2 (x86_64 call_ref + null-trap fixture → then return_call_ref reuse)
- **Continuity-memo**: arm64 `call_ref` JIT landed cyc203 `97ca5e0e` (liveness arm +
  `op_call.emitCallRef` + `emit.zig` dispatch). Funcref = `@intFromPtr(*FuncEntity)`;
  emitCallRef = pop funcref → marshal → `CMP X17,#0; B.EQ`(cind bounds stub) →
  `LDR X16,[X17,#funcentity_funcptr_offset]` → MOV X0,X19 → BLR → capture. Remaining
  (D-207): (a) **x86_64 mirror** — x86_64 has encoders (`encJccRel32(.e)` null-JZ,
  `encMovR64FromMemDisp32(funcentity_funcptr_offset)`) but its call dispatch differs
  from arm64's explicit switch — IT-2 Step-0 = find x86_64 call_ref dispatch path
  (`x86_64/emit.zig` / dispatch_collector) + mirror `emitCallRef`; then UNGATE the
  runner test (drop the aarch64 `skip.blocker(.@"D-207")`). (b) **null-trap fixture**
  — `ref.null $sig; call_ref` → trap (typed `ref.null` heap-type encoding TBD).
- **Exit-condition**: x86_64 `call_ref` JIT-executes (test ungated, green both
  hosts) + null-trap fixture → bundle close; then `return_call_ref` reuse (D-206).

## Active task — 10.R-call_ref-JIT IT-2 (x86_64 + null-trap)  **NEXT**

Step-0: find how x86_64 dispatches `call`/`call_indirect` (no explicit `.call_ref`
arm in `x86_64/emit.zig` — likely `dispatch_collector`/`emitCallIndirectCtx`), then
mirror `op_call.emitCallRef` for x86_64 (`x86_64/op_call.zig`): pop funcref, marshal,
`TEST`/`JZ`-null → trap fixup, `MOV r,[funcref+funcentity_funcptr_offset]`, MOV RDI=R15,
CALL, capture. Ungate the runner call_ref test (remove `skip.blocker(.@"D-207")`).
Add the null-trap fixture (`ref.null $sig; call_ref` → trap). Lighter queued:
refresh stale 10.P SKIP rationales (I14/I21 reference resolved D-192/D-179).

## §10 close map

Spec-corpus rows (10.G/10.M/10.E/10.TC/10.R) are mature but ROADMAP-`[ ]`;
formal close needs realworld/p10 + 10.P. Residual:
- **realworld/p10**: clang_musttail DONE (cyc201, JIT result-checked); clang_wasm64
  next-AUTONOMOUS (clang✓); emscripten/dart/ocaml/hoot TOOL-GATED.
- **gc .17** funcref-RTT (D-198 multi-mechanism rabbit hole) — deep defer.
- **funcrefs** 34/39 — 5 gated; **10.P close gate** = user touchpoint.

## Spec runner observable (cyc190, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=349/407 trap=96/100 invalid=60/60 ✅ malformed=1/1 skip=20  ← cyc190 invalid-axis closed
[multi-memory       ] return=407/407 trap=244/244  ← cyc188 ALL-GREEN (D-199/200/201 cross-module chain)
```
> gc residual: return=1 + trap=4 = type-subtyping.30/.48/.50 (the bundle).
> Use `--fail-detail` (reliable per-assert), NOT the per-manifest breakdown.

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
