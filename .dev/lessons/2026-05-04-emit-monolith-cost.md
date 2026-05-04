---
name: emit-monolith-cost
description: emit.zig grew to 3989 LOC across Phase 7 sub-rows; should have split when crossing the §A2 soft cap (1000 LOC). Records the proposed 9-module split.
type: feedback
---

# emit.zig monolith cost — should have split at the soft cap

`src/jit_arm64/emit.zig` reached **3989 LOC** across Phase 7 sub-
rows 7.0..7.5c-vi without a refactor cycle. It crossed §A2 soft
cap (1000 LOC) around sub-7.3 and the hard cap (2000 LOC) by
sub-7.4, but no audit fired. The monolith was discovered at the
2026-05-04 retrospective when re-reading ADR-0019's "two emit.zig
files" clause.

## Proposed 9-module split (load-bearing for §9.7 / 7.5d sub-b)

| Module                    | Scope                                                       | LOC est. |
|---------------------------|-------------------------------------------------------------|----------|
| `emit.zig` (orchestrator) | dispatcher + prologue/epilogue + trap stub + main loop      | ≤ 1000   |
| `ops_const.zig`           | i32/i64/f32/f64 const handlers + multi-lane MOV emission    | ≤ 200    |
| `ops_alu.zig`             | i32/i64 ALU, comparisons, shifts, eqz, clz, ctz, popcnt     | ≤ 250    |
| `ops_memory.zig`          | load/store all widths + memory.size/grow + bounds prologue  | ≤ 200    |
| `ops_control.zig`         | block/loop/br/br_table/if/else/end + D-027 merge logic       | ≤ 350    |
| `ops_call.zig`            | call + call_indirect + arg/result marshaling                | ≤ 200    |
| `bounds_check.zig`        | emitTrunc32BoundsCheck + emitTrunc64BoundsCheck             | ≤ 100    |
| `register.zig`            | resolveGpr + resolveFp + spill load/store helpers           | ≤ 100    |
| `emit_helpers.zig`        | writeU32 + emitConstU32/U64 + prologue/epilogue encoders    | ≤ 150    |
| `label.zig`               | Label struct + LabelKind + Fixup + FixupKind + merge_top_vreg | ≤ 50    |

Test suite (1870 LOC) stays in emit.zig in the first split; if
that pushes orchestrator + tests over 2000 LOC, move tests to
`test/unit/jit_arm64/emit_test.zig`.

## Cross-cutting concerns to thread

`&buf` / `&pushed_vregs` / `&labels` / `&bounds_fixups` /
`&call_fixups` / `&next_vreg` thread through per-handler params;
emit.zig orchestrates ownership. D-027 `Label.merge_top_vreg`
stays cohesive in `ops_control.zig` (don't fragment if/else/end
across files).

**Citing**: ADR-0021 row 7.5d-b (the load-bearing gate this
lesson supports).
