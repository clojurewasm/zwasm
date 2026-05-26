# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24)
- **10.D = CLOSED 2026-05-25**.
- **10.M sub-chunks 1..fixture-2 = SHIPPED**.
- **10.R sub-chunks 1..5 = SHIPPED**.
- **10.TC-1 = SHIPPED** (`a83e095f`).
- **10.G-i31-ops / 10.G-2 / 10.G-3 = SHIPPED**.
- **10.E interp side = COMPLETE**.
- **10.E codegen IT-1..IT-5 = SHIPPED** (`c3424788`, `2d938570`,
  `466674b7`, `5b75bee5`, `14fafdc6`).
- **10.E IT-6 prep SHIPPED**: frame_bytes thread (`9ac268f1`),
  landing_pad_pc forward fixup (`18b2a077`), ADR-0119 draft
  (`e725bce7`), spike-validated flip to Accepted (`213df2f2`).
- **10.E IT-6 cycle 3a SHIPPED** (`14b32f74` + `0d099a41`):
  trampoline scaffolding under `shared/throw_trampoline.zig`.
- **10.E IT-6 cycle 3b SHIPPED** (`7c7169ad`): `op_throw` /
  `op_throw_ref` retargeted to BLR/CALL the trampoline (both archs).
- **10.E IT-6 cycle 3c-i SHIPPED** (`73c163d4`): JitRuntime gains
  `eh_table_entries` + `eh_table_count` + `eh_code_map_entries` +
  `eh_code_map_count`; setupRuntime wires from CompiledWasm.
- **10.E IT-6 cycle 3c-ii SHIPPED** (`6646e469`): trampoline body
  split into naked stub + `trampolineCore` (callconv .c Zig fn) per
  ADR-0119. End-to-end pipe naked-stub → core → `dispatchThrow` →
  unwind walk → trap_flag now exercised on Mac aarch64 + Linux SysV.
  Also fixed two latent test-fixture bugs (inverted AAPCS64 saved-LR
  semantics in `zwasm_throw` unwind tests).

## ROADMAP §10 progress

- DONE (7/13): 10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.T / 10.D
- IN-PROGRESS (4): 10.M (7/8) / 10.R (5/5; gated on 10.G) /
  10.TC (codegen + cross-module + spec corpus 残) /
  10.E (codegen IT-6 cycle 3c-iii 残)
- Pending (3): 10.G / 10.P (close gate)

## Active bundle

- **Bundle-ID**: `10.E-codegen-IT-6`
- **Cycles-remaining**: `~1` (cycle 3c-iii final handler dispatch)
- **Continuity-memo**: trampoline body, throw-site retargeting, and
  per-Instance EH data wiring are all in place. The `.handler`
  branch in `trampolineCore` currently traps as a placeholder;
  cycle 3c-iii implements actual handler dispatch:
  1. Restore SP via `sp_restore.emitSpRestoreFull` (arm64 +
     x86_64) at handler_fp's prologue boundary using frame_bytes.
  2. Resolve `landing_pad_pc` (module-relative) to absolute via
     `CodeMap.Entry.start_addr + landing_pad_pc`.
  3. JMP / BR to the absolute landing-pad address from
     `trampolineCore` (will require a small arch-shim helper
     since `trampolineCore` is regular Zig — likely a tiny per-
     arch `@extern(.naked)` thunk that takes (new_sp, target_pc)
     and never returns).
  4. Update the "handler found path" trampoline test to assert
     `trap_flag == 0` + observable landing-pad execution.
  5. Win64 trampoline body (currently `@compileError`) — fold in
     RCX/RDX/R8/R9 + shadow-space ABI shuffle.
- **Exit-condition**: end-to-end `throw 0 / catch_all 0` fixture
  compiles + runs + lands at the catch block (per integration
  plan §IT-6 acceptance).

## Open questions / blockers

- 10.G-4 (struct ops) — blocked-by GC heap impl
- 10.M-realworld — toolchain-blocked (clang_wasm64 fixture)
- 10.P close gate — user touchpoint by construction

## Key refs

- **ADR-0119 Accepted** (`213df2f2`,
  `.dev/decisions/0119_eh_trampoline_naked_zig.md`)
- **Spike** `private/spikes/p10-it6-naked-trampoline/` —
  Status: merged-into-prod.
- **Integration plan** (`.dev/phase10_eh_integration_plan.md`)
- **ADR-0114** (EH design — D6 specifies the trampoline shape)
- **ROADMAP §10**
- **Phase log** (`.dev/phase_log/phase10.md`)
- **Lesson** `2026-05-26-eh-codegen-foundation-atom-rhythm.md`
  (`e62db476`)
