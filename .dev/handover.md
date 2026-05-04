# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0021_phase7_emit_split_gate.md` — §9.7 / 7.5d
   sub-gate (emit.zig split + byte-offset abstraction; hard gate
   before 7.6 x86_64 opens). Operationally amends ADR-0019.
3. `.dev/decisions/0019_x86_64_in_phase7.md` — Phase 7 covers ARM64
   + x86_64 baseline; Phase 8 redefined as optimisation foundation.
4. `.dev/decisions/0017_jit_runtime_abi.md` — JitRuntime ABI (X0
   = `*const JitRuntime`); D-014 dissolved.
5. `.dev/decisions/0018_regalloc_reserved_set_and_spill.md` —
   pool/reserved separation + first-class spill.
6. `.dev/decisions/0020_edge_case_test_culture.md` — boundary
   fixture culture + rule + audit hooks.
7. `.dev/decisions/0022_post_session_retrospective.md` — 2026-05-04
   regret triage + emit-split sub-gate; process improvements.
8. `.claude/skills/meta_audit/SKILL.md` — periodic deliberate-
   skepticism audit; user-gated; trigger conditions in
   `.claude/skills/audit_scaffolding/CHECKS.md §J`.
9. `.dev/debt.md` — discharge `Status: now` rows before active task.
10. `.dev/lessons/INDEX.md` — keyword-grep for active task domain.

## Current state — design + refactor cycle CLOSED

- **Phase**: Phase 7 IN-PROGRESS, scope per ADR-0019 + ADR-0021
  (ARM64 + x86_64 baseline both in Phase 7; §9.7 = 7.0..7.12 plus
  hard-gate row 7.5d).
- **Last session**: 2026-05-04 design + refactor + rules cycle
  (not /continue). User invoked discussion-first. Outputs:
  ADR-0021 + ROADMAP §9.7 row 7.5d + §15 bullet, `bug_fix_survey`
  rule, 5 lessons (regrets #1/2/3/7/10), 2 amendments to
  `edge_case_testing.md` (regrets #4/6), `src/jit_arm64/prologue.zig`
  helper + 4 demonstration sites (~128 sites bulk-migration sequenced
  under 7.5d sub-b), ADR-0022 retrospective.
- **Branch**: `zwasm-from-scratch`, **commits LOCAL** (not pushed
  — this session was not /continue; push requires user approval).

## Active plan — implementation cycles after ADR acceptance

| # | Step | ADR | Status |
|---|------|-----|--------|
| 1 | regalloc pool + first-class spill | 0018 | **DONE** |
| 2 | JitRuntime struct + ABI | 0017 | **DONE** |
| 3 | Edge-case test culture | 0020 | **DONE** |
| 4 | §9.7 / 7.5 spec testsuite via ARM64 JIT | — | 7.5a..7.5c-vi DONE; **7.5d sub-a PARTIAL** (`prologue.zig` helper landed + 4 demonstration sites + rule); 7.5d sub-b NEXT (emit.zig split per `.dev/lessons/2026-05-04-emit-monolith-cost.md`) — the ~128-site bulk relativisation runs alongside the split per ADR-0021 Revision history; 7.5c-vii (broader entry sigs) after 7.5d sub-b closes |
| 5 | §9.7 / 7.6 + 7.7 + 7.8: x86_64 reg_class/abi + emit + spec gate | 0019 | After 7.5d closes (HARD GATE per ADR-0021) |
| 6 | §9.7 / 7.9–7.12: realworld + three-way differential + audit | — | After Step 5 |

## Implementation notes for the next cycle (7.5d sub-b = emit.zig split)

- See `.dev/lessons/2026-05-04-emit-monolith-cost.md` for the
  proposed 9-module split target.
- Survey-derived split (this session): emit.zig orchestrator
  ≤ 1000 LOC; ops_const / ops_alu / ops_memory / ops_control
  (with D-027 Label.merge_top_vreg) / ops_call (≤ 300 LOC each);
  bounds_check / register / emit_helpers / label (≤ 120 LOC
  each).
- Test suite (1870 LOC) stays in emit.zig in this cycle; if the
  orchestrator + tests blow past 2000 LOC, move tests to
  `test/unit/jit_arm64/emit_test.zig`.
- Mutable state pattern: `&buf`, `&pushed_vregs`, `&labels`,
  `&bounds_fixups`, `&call_fixups`, `&next_vreg` thread through
  per-handler params; emit.zig orchestrates.

## Open structural debt

- **D-022** Diagnostic M3 / trace ringbuffer — sub-f trap surfaces
  exist; revisit after Phase 7 close.
- **D-026** env-stub host-func wiring — 4 embenchen + 1
  externref-segment skip-ADR'd; cross-module dispatch.
- emit.zig at 3989 LOC — §A2 violation surfaced this session;
  ADR-0021 row 7.5d-b discharges in next cycle.
- 3-host JIT asymmetry — Step 5 dissolves via ADR-0019.

## Recently closed (per `git log`)

- §9.7 / 7.3 op coverage CLOSED (111 ops total).
- §9.7 / 7.4a/b/c JIT runtime infra.
- ADRs 0017/0018/0019/0020 drafted, accepted.
- ADR-0021 sub-gate inserted; `src/jit_arm64/prologue.zig` helper
  + 4 demonstration test sites; ~128-site bulk migration sequenced
  under 7.5d sub-b alongside the emit.zig split.
- ADR-0022 retrospective recorded.
