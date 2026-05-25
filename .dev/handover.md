# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24)
- **Meta-pivot bundle SHIPPED 2026-05-26** (ADR-0118):
  `0b0a514d..2ce59032`.
- **10.D = CLOSED 2026-05-25**: 全 7 ADR (0111-0117) Accepted.
- **10.M sub-chunks 1..fixture-2 = SHIPPED**.
- **10.R sub-chunks 1..5 = SHIPPED**.
- **10.TC-1 = SHIPPED** (`a83e095f`).
- **10.G-i31-ops / 10.G-2 / 10.G-3 = SHIPPED**.
- **10.E interp side = COMPLETE**.
- **10.E codegen IT-1..IT-3 bundle COMPLETE** (`c3424788`,
  `2d938570`, `466674b7`): EmitCtx.exception_table_builder
  wiring; try_table.emit populates HandlerEntry per catch with
  pc_end patched at matching `end`; throw / throw_ref emit as
  unconditional trap (full dispatcher CALL deferred to IT-6).
  `EmitOutput.exception_handlers` carries the per-function
  slice for IT-5 to fold into CompiledWasm.

## ROADMAP §10 progress

- DONE (7/13): 10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.T / 10.D
- IN-PROGRESS (4): 10.M (7/8) / 10.R (5/5; gated on 10.G) /
  10.TC (codegen + cross-module + spec corpus 残) /
  10.E (codegen integration IT-4..IT-6 残)
- Pending (3): 10.G / 10.P (close gate)

## Active task — Phase 10.E IT-4..IT-6

Next continuous chunk picks up at **IT-4** per
`.dev/phase10_eh_integration_plan.md` §IT-4 — populate the
per-Instance `CodeMap.Builder` at JIT link time so the FP-walk
unwinder can normalize an absolute PC into `(func_idx,
relative_pc)`. Touchpoint: `src/engine/codegen/shared/compile.zig`
(or wherever per-function start addrs are assigned post-emit).
Acceptance: `code_map.lookup(any_addr_in_func_N)` returns
`.inside { relative_pc, func_idx = N }`.

After IT-4: IT-5 (CompiledWasm.exception_table field — collect
per-function `EmitOutput.exception_handlers` into a per-Instance
ExceptionTable); IT-6 (per-arch zwasm_throw trampoline glue, the
load-bearing piece that makes throw actually call dispatchThrow
instead of trapping unconditionally).

IT-4..IT-6 may merit a fresh `## Active bundle` if the next
session intends multi-cycle continuity.

## Open questions / blockers

- 10.G-4 (struct ops) — blocked-by GC heap impl
- 10.M-realworld — toolchain-blocked (clang_wasm64 fixture)
- 10.P close gate — user touchpoint by construction
- IT-2 HandlerEntry.landing_pad_pc currently holds the raw
  relative br-depth (placeholder); IT-4 / IT-6 resolve to a JIT
  byte offset

## Key refs

- **Integration plan** (`.dev/phase10_eh_integration_plan.md`) —
  IT-1..IT-6 (IT-1..IT-3 shipped; IT-4 next)
- **ADR-0114** (EH design)
- **ADR-0118** (`.dev/decisions/0118_meta_loop_consolidation.md`)
- **ROADMAP §10**
- **Phase log** (`.dev/phase_log/phase10.md`)
- **Lesson** `2026-05-26-eh-codegen-foundation-atom-rhythm.md`
  (`e62db476`)
