---
paths:
  - "src/**/*.zig"
  - "build.zig"
---

# Zone Dependency Rules

> Lean stub (ADR-0118 D2). Full detail: [`../references/zone_deps.md`](../references/zone_deps.md).

## Invariant

Layering (lower ← higher; `↓` = may import below only):
**Zone 0** (`support/`, `platform/`) ← **Zone 1** (`ir/`, `runtime/`,
`parse/`, `validate/`, `instruction/`, `feature/`, `diagnostic/`) ←
**Zone 2** (`interp/`, `engine/`, `wasi/`) ← **Zone 3** (`cli/`, `api/`).

- **NEVER upward imports** — a zone MUST NOT `@import` from any zone above it.
- **NEVER cross-arch** — `engine/codegen/arm64/` ↔ `engine/codegen/x86_64/`
  MUST NOT import each other (A3); share via `engine/codegen/shared/` only.
- Lower-needs-higher → **VTable injection** (lower declares the type,
  higher installs fn-pointers at startup). Feature modules register into
  `src/ir/dispatch_table.zig`; core never `@import`s a specific feature.

## Enforcement

`bash scripts/zone_check.sh --gate` — exit 1 if violations exceed
in-script BASELINE (currently **0**). Scans `src/` only; `test/` exempt.
(`--strict` = exit 1 on any; bare = informational, exit 0.)

## Key cases

- Test exemption (D-017): in-source code after first `test "…"` or
  `const testing = std.testing` is skipped; all of `test/` is structural.
- Authoritative version of ROADMAP §4.1 / §A1 layering contract.

Full diagram, per-zone file lists, VTable code, test-exemption detail:
[`../references/zone_deps.md`](../references/zone_deps.md).
