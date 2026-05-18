# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_completion_master_plan.md`](phase9_completion_master_plan.md)
   (master plan v2; finalized). §9.12 = hard gate (next row).
2. **READ NEXT** [`.dev/phase9_completion_substrate_audit.md`](phase9_completion_substrate_audit.md)
   — Q1-Q6 with tentative answers ([T] marks). §9.12 collab review confirms
   each answer + flips the cited ADRs to `Accepted`.
3. ADRs ready for collab review (`Status: Proposed`):
   - [`0070`](decisions/0070_libc_dependency_policy.md) — Q6 libc policy + 16-site inventory.
   - [`0071`](decisions/0071_phase9_substrate_audit_resolution.md) — keystone (Q2/Q3/Q4 + ROADMAP §9.12 scope amend).
   - [`0072`](decisions/0072_comment_as_invariant_rule.md) — Q5 comment rule + violation catalog.
   - [`0073`](decisions/0073_build_option_dce_substrate.md) — all-layer build-option DCE substrate + 3 spike summaries.
   - [`0023`](decisions/0023_src_directory_structure_normalization.md) §4.5 amend — per-op file pattern (2026-05-19 Revision history row + dedicated subsection).
   - [`0050`](decisions/0050_adr_lifecycle_and_skip_adr_enforcement.md) amend — D-5 + D-6 (skip-impl ratchet substrate + pre-push gate).
4. Spike reports (gitignored; load-bearing conclusions absorbed into ADR-0073):
   - `private/spikes/q3-zig-inline-switch/` — 581-tag `inline switch` compile-time wall measurement (no wall hit).
   - `private/spikes/q3-build-option-dce-poc/` — DCE substrate end-to-end PoC (literal absence confirmed).
   - `private/spikes/q3-interp-dispatch-bench/` — dispatch shape cycle bench.

## Active state — §9.12-pre [x]; §9.12 HARD GATE active

- §9.12-pre `[x]` (this commit) — 4 new ADRs (0070/0071/0072/0073) + 2 amends
  (0023 §4.5 + 0050 D-5/D-6) populated; 3 spikes ran with measurement reports.
- §9.12 (🔒) — Phase 9 completion substrate re-examination = HARD GATE.
  Autonomous /continue loop must suspend; user-collaborative review session
  is required to flip the cited ADRs from `Proposed` → `Accepted` and to fill
  the `[T]` marks in `phase9_completion_substrate_audit.md` §Decisions.
- Phase Status widget: Phase 9 IN-PROGRESS (becomes DONE when §9.13 [x]).
  Widget wording update is deferred until §9.12 Accepts ADR-0071 (per master
  plan Chapter 6.2).

## Next session — depends on user direction at §9.12 collab gate

After §9.12 [x] flips, the autonomous loop resumes at §9.12-A (Scaffolding
compression + enforcement-layer construction; master plan Chapter 5.3 +
Chapter 7). The hard-gate detector in `.claude/skills/continue/SKILL.md`
§"Exception — hard human-in-loop transition gates" fires on the 🔒 marker
in §9.12; on next `/continue` invocation the loop will detect the gate and
re-surface unless §9.12 is already `[x]`.

## Outstanding upstream / Phase-10 blockers

- **D-148** (Zig 0.16 self-hosted x86_64 backend miscompile): blocked-by
  upstream; workaround `build.zig` `.use_llvm = true` continues. Watching
  Codeberg ziglang/zig#35343.
- D-079 / D-102 / D-103 / D-105: barrier cleared (`now`); discharge in §9.12-E.
- D-133: included in the D-133 sweep in §9.12-C.

### Discipline reminders

- No `--no-verify`. 2-host per chunk (Mac + ubuntunote); windowsmini deferred
  to §9.13-0 per ADR-0049.
- **HARD GATE active at §9.12**: NO ScheduleWakeup re-arm. Resumption is
  bucket-1 user intervention only.

## Sandbox + References

PRIMARY: [`phase9_completion_master_plan.md`](phase9_completion_master_plan.md)
(master plan v2).
Gate doc: [`phase9_completion_substrate_audit.md`](phase9_completion_substrate_audit.md)
(Q1-Q6 + tentative answers).
ADRs (Proposed, awaiting §9.12 Accept):
[`0071`](decisions/0071_phase9_substrate_audit_resolution.md) (keystone),
[`0070`](decisions/0070_libc_dependency_policy.md),
[`0072`](decisions/0072_comment_as_invariant_rule.md),
[`0073`](decisions/0073_build_option_dce_substrate.md).
Amends: [`0023`](decisions/0023_src_directory_structure_normalization.md) §4.5
+ [`0050`](decisions/0050_adr_lifecycle_and_skip_adr_enforcement.md) D-5/D-6.
Spike scratch (gitignored): `private/spikes/q3-{zig-inline-switch,build-option-dce-poc,interp-dispatch-bench}/`.
