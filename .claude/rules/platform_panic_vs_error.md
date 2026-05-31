---
paths:
  - "src/engine/codegen/**/*.zig"
  - "src/platform/**"
  - "src/runtime/**"
  - "src/api/**"
  - "src/wasi/**"
---

# Platform-conditional gaps: `@panic` over widening shared `Error`

> Lean stub (ADR-0118 D2). Full detail: [`../references/platform_panic_vs_error.md`](../references/platform_panic_vs_error.md).

## Invariant

A comptime-pruned platform-only `else` branch **MUST NOT** add a variant
to a SHARED `Error` set just to give the branch something to return —
phantom variants force every exhaustive `switch (err)` caller to widen.
Instead use, in order: **`@panic("<msg> (D-NNN)")`** (default) OR a
**function-local error set** (`(Error || error{X})!T`, only when caller
recovery is meaningful) OR **`@compileError`** (only when reaching the
branch is itself a bug).

## Enforcement

Reviewer checklist (Step 4 / pre-commit): if diff adds an `Error`
variant returned from a `comptime builtin.target.*` else-branch, run
`rg -nE 'switch \(err\)' src/ test/` — any caller arm added → API
pollution, use `@panic`. Cross-compile before push:
`zig build -Dtarget=x86_64-windows-gnu` (+ `x86_64-linux-gnu`,
`aarch64-macos`) — MinGW catches ~90% of Win64 exhaustive-switch issues.

## Key cases

- Default for "not implemented on this platform yet" = `@panic`;
  caller-side recovery is the exception.
- Same trap for any shared `Error` across `runtime/`, `api/`, `parse/`.
- Case study: commit `4ec3f4cb` (added variant → 4 caller breaks) vs
  `0c2474c2` (redo with `@panic`, zero caller change).

Full options, detection pattern, checklist, case study:
[`../references/platform_panic_vs_error.md`](../references/platform_panic_vs_error.md).
