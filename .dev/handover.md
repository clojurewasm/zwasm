# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_completion_master_plan.md`](phase9_completion_master_plan.md)
   = Phase 9 completion master plan (v2; finalized). `§9.12-pre` is the next `[ ]` task.
2. `git log --oneline -10`. 2026-05-19 setup commit group: `bdd433d5` (ADR
   skeletons) + `31411280` (master plan + ROADMAP §9.12 sub-row expansion
   + handover + substrate audit doc) + `05377cf6` (enforcement scaffold) +
   `4259b6b6` (JA → EN translation) + cleanup commit (this commit).
3. `bash scripts/p9_simd_status.sh` — live SIMD status (13301/0/440 Mac+ubuntu
   bit-identical). non-simd live: 25325/0/688 via `zig build test-spec-wasm-2.0-assert`
   (193 skip-impl + 495 skip-adr).
4. `bash scripts/p9_completion_status.sh` (to be completed in §9.12-A; skeleton in this session)
   — live progress status for Phase 9 completion.
5. `.dev/debt.md` `now` rows: (none — all 6 prior `now` debts re-classified to `blocked-by: §9.12-X` since their discharge is embedded in §9.12-C / §9.12-E / §9.12-I work; see Step 0.5b live status).

## Active state — §9.9 [x]; §9.12 hard gate; next = §9.12-pre

- §9.9 + §9.9-II + §9.9-III all `[x]` (commits `a8af42e3` / `fb063b09` /
  `2dbd3f15`)
- §9.12 + sub-rows §9.12-pre / §9.12-A..I / §9.13-0 / §9.13 are now expanded
  in ROADMAP §9 (this session, commit 2).
- Phase Status widget: Phase 9 IN-PROGRESS (becomes DONE when §9.13 [x]).
- ADR skeletons (Proposed): 0070 / 0071 / 0072 / 0073; 0050 / 0023 amend
  Revision history (this session, commit 1).

## Next-session active task = §9.12-pre (autonomous)

ADR drafts + 3 spikes (`private/spikes/q3-*`). Exit: 6 ADRs fully drafted at
`Status: Proposed` (Context / Decision / Alternatives / Consequences / References
all populated) + 3 spike measurement reports → §9.12 collab gate fires (HARD;
suppress ScheduleWakeup + 1-sentence handoff).

### ADR drafts (skeleton → full)

| ADR | Skeleton land | Content to populate in §9.12-pre |
|---|---|---|
| 0071 (keystone) | this session | Q2 P14 sharpening + Q3 C adoption + Q4 boundary; details for Alternatives A/B/D-1 |
| 0070 (Q6 libc) | this session | full site inventory for necessary/replaceable/convenience |
| 0072 (Q5 comment) | this session | rule text + catalog of violation examples |
| 0073 (Q3 C DCE) | this session | 4 layer pattern details + 3 spike results |
| 0050 amend | this session | D-5 / D-6 full body |
| 0023 §4.5 amend | this session | per-op file pattern migration detail |

### 3 spike (`private/spikes/`)

| Spike | Measurement |
|---|---|
| `q3-zig-inline-switch/` | Zig 0.16 compile-time + IR size of a 581-tag `inline switch (op) { inline else => \|tag\| ... }`; whether it hits the quota wall |
| `q3-interp-dispatch-bench/` | Cycle difference between central `DispatchTable.interp[op]` indirect call vs zware `@call(.always_tail, lookup[op], ...)` |
| `q3-build-option-dce-poc/` | Implement representative op `i32.add` in the C pattern and verify symbol/size/test across 6 builds: `-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2}` |

## Outstanding upstream / Phase-10 blockers

- **D-148** (Zig 0.16 self-hosted x86_64 backend miscompile): blocked-by
  upstream; workaround `build.zig` `.use_llvm = true` continues. Watching
  Codeberg ziglang/zig#35343.
- D-079 / D-102 / D-103 / D-105: barrier cleared (`now`); discharge in §9.12-E
- D-133: included in the D-133 sweep in §9.12-C

### Discipline reminders

- No `--no-verify`. 2-host per chunk (Mac + ubuntunote).
- windowsmini waits until §9.13-0 (per ADR-0049).
- §9.12 hard gate: after §9.12-pre [x], suppress ScheduleWakeup + 1-sentence handoff.

## Sandbox + References

PRIMARY: [`phase9_completion_master_plan.md`](phase9_completion_master_plan.md)
(master plan v2).
Gate doc: [`phase9_completion_substrate_audit.md`](phase9_completion_substrate_audit.md)
(Q1-Q6 + tentative answers).
ADRs: [`0071`](decisions/0071_phase9_substrate_audit_resolution.md) (keystone),
[`0070`](decisions/0070_libc_dependency_policy.md),
[`0072`](decisions/0072_comment_as_invariant_rule.md),
[`0073`](decisions/0073_build_option_dce_substrate.md);
amends: [`0023`](decisions/0023_src_directory_structure_normalization.md),
[`0050`](decisions/0050_adr_lifecycle_and_skip_adr_enforcement.md).
Survey output (gitignored): `private/notes/p9-close-*.md`,
`private/notes/p9_close_master_plan_ja*.md`.
