# Adding a TrapKind variant breaks test-all-only runner switches (Mac `zig build test` blind spot)

**Date**: 2026-06-06 · **Context**: D-293 slice-4a — appended
`null_reference`/`cast_failure`/`uncaught_exception` to `api.trap_surface.TrapKind`.

Mac per-task gate (`zig build test`) was GREEN, but the ubuntu `test-all` gate
FAILED to build: `test/runners/wast_runtime_runner.zig:967 error: switch must
handle all possibilities` — `trapKindName(k: TrapKind)` is an **exhaustive
switch with no `else`**, and `zig build test` does NOT compile the test-all-only
runner executables (only `test-all` builds them). So a public-enum widening that
a runner switches on exhaustively is invisible to the per-task gate.

## Rule

- Widening a public enum that lives at a surface (`TrapKind`, `ValType`, `ZirOp`,
  `ExternKind`, …) → grep for **exhaustive switches in `test/runners/`** (not just
  `src/`), which Mac `zig build test` skips: `rg -n 'switch \(.*\)' test/runners/`.
- Cheap local catch BEFORE push: `zig build test-runtime-runner-smoke` (seconds —
  compiles + runs `wast_runtime_runner` on the smoke fixture). It would have caught
  this without the ~5-min ubuntu round-trip.
- This is the **D-228 family** (`test-all ⊉ test`): a target/coverage gap, not an
  OS-conditional one (cf. `cross-compile-is-not-cross-run`,
  `windowsmini-reconciliation-catches-os-only-compile-drift`). The always-on ubuntu
  `test-all` (ADR-0076 D6) is the backstop that caught it; forward-fix (add the arms),
  don't revert.
