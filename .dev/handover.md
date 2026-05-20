# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **READ FIRST** [`.dev/phase9_structural_debt_close_plan.md`](phase9_structural_debt_close_plan.md)
   (Status: Proposed 2026-05-20). この close-plan が
   `/continue` Step 1a の override を発火させ、ROADMAP
   §9.<N> task より先に §6 Work sequence を実行する。
2. **READ NEXT** [`.dev/lessons/2026-05-20-refactor-tradeoffs-honest-accounting.md`](lessons/2026-05-20-refactor-tradeoffs-honest-accounting.md) — 経緯記録。
3. `git log --oneline -10` — last code commit: `72a87509`
   (close-plan §6 (j) Step B cohort 1-residual: effectiveMemory0Min
   + fixture filename in FAIL line)。
4. **Live status**: `zig build test-spec-wasm-2.0-assert >
   /tmp/spec.log 2>&1 || true; grep "^FAIL " /tmp/spec.log |
   sort | uniq -c | sort -rn` — current breakdown is the
   source of truth.
5. `.dev/debt.md::D-154` — close-plan umbrella row。

## Active state

- Phase 9.12-E。close-plan §6 (j) Step B 進行中。
- §6 (j) Step A 完了 (`f5b3f626`): spectest.wat auto-register。
- §6 (j) Step B cohort 1+2 部分着 (`2ddcdd7c`): const-expr
  `global.get N` for imported globals + importer-side
  `scratch_globals` の `[0..num_imports)` を registered
  exporter から populate。
- §6 (j) Step B cohort 3 完 (`45bc96d3`)。cohort 4 完 (`ce67cd4a`)。
  cohort 1-residual 完 (`72a87509`): imported memory の effective
  size を spectest exporter の actual min から取得。FAIL line に
  fixture 名を入れる軽量改修も同時に land。
- 次: 残 3 件
  - cohort 5 (imports: grow × 2) — `grow(i32:0) → got 3, expected 2`
    + `grow(i32:1) → got 2, expected 4294967295`。imported memory
    grow の state 蓄積 / max-pages cap 判定。
  - cohort 6 (elem: call_imported_elem trap) — global.get funcref
    runtime resolution (elem-form 4 の `global.get N` を null
    sentinel として decode した結果)。

## Step B 再開時の手順 (cold-start)

```sh
# 1. ログ再生
zig build test-spec-wasm-2.0-assert > /tmp/spec.log 2>&1
grep "^FAIL " /tmp/spec.log | sort | uniq -c | sort -rn

# 2. cohort 3 候補の fixture を bisect
#    InvalidFuncIndex: imports.60/61, elem.57, linking.17, table_grow.6
#    InvalidFunctype: elem.66/68
ls test/spec/wasm-2.0-assert/imports/imports.6{0,1}.wat
```

仮説 (verified at 2026-05-21):
- elem.57 / elem.66 / elem.68 などは declarative elem
  segment で typeidx が type section 範囲外、または
  declarative funcidx の resolve タイミング差。compile 時の
  validator がリジェクトすべきところで何かが抜けている。

cohort 詳細は `.dev/phase9_structural_debt_close_plan.md`
§6 (j) Step B 参照。

## Open questions / blockers

- なし。autonomous loop resumed。

## §9.12-B progress chunks

`.dev/phase_log/p9_12_B_chunks.md` (B1〜B158) に移管。
handover はポインタのみ保持。

## See

- [ROADMAP](./ROADMAP.md) §9.12 — phase row
- [`debt.md`](./debt.md) — D-154 umbrella, D-153 paused
- [`lessons/INDEX.md`](./lessons/INDEX.md) — 2026-05-20 entry
