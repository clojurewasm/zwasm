---
paths:
  - "src/parse/**/*.zig"
  - "src/validate/**/*.zig"
  - "src/ir/**/*.zig"
  - "src/instruction/**/*.zig"
  - "src/runtime/**/*.zig"
  - "src/engine/codegen/**/*.zig"
  - "src/feature/**/*.zig"
---

# Spec citation discipline

> Lean stub (ADR-0118 D2). Full format / examples: [`../references/spec_citation.md`](../references/spec_citation.md) (→ `spec_citation_examples.md`).

## Invariant

A handler / validator / emitter routine implementing **spec-defined behaviour**
MUST carry a docstring line citing the spec section + op:
`/// Wasm spec §X.Y.Z (op-name) — <one-line summary>`. This anchors the
implementation to ground truth (P1: the Wasm spec is authoritative) and makes
divergence reviewable.

## Enforcement

Reviewer / comment-level discipline (no hard gate); `audit_scaffolding` can grep
`///` docstrings on spec-implementing routines for missing citations.

## Key cases

- Applies to parse / validate / ir-lower / instruction handlers / runtime /
  codegen-emit / feature subsystems (the `paths:` set).
- Not required for pure-internal helpers with no spec-defined behaviour.

Full format spec + examples: [`../references/spec_citation.md`](../references/spec_citation.md).
