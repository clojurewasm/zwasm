# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24)
- **Meta-pivot bundle SHIPPED 2026-05-26** (ADR-0118):
  `0b0a514d..2ce59032`.
- **10.D = CLOSED 2026-05-25**.
- **10.M sub-chunks 1..fixture-2 = SHIPPED**.
- **10.R sub-chunks 1..5 = SHIPPED**.
- **10.TC-1 = SHIPPED** (`a83e095f`).
- **10.G-i31-ops / 10.G-2 / 10.G-3 = SHIPPED**.
- **10.E interp side = COMPLETE**.
- **10.E codegen IT-1..IT-5 = SHIPPED**:
  - IT-1 (`c3424788`): EmitCtx.exception_table_builder
  - IT-2 (`2d938570`): try_table emit body + pc_end fixup
  - IT-3 (`466674b7`): throw / throw_ref as unconditional trap
  - IT-4 (`5b75bee5`): linker populates CodeMap entries
  - IT-5 (`14fafdc6`): CompiledWasm.exception_table aggregation
- **10.E IT-6 prep SHIPPED** (`9ac268f1`, `18b2a077`):
  - `9ac268f1`: frame_bytes threading EmitOutput → FuncBody →
    CodeMap.Entry (was IT-4 placeholder).
  - `18b2a077`: landing_pad_pc forward fixup at catch-label end
    (was IT-2 placeholder).

## ROADMAP §10 progress

- DONE (7/13): 10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.T / 10.D
- IN-PROGRESS (4): 10.M (7/8) / 10.R (5/5; gated on 10.G) /
  10.TC (codegen + cross-module + spec corpus 残) /
  10.E (codegen IT-6 残)
- Pending (3): 10.G / 10.P (close gate)

## Active bundle

- **Bundle-ID**: `10.E-codegen-IT-6`
- **Cycles-remaining**: `~2` (trampoline ADR + trampoline impl;
  landing_pad_pc + frame_bytes prep both shipped)
- **Continuity-memo**: with placeholders dissolved, the remaining
  work is the load-bearing trampoline — ADR-grade design choice
  (pure-Zig `naked` fn vs per-arch `.s` file, flagged in
  integration-plan §IT-6 "Open questions for user collab") +
  trampoline impl that replaces IT-3's unconditional-trap shape
  with a real CALL into `shared/zwasm_throw.dispatchThrow`.
- **Exit-condition**: end-to-end `throw 0 / catch_all 0` fixture
  compiles + runs + lands at the catch block (per integration
  plan §IT-6 acceptance).

Next /continue resume picks up the **trampoline-design ADR**
sub-task — draft `.dev/decisions/0119_<slug>.md` (or whichever
number is next) per `lessons_vs_adr.md` decision tree (this IS
load-bearing: it picks pure-Zig vs `.s` for every throw site,
rejects the other, and gates every downstream op_throw emit
rewrite). Spike option per `spike_discipline.md` §1 is
appropriate if the `naked`-fn semantics need empirical
validation against the Zig 0.16 codegen.

## Open questions / blockers

- 10.G-4 (struct ops) — blocked-by GC heap impl
- 10.M-realworld — toolchain-blocked (clang_wasm64 fixture)
- 10.P close gate — user touchpoint by construction
- IT-6 trampoline design (naked Zig vs `.s` file) — flagged
  user-collab in `.dev/phase10_eh_integration_plan.md` §IT-6
  "Open questions for user collab"; ADR (draft this cycle) is
  expected to surface for user review at flip time per §18.2

## Key refs

- **Integration plan** (`.dev/phase10_eh_integration_plan.md`)
- **ADR-0114** (EH design)
- **ADR-0118** (`.dev/decisions/0118_meta_loop_consolidation.md`)
- **ROADMAP §10**
- **Phase log** (`.dev/phase_log/phase10.md`)
- **Lesson** `2026-05-26-eh-codegen-foundation-atom-rhythm.md`
  (`e62db476`)
