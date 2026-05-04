---
name: emit-monolith-cost
description: emit.zig grew to 3989 LOC across Phase 7 sub-rows; should have split when crossing the §A2 soft cap (1000 LOC). Records the proposed 9-module split.
type: feedback
---

# emit.zig monolith cost — should have split at the soft cap

`src/jit_arm64/emit.zig` reached **3989 LOC** across Phase 7
sub-rows 7.0..7.5c-vi without a refactor cycle. The file
crossed §A2 soft cap (1000 LOC) somewhere around sub-7.3 (op
coverage) and crossed the §A2 hard cap (2000 LOC) by the end
of sub-7.4 (runtime infra). No audit fired during these
boundaries; the monolith was discovered at the 2026-05-04
design retrospective when ADR-0019's "two emit.zig files"
clause was re-read.

## Why this matters (load-bearing for next cycle)

ADR-0021 inserts §9.7 / 7.5d as a hard gate before x86_64 emit
work opens. The split target is documented here so the next
/continue cycle has a concrete blueprint, not a "go figure it
out" task.

## Proposed split (9 modules)

| Module                          | Scope                                                       | LOC est. |
|---------------------------------|-------------------------------------------------------------|----------|
| `emit.zig` (orchestrator)       | dispatcher + prologue/epilogue + trap stub + main loop      | ≤ 1000   |
| `ops_const.zig`                 | i32/i64/f32/f64 const handlers + multi-lane MOV emission    | ≤ 200    |
| `ops_alu.zig`                   | i32/i64 ALU, comparisons, shifts, eqz, clz, ctz, popcnt     | ≤ 250    |
| `ops_memory.zig`                | load/store all widths + memory.size/grow + bounds prologue  | ≤ 200    |
| `ops_control.zig`               | block/loop/br/br_table/if/else/end + D-027 merge logic       | ≤ 350    |
| `ops_call.zig`                  | call + call_indirect + arg/result marshaling                | ≤ 200    |
| `bounds_check.zig`              | emitTrunc32BoundsCheck + emitTrunc64BoundsCheck             | ≤ 100    |
| `register.zig`                  | resolveGpr + resolveFp + spill load/store helpers           | ≤ 100    |
| `emit_helpers.zig`              | writeU32 + emitConstU32/U64 + prologue/epilogue encoders    | ≤ 150    |
| `label.zig`                     | Label struct + LabelKind + Fixup + FixupKind + merge_top_vreg | ≤ 50    |

Test suite (1870 LOC) stays in emit.zig in the first split. If
that pushes orchestrator + tests over 2000 LOC, move tests to
`test/unit/jit_arm64/emit_test.zig` in a follow-up.

## Cross-cutting concerns to handle

1. **Mutable buffer + dynamic fixup patching** — pass `&buf` to
   each handler; emit.zig orchestrates ownership.
2. **Label stack lifetime** — `&labels: *ArrayList(Label)`
   threaded through; ops_control owns the read/write logic.
3. **Spill base offset** — computed once in prologue; threaded
   to ops needing it.
4. **next_vreg counter** — `&next_vreg: *u32` shared.
5. **D-027 `merge_top_vreg`** — stays in `Label` struct
   (label.zig); capture/resolve logic stays cohesive in
   ops_control.zig (don't fragment if/else/end across files).

## Why I'm writing this as a lesson, not an ADR

The split itself is a refactor, not a load-bearing decision. The
load-bearing piece (when to split, what triggers the gate) is
ADR-0021. This lesson captures the proposed shape so the
implementation isn't re-derived from scratch in the next cycle.

## How to apply

When the next /continue cycle picks up §9.7 / 7.5d sub-deliverable
b: read this lesson first; the survey is done. Implementation =
mechanical reorg + import-graph updates.

## Citing

- ADR-0021 row 7.5d-b (the load-bearing gate this lesson
  supports)
- emit.zig responsibility survey (in-context, 2026-05-04 design
  session)
