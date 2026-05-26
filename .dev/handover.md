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
- **10.E codegen IT-1..IT-5 = SHIPPED**.
- **10.E IT-6 BUNDLE CLOSED** (`c9b9d16c`): end-to-end
  `(block (try_table (catch_all $b) (throw $e)) ...)` fixture in
  `src/engine/runner.zig` compiles + runs + lands at the catch
  block (returns 42), paired uncaught variant traps cleanly.
  Mac aarch64 + Linux x86_64 SysV both green at HEAD (2001/2015
  pass, 14 skip, 0 fail). 10.E codegen-side COMPLETE; Win64 EH
  trampoline body still `@compileError` (deferred).

## ROADMAP §10 progress

- DONE (8/13): 10.0 / 10.C9 / 10.J / 10.F / 10.Z / 10.T / 10.D /
  10.E (codegen-side; Win64 follow-on tracked below).
- IN-PROGRESS (3): 10.M (7/8) / 10.R (5/5; gated on 10.G) /
  10.TC (codegen + cross-module + spec corpus 残).
- Pending (2): 10.G / 10.P (close gate).

## Next candidates (names + Refs)

- **Win64 EH trampoline body** — `throw_trampoline.zig` x86_64-windows
  arm currently `@compileError`. Implement Win64 ABI arg shuffling
  (RCX/RDX/R8/R9 + shadow space) so the EH pipeline is fully cross-
  platform. Touches: arm64/x86_64 SysV are already green; this is
  Win64-only.
- **10.M-realworld** — toolchain-blocked (clang_wasm64 fixture);
  barrier in D-179 (wabt 1.0.41+ GC type syntax).
- **10.TC** — Wasm 3.0 spec corpus extension + cross-module EH
  fixtures. The naked-stub trampoline + handler dispatch pipeline
  now lets the EH spec subset (`exception-handling/try_table.wast`
  etc.) be run end-to-end; gap is wiring it into the spec runner.

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
- **ADR-0114** (EH design)
- **ROADMAP §10**
- **Phase log** (`.dev/phase_log/phase10.md`)
- **Lessons**:
  - `2026-05-26-eh-codegen-foundation-atom-rhythm.md` (`e62db476`)
  - `2026-05-28-eh-test-wrapper-host-fp-walk-segv.md`
    (sentinel-frame discipline → `test_discipline.md` §3)
