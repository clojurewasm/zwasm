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
- **10.E codegen IT-1..IT-4 = SHIPPED**:
  - IT-1 (`c3424788`): EmitCtx.exception_table_builder wiring
  - IT-2 (`2d938570`): try_table emit body — HandlerEntry per
    catch, pc_end patched at matching `end`
  - IT-3 (`466674b7`): throw / throw_ref emit as unconditional
    trap (dispatcher CALL deferred to IT-6)
  - IT-4 (`5b75bee5`): linker populates per-Instance
    CodeMap entries on JitModule

## ROADMAP §10 progress

- DONE (7/13): 10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.T / 10.D
- IN-PROGRESS (4): 10.M (7/8) / 10.R (5/5; gated on 10.G) /
  10.TC (codegen + cross-module + spec corpus 残) /
  10.E (codegen integration IT-5..IT-6 残)
- Pending (3): 10.G / 10.P (close gate)

## Active task — Phase 10.E IT-5

Next continuous chunk picks up at **IT-5** per
`.dev/phase10_eh_integration_plan.md` §IT-5 — add an
`exception_table: ExceptionTable` field to `CompiledWasm`,
collecting the per-function `FuncResult.out.exception_handlers`
slices (already produced by IT-2) into a single per-Instance
table. Touchpoint: `src/engine/runner.zig` (CompiledWasm) +
`src/engine/compile.zig` (the compileWasm pipeline that
assembles CompiledWasm). Acceptance: a CompiledWasm built from
a try_table-containing module has
`exception_table.entries.len > 0`.

After IT-5: IT-6 (per-arch zwasm_throw trampoline glue) — the
load-bearing piece that makes throw actually call dispatchThrow
instead of trapping unconditionally.

## Open questions / blockers

- 10.G-4 (struct ops) — blocked-by GC heap impl
- 10.M-realworld — toolchain-blocked (clang_wasm64 fixture)
- 10.P close gate — user touchpoint by construction
- IT-2 HandlerEntry.landing_pad_pc currently holds the raw
  relative br-depth (placeholder); IT-6 resolves to a JIT
  byte offset
- IT-4 CodeMap.Entry.frame_bytes is a 0 placeholder; IT-6's
  SP-restore path populates it for handler dispatch

## Key refs

- **Integration plan** (`.dev/phase10_eh_integration_plan.md`) —
  IT-1..IT-6 (IT-1..IT-4 shipped; IT-5 next)
- **ADR-0114** (EH design)
- **ADR-0118** (`.dev/decisions/0118_meta_loop_consolidation.md`)
- **ROADMAP §10**
- **Phase log** (`.dev/phase_log/phase10.md`)
- **Lesson** `2026-05-26-eh-codegen-foundation-atom-rhythm.md`
  (`e62db476`)
