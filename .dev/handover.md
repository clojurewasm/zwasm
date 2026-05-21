# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10` — most recent code-affecting commit
   is the D-159+D-160 discharge pair (`799b9b10` + `65e79aa1`,
   ubuntu OK). Latest cycle: ADR-0094 Proposed (SIBLING-PUB
   marker + audit grep for cross-file struct-method extraction;
   D-158 design phase).
2. **User directive (2026-05-21)**: batch-session architectural
   mode — Phase 9 closure quality. ADR-0094 implementation
   cycle is the next action (D-158 discharge).
3. **Live status**: `bash scripts/p9_completion_status.sh`.

## Active `now` debts

- **D-158** (ADR-0094 Proposed; impl cycle next): cross-file
  private boundary in Zig 0.16 — Validator/Lowerer/op_control_
  merge_mov pub-surface leak from ADR-0083/0089/0093. Design
  chose **SIBLING-PUB marker + audit grep**. Implementation
  cycle deliverables: (1) `scripts/check_sibling_pub.sh`
  (gate+info modes), (2) marker application to 5 leak sites,
  (3) audit_scaffolding §F extension, (4) gate_commit.sh
  integration, (5) lesson update. **Still blocks further
  struct-method extraction until impl cycle lands.**
- **D-055** (mechanical, multi-cycle): ~95 hardcoded
  byte-offset sites in x86_64 `emit_test_int.zig` /
  `emit_test_float.zig` migrate to `prologue.body_start_offset()`-
  relative pattern + wire `inst.encMovMemDisp32Imm32` call.
  Barrier dissolved 2026-05-21; mechanical work remains.

## Authorized next-session pickup (priority order)

1. **ADR-0094 implementation cycle** (D-158 discharge):
   `scripts/check_sibling_pub.sh` design + 5 marker
   applications + audit_scaffolding §F + gate_commit
   integration + lesson update. Architectural chunk.
2. **Remaining D-141 candidates — all need ADR-grade survey
   (NOT single-cycle mechanical)**:
   - `parse/sections.zig` (1556 LOC) — per-section vs Wasm-
     version-cohort split vs FILE-SIZE-EXEMPT marker.
   - `api/instance.zig` (1431 LOC) — c_api lifecycle redesign.
   - `engine/compile.zig` (1225 LOC) — compileWasm phased
     sub-fn split.
   - `regalloc.zig` (1529 LOC after ADR-0090) — compute/verify/
     vreg-class axis split.
3. **D-055 discharge** (independent, multi-cycle mechanical).
4. **§9.12-G `src/api/instance.zig` split** (per c_api lifecycle).
5. **§9.12-H bench baseline** (Mac Wasm 2.0 + wasmtime).
6. **§9.12-I ADR/lesson curation closure**.

## Active state (snapshot)

- **§9.12-A enforcement**: 9 items OK; gate_commit + pre-push
  audit gates active. §9.12-E [x] at `7b2e1b02`.
- **ADR-0078 fully load-bearing**: G.1.1 + G.1.2 + amendment.
- **§9.12-G partial**: 41 Wasm 3.0 stubs landed; dispatcher
  comptime-reject; CLI --invoke.
- **§9.12-F**: 11 D-141 slots closed in 2026-05-21 session.
  ADRs 0079+0081+0082+0083+0084+0085+0086+0087+0088+0089+0090
  Accepted. 3 lessons captured.

## Pattern menu (next-session reference)

| Pattern | When applicable | Examples |
|---|---|---|
| Pure-data re-export | One block > 40% LOC, no methods, no state | ADR-0082, 0086, 0087, 0088, 0090 |
| Pure top-level helper | 3+ standalone helpers, no callers, simple imports | ADR-0079, 0081, 0085 |
| Cross-file struct method | Struct-method-heavy file with SIMD or other clean axis | ADR-0083, 0089 |
| Per-caller migration | N independent symbols, 100+ caller sites | ADR-0084 |

See lesson `2026-05-21-pure-data-extraction-via-reexport.md`
survey checklist before drafting the next per-file ADR.

## Operational note for the batch-session loop

`/continue` resume Steps 0-7 apply per cycle. Granularity
`architectural`. Soft cap is a smell not a constraint per
user direction (意味があるならハードキャップ無視可). Remaining
work needs survey-first discipline.

## Open questions / blockers

- なし。Mechanical-extraction sweep complete; D-158 needs
  ADR investigation before further struct-method extraction.

## See

- [ROADMAP](./ROADMAP.md) §9.12 — F (D-141 sweep partial) / G / H / I open.
- [`debt.md`](./debt.md) — 26 active rows.
- [`decisions/0094_sibling_pub_marker_for_cross_file_struct_methods.md`](./decisions/0094_sibling_pub_marker_for_cross_file_struct_methods.md)
  — Proposed; D-158 design phase.
- [`decisions/0075_x86_64_emitctx_ctx_passing_unification.md`](./decisions/0075_x86_64_emitctx_ctx_passing_unification.md)
  — amended Consequences (D-160 discharge).
- [`lessons/INDEX.md`](./lessons/INDEX.md).
