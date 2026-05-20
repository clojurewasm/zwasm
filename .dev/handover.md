# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_structural_debt_close_plan.md`](phase9_structural_debt_close_plan.md)
   (Status: Proposed 2026-05-20). この close-plan が
   `/continue` Step 1a の override を発火させ、ROADMAP
   §9.<N> task より先に §6 Work sequence を実行する。
   **D-153 / B159 以降の cross-module imports work には
   触らない** (close-plan §6 (j) まで凍結)。
2. **READ NEXT** [`.dev/lessons/2026-05-20-refactor-tradeoffs-honest-accounting.md`](lessons/2026-05-20-refactor-tradeoffs-honest-accounting.md) — 経緯記録。
3. `git log --oneline -10` — last code commit: `9beb73ca`
   (B158, validator_globals imports prefix). 以降は docs-
   only。
4. `bash scripts/p9_completion_status.sh` — live progress
   (cross-module imports 100 sites 不動)。
5. `.dev/debt.md::D-154` — close-plan umbrella row。

## Active state

- Phase 9.12-E。close-plan §6 work sequence 実行中。
- 完了: (a)〜(e)。直近 (e) で AssertTally 分割 — manifest
  `skip-impl` lines は実は 0 だった (旧 192 は runtime
  SKIP events だった)。Phase 9 完備 gate signal が見え
  るようになった。
- 次: **(f) skip-token taxonomy ADR** — 既存 SKIP-* token
  (V2-InstanceAllocFailed / VALIDATOR-GAP / PARSER-GAP /
  CROSS-MODULE-IMPORTS / NO-LINK-TYPECHECK /
  NON-INVOKE-ACTION / WASMTIME-UNUSABLE / NO-INSTANTIATE-CB)
  の class 定義 ADR (debt-trackable / ADR-required /
  runner-internal)。
- D-153 は close-plan §6 (j) まで凍結。

## §9.12-B progress chunks

`.dev/phase_log/p9_12_B_chunks.md` (B1〜B158 = 138 chunks)
に移管。handover はポインタのみ保持。chunk table 蓄積に
よる handover 肥大 (A1 / C5) を解消。

## Open questions / blockers

- §6 (i) Phase 9 exit redefinition ADR は user collab 必須
  (Phase 9 完備の意味を変える) — Proposed まで進めて stop。
- §6 (g) D-141 ADR は "blocked-by substrate audit Q3" を
  解除するため、substrate audit 文脈との整合性確認が user
  collab 推奨ポイント。

## See

- [ROADMAP](./ROADMAP.md) §9.12 — phase row
- [`debt.md`](./debt.md) — D-154 umbrella, D-153 paused
- [`lessons/INDEX.md`](./lessons/INDEX.md) — 2026-05-20 entry
