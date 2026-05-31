---
paths:
  - "src/**/*.zig"
---

# No single slot serving two semantic axes

> Lean stub (ADR-0118 D2). Full detail / case study / examples: [`../references/single_slot_dual_meaning.md`](../references/single_slot_dual_meaning.md).

## Invariant

- A struct field MUST NOT carry two distinct semantic axes (two readers expecting **different** values from one slot). Split per-axis at design time, even when the values currently coincide.
- ROADMAP §14 forbidden pattern (per ADR-0014 §6.K.5).
- FORBIDDEN phrases in commit messages / ADR text:
  - "the same field is reused"
  - "for now we share `X`"

## Enforcement

Reviewer discipline — field-reading-path analysis during Step 4 Refactor / pre-commit (see reference).

## Key cases

- Case study: `Label.arity` vs `Label.branch_arity` — coincide for `block`/`if`, diverge for `loop` (one slot read by both `endOp` and `brOp`).
- `flags` byte where one bit's meaning depends on another → split into named bools / packed sub-struct.
- Opcode `payload: u32` as immediate AND typed-index AND offset → split into `payload` + `extra`.
- Genuinely-safe reuse = one axis (loop counter, switch enum tag); not a violation.

Full detail: [`../references/single_slot_dual_meaning.md`](../references/single_slot_dual_meaning.md).
