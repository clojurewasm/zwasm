---
paths:
  - "src/**/*.zig"
  - ".dev/decisions/*.md"
  - "scripts/file_size_check.sh"
---

# File-size discipline: smell-detection, not metric satisfaction

> Lean stub (ADR-0118 D2). Full detail / conditions / examples: [`../references/file_size_smell.md`](../references/file_size_smell.md).

## Invariant

- **Soft cap 1000 = WARN** — smell detector, NOT a metric to drive to zero. Do NOT split just to silence the WARN.
- **Hard cap 2000 = BLOCK** — needs a split-ADR OR `// FILE-SIZE-EXEMPT: <specific rationale> (per ADR-NNNN)` on lines 1-5. Marker raises hard cap to **2500**. Vague rationales ("legacy"/"complex"/"later") rejected.
- A split needs **≥1 positive AND 0 negative**:
  - P1 spec-defined closed sub-language ≥300 LOC
  - P2 pure-data ≥40% file LOC
  - P3 independent change cadence + deep interface
  - P4 test-isolation (corroborating only)
  - N1 helper-circular import (test-block calls exempt)
  - N2 forced pub-leak of helper fn (OK only w/ SIBLING-PUB + P1)
  - N3 shallow module <100 LOC
  - N4 test-dup (>5 LOC body) or fixture pub-leak
- Tie-break: P1+N2-SIBLING-PUB → ACCEPT; P3+N1-type-only → ACCEPT; else REJECT/redesign.

## Enforcement

`bash scripts/file_size_check.sh --gate` (cap) + `scripts/check_split_smell.sh` (post-split smell).

## Key cases

- "Make this file ≤ 1000 lines" as a task description → re-state as "investigate the smell".
- No valid extraction → EXEMPT marker is the default outcome.
- Sub-100-LOC sibling extraction → almost always a shallow module (N3).

Full detail: [`../references/file_size_smell.md`](../references/file_size_smell.md).
