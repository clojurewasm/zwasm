# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_completion_close_plan.md`](phase9_completion_close_plan.md)
   = Phase 9 完備 マスター計画書 (v2; 確定稿)。`§9.12-pre` が次の `[ ]` task。
2. `git log --oneline -10`. 2026-05-19 setup commit 群: `15df00bd` (ADR
   skeletons) + commit 2 (master plan + ROADMAP §9.12 sub-row expansion +
   handover + substrate audit doc) + commit 3 (enforcement scaffold).
3. `bash scripts/p9_simd_status.sh` — live SIMD 状態 (13301/0/440 Mac+ubuntu
   bit-identical)。non-simd live: `zig build test-spec-wasm-2.0-assert` で
   25325/0/688 (193 skip-impl + 495 skip-adr)。
4. `bash scripts/p9_completion_status.sh` (§9.12-A で完成、本セッション skeleton)
   — Phase 9 完備の progress live status。
5. `.dev/debt.md` `now` rows: D-079 / D-102 / D-103 / D-105 / D-133 / D-149。

## Active state — §9.9 [x]; §9.12 hard gate; next = §9.12-pre

- §9.9 + §9.9-II + §9.9-III all `[x]` (commits `a8af42e3` / `fb063b09` /
  `2dbd3f15`)
- §9.12 + サブ行 §9.12-pre / §9.12-A〜I / §9.13-0 / §9.13 が ROADMAP §9 に
  展開済み (本セッション commit 2)。
- Phase Status widget: Phase 9 IN-PROGRESS (§9.13 [x] で DONE)。
- ADR skeletons (Proposed): 0070 / 0071 / 0072 / 0073; 0050 / 0023 amend
  Revision history (本セッション commit 1)。

## Next-session active task = §9.12-pre (autonomous)

ADR drafts + 3 spike (`private/spikes/q3-*`)。Exit: 6 ADR が `Status: Proposed`
で full draft 化 (Context / Decision / Alternatives / Consequences / References
全部 populate) + 3 spike measurement report → §9.12 collab gate fire (HARD;
ScheduleWakeup 抑止 + 1 文 handoff)。

### ADR drafts (skeleton → full)

| ADR | Skeleton land | §9.12-pre で populate する内容 |
|---|---|---|
| 0071 (keystone) | 本セッション | Q2 P14 sharpening + Q3 C 採用 + Q4 boundary; Alternatives A/B/D-1 詳細 |
| 0070 (Q6 libc) | 本セッション | necessary/replaceable/convenience 全 site 一覧 |
| 0072 (Q5 comment) | 本セッション | rule text + 違反例カタログ |
| 0073 (Q3 C DCE) | 本セッション | 4 layer pattern 詳細 + 3 spike 結果 |
| 0050 amend | 本セッション | D-3 / D-4 full body |
| 0023 §4.5 amend | 本セッション | per-op file pattern 移行 detail |

### 3 spike (`private/spikes/`)

| Spike | 計測 |
|---|---|
| `q3-zig-inline-switch/` | 581-tag `inline switch (op) { inline else => \|tag\| ... }` の Zig 0.16 compile-time + IR size; quota wall に当たるか |
| `q3-interp-dispatch-bench/` | 中央 `DispatchTable.interp[op]` 間接 call vs zware `@call(.always_tail, lookup[op], ...)` の cycle 差 |
| `q3-build-option-dce-poc/` | 代表 op `i32.add` を C パターンで実装し `-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2}` 6 build で symbol/size/test 確認 |

## Outstanding upstream / Phase-10 blockers

- **D-148** (Zig 0.16 self-hosted x86_64 backend miscompile): blocked-by
  upstream; workaround `build.zig` `.use_llvm = true` 継続。Codeberg
  ziglang/zig#35343 監視。
- D-079 / D-102 / D-103 / D-105: barrier 解消済み (`now`); §9.12-E で discharge
- D-133: §9.12-C で D-133 sweep に含む

### Discipline reminders

- No `--no-verify`. 2-host per chunk (Mac + ubuntunote)。
- windowsmini は §9.13-0 まで待機 (per ADR-0049)。
- §9.12 hard gate: §9.12-pre [x] 後、ScheduleWakeup 抑止 + 1 文 handoff。

## Sandbox + References

PRIMARY: [`phase9_completion_close_plan.md`](phase9_completion_close_plan.md)
(マスター計画書 v2)。
Gate doc: [`phase9_completion_substrate_audit.md`](phase9_completion_substrate_audit.md)
(Q1-Q6 + tentative answers)。
ADRs: [`0071`](decisions/0071_phase9_substrate_audit_resolution.md) (keystone),
[`0070`](decisions/0070_libc_dependency_policy.md),
[`0072`](decisions/0072_comment_as_invariant_rule.md),
[`0073`](decisions/0073_build_option_dce_substrate.md);
amends: [`0023`](decisions/0023_src_directory_structure_normalization.md),
[`0050`](decisions/0050_adr_lifecycle_and_skip_adr_enforcement.md)。
Survey 出力 (gitignored): `private/notes/p9-close-*.md`,
`private/notes/p9_close_master_plan_ja*.md`。
