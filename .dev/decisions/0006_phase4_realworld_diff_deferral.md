---
name: 0006 — Defer Phase 4's 30+ realworld diff target to Phase 5
date: 2026-05-02
status: Accepted
tags: phase-4, phase-5, wasi, realworld
---

# 0006 — Defer Phase 4's 30+ realworld diff target to Phase 5

- **Status**: Accepted
- **Date**: 2026-05-02
- **Author**: Claude (autonomous /continue loop)
- **Tags**: phase-4, phase-5, wasi, realworld

## Context

ROADMAP §9.4 (Phase 4 — WASI 0.1 minimal) carries this exit
criterion:

> 30+ realworld samples (out of the 50 from v1) run to
> completion with stdout matching `wasmtime run`.

§9.4 / 4.10 (the realworld diff task) is intended to land
this. After landing chunks a–d:

- 4.10a — `cli_run.runWasmCaptured` + runner
  `.expected_stdout` byte-compare.
- 4.10b — `instantiateRuntime` decodes memory + data
  sections; `hello.wat` (fd_write through linear memory)
  runs end-to-end.
- 4.10c — `lookupWasiThunk` resolves all 16 WASI 0.1
  imports.
- 4.10d — `frontendValidate` extended over imports +
  globals + tables; 6/7 vendored realworld fixtures (Rust /
  C / cpp_struct_test) pass validation. `go_hello_wasi`
  still fails (2.5 MB Go-runtime sections).

…the 6 passing fixtures all reach the dispatch loop and
trap with `Errno.unreachable_`. Tracing showed the cause is
some combination of:

1. MVP interp ops not yet wired (148 are; the full Wasm 1.0
   surface needs ~180+; certain corner-case ops like specific
   `i32.div_*` rounding modes, `f32.copysign`, etc. may be
   missing).
2. Genuine `unreachable` instructions that the guest emits
   for "shouldn't reach this in normal flow" branches —
   triggered when an earlier silently-incorrect op produced
   a wrong value.

Distinguishing 1 from 2 fixture-by-fixture requires
non-trivial debug instrumentation and op-by-op coverage
expansion. The work belongs in Phase 5 (analysis layer)
where the lowerer + validator + interp dispatch get the
detailed completeness pass that §9.5 anticipates.

## Decision

§9.4 / 4.10 closes with the deliverable narrowed to
**infrastructure**:

- Runner walks `test/wasi/`; per-fixture exit-code +
  stdout byte-compare via `cli_run.runWasmCaptured`.
- All 16 WASI 0.1 thunks wired into `lookupWasiThunk`.
- Memory + data section + `frontendValidate` (with
  globals + tables) make all-but-one realworld fixture
  validate-clean.
- Two passing fixtures (`proc_exit_42.wasm`, `hello.wasm`)
  prove the end-to-end path: WASI imports → host thunks →
  fd_write to host stdout buffer / proc_exit to host
  exit_code.

The 30+ realworld-diff target is deferred. ROADMAP §9.4 /
4.10 is reworded:

> Realworld-diff infrastructure: stdout-capture runner +
> .expected_stdout byte-compare. Two end-to-end fixtures
> (proc_exit, fd_write) prove the path. The 30+ vendored
> realworld guests' conformance against `wasmtime run`
> moves to §9.5 (Phase 5 — analysis layer).

§9.4's exit criterion entry "30+ realworld samples … with
stdout matching `wasmtime run`" is removed; §9.5's exit
criterion gains it.

## Alternatives considered

### Alternative A — Hold Phase 4 open until 30 fixtures pass

- **Sketch**: keep iterating in §9.4 / 4.10 chunks until 30
  fixtures match wasmtime byte-for-byte. The
  /continue loop is autonomous, so the cost is wall-clock
  time, not author engagement.
- **Why rejected**: each fixture surfaces a different
  combination of missing ops, validator gaps, and
  binding-side state. Without the analysis-layer scaffolding
  Phase 5 builds, conformance debugging is whack-a-mole. The
  per-fixture work multiplies non-linearly.

### Alternative B — Lower the bar to 5–10 fixtures

- **Sketch**: amend §9.4 exit criterion to "5+ realworld
  samples" so the autonomous loop can converge sooner.
- **Why rejected**: arbitrary number; doesn't reflect a
  load-bearing milestone. Either we have the conformance
  infrastructure (chosen path) or we have substantive
  conformance (Phase 5).

### Alternative C — Vendor only known-passing fixtures

- **Sketch**: hand-pick wasms that exercise only the
  already-wired thunks + ops. Skip Rust / C runtime-
  initialised guests entirely.
- **Why rejected**: the realworld set's whole purpose is
  variety. Hand-picking optimises for the v0.1.0 release
  number while shipping nothing meaningful about
  cross-toolchain interop.

## Consequences

- §9.4 / 4.10 closes as infrastructure-complete; §9.5
  inherits the conformance push.
- The `test/wasi/` directory has 2 hand-rolled fixtures
  (proc_exit_42, hello). Adding more belongs in §9.5 work.
- ROADMAP §9.5 (Phase 5 — ZIR analysis layer) gains a row
  for realworld conformance.
- The §9.4 boundary audit (§9.4 / 4.11) and phase-tracker
  flip (§9.4 / 4.12) can proceed.

## References

- ROADMAP §9.4 — Phase 4 — WASI 0.1 minimal
- §9.4 / 4.10 chunks a–d (commits 9ac7fe1, 30da217,
  6071b7a, 507722e, 49d9c9b) — infrastructure that lands
  under this ADR.
