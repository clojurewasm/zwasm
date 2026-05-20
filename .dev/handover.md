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

- Phase 9.12-E。close-plan §6 (j) direct-implementation 進行中。
- ADR-0080 → Rejected (`dc07b79`)。spectest を `.wat` で
  auto-register する v1/wazero 方式を採用。
- §6 (j) Step A 完了 (`f5b3f62`): test/spec/spectest.wat +
  build.zig wat2wasm step + @embedFile route。
  Mac: runtime-skip 192 → 80、新規 43 failures surface。
- 次: **§6 (j) Step B cohort 1 — UnsupportedEntrySignature × 21**。

## Step B 即実行手順 (cold-start から再開時)

```sh
# 1. ログ再生 (前回の /tmp/spec-spike2.log は揮発するため)
zig build test-spec-wasm-2.0-assert > /tmp/spec.log 2>&1
grep "^FAIL " /tmp/spec.log | sort | head -30
grep "UnsupportedEntrySignature" /tmp/spec.log | head -20

# 2. 仮説検証 — どの export が呼ばれた直後に出るか trace
#    `init` 文字列を含む FAIL のコンテキスト周辺を読む。
#    例: "imports data-init: UnsupportedEntrySignature"
#    → imports.wast の data-init 直前の `(invoke ...)` を確認。
grep -B 5 -A 2 "UnsupportedEntrySignature" /tmp/spec.log | head -50
```

調査開始ファイル:
- `src/runtime/entry.zig` — entry helper の signature dispatch
  table (callI32NoArgs / callI32_i32 / ...)。missing signature
  cases を grep。
- `test/spec/spec_assert_runner_base.zig::routeAssertReturn`
  系 — どこから UnsupportedEntrySignature が raise される
  か確認。
- 該当 fixture: `test/spec/wasm-2.0-assert/imports/imports.NN.wat`
  (`grep "imports/imports\\." /tmp/spec.log` で具体的 .wasm 名
  を確認、対応 .wat を読む)。

cohort 順位 + 仮説詳細は `.dev/phase9_structural_debt_close_plan.md`
§6 (j) Step B 参照。

## Open questions / blockers

- なし。autonomous loop resumed。

## §9.12-B progress chunks

`.dev/phase_log/p9_12_B_chunks.md` (B1〜B158 = 138 chunks)
に移管。handover はポインタのみ保持。chunk table 蓄積に
よる handover 肥大 (A1 / C5) を解消。

## See

- [ROADMAP](./ROADMAP.md) §9.12 — phase row
- [`debt.md`](./debt.md) — D-154 umbrella, D-153 paused
- [`lessons/INDEX.md`](./lessons/INDEX.md) — 2026-05-20 entry
