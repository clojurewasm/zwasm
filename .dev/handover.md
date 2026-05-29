# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `5453141f` (cyc206). **arm64 JIT `return_call_ref` tail-calls through a
  funcref → 42** (`ref.func $worker; return_call_ref $sig` via `runI32Export`).
  `op_tail_call.emitReturnCallRef` = emitCallRef funcref-deref front (pop *FuncEntity,
  null-check, LDR X16 from `funcentity_funcptr_offset`) + tail-call tail (MOV X0,X19;
  frame_teardown; BR X16); wired via manual `emit.zig` switch + de-stubbed per-op file.
  Test aarch64-gated (x86_64 mirror = D-206). Mac test-all + lint GREEN.
- **call_ref JIT done both arches** (10.R-call_ref-JIT bundle closed cyc205, ubuntu
  @ `5f104ff4`). emitCallRef = pop funcref → null-check → funcptr deref → CALL.
  call_ref null-trap fixture = D-207 residual.
- **10.TC-JIT bundle CLOSED** cyc201: same-module tail-call codegen proven (direct
  0-arg/indirect/recursion-with-args) + real clang `musttail` fixture JIT-checked
  → 15. D-205 discharged; residuals D-206 (cross-module TC + return_call_ref).
- Phase 10 CLOSE-ELIGIBLE (spec corpus interp-complete). Earlier: cyc190-196 gc
  global-init/subtyping + clang_smoke; EH corpus 34/34 (ADR-0114). Runner EXECUTES
  via interp; gc_heap materialised at instantiate. 10.M memory64 + 10.E EH JIT
  largely done; 10.G GC JIT = interp-only (extreme effort, regalloc stack-map).
- **Step 0.7 on resume**: cyc206 (arm64 return_call_ref, code) kicks ubuntu @
  `5453141f` — verify next cycle (return_call_ref test is aarch64-gated, so x86_64
  skips it; ubuntu just confirms no regression). Prior: cyc205 `OK (HEAD=44d02873)` GREEN.

## Active task — x86_64 return_call_ref JIT + ungate (D-206)  **NEXT**

Mirror the call_ref-IT-2 pattern for return_call_ref's x86_64 half: (1) add
`emitReturnCallRef` to `x86_64/op_tail_call.zig` (mirror x86_64 `emitReturnCall`/
`emitIndirectReturnCall` tail-jump + `emitCallRef`'s funcref deref:
`OR r,r; JZ`-null → `MOV r,[funcref+funcentity_funcptr_offset]` → frame_teardown →
JMP); (2) de-stub `x86_64/ops/wasm_3_0/return_call_ref.zig` → delegate; (3) register
`x86_64_return_call_ref` in `dispatch_collector_ops` + bump the
`collected_x86_64_ctx_ops` count test (was 400); (4) UNGATE the runner
return_call_ref test (drop `skip.blocker(.@"D-206")` + the D-206 Blocker variant).
Then D-206's return_call_ref part is fully discharged (cross-module TC remains).
Smaller follow-ups: call_ref null-trap fixture (D-207); refresh stale 10.P SKIP
rationales (I14/I21 → D-192/D-179).

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
