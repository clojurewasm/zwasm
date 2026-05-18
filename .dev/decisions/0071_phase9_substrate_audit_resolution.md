# 0071 — Phase 9 substrate audit resolution + §9.12 scope amendment

- **Status**: Proposed
- **Date**: 2026-05-19
- **Author**: continue loop §9.9 close + 2026-05-19 substrate audit design session
- **Tags**: phase-9, substrate-audit, dispatch-architecture, build-option-dce, scope-amendment

> **状態**: skeleton。本 ADR は §9.12-pre で full draft に展開される。本ファイルは
> §9.12 サブ行展開 (ROADMAP §9 amend) を §18.2 の事前 ADR 要件として満たすための
> placeholder。Context / Decision の骨子は記載済み; Alternatives / Consequences /
> 実装詳細は §9.12-pre で populate。

## Context

Phase 9 完備 substrate audit (ROADMAP §9.12; per ADR-0062) は当初「Q2-Q4 の design
decisions only」として scope された。ところが 2026-05-18 〜 19 のセッションで:

1. **skip-impl == 0 主張の不正確性が判明** — 実測で 243 directives (193 non-simd + 50
   SIMD) 残存。`SKIP-CROSS-MODULE-IMPORTS` (100) + `SKIP-NO-LINK-TYPECHECK` (26) +
   `SKIP-VALIDATOR-GAP` SIMD (50) + manifest skip-impl (1)。

2. **ユーザーが Phase 9 完備の 7 要件を確定** ([`.dev/phase9_completion_close_plan.md`](../phase9_completion_close_plan.md) 第 1 章):
   - 負債 / ADR 全部解消、Wasm 2.0 完備 100%、知見の固定化、Phase 10 整地、bench
     baseline、scaffolding iteration 速度、windowsmini cross-platform sweep。

3. **追加フィードバック** (2026-05-19): build-option による真の DCE + runtime
   option の二段制御 を全 layer 一貫パターンで確立する方向性確定。

4. **substrate 現状の事実確認**:
   - ZirOp 581 tags (Wasm 3.0 slot 揃い); `src/instruction/wasm_X_Y/<op>.zig` 3514
     LOC 既存; `src/feature/mvp/mod.zig` だけ register() 実装、他 9 features は
     placeholder; `build_options.wasm_level` consult が CLI diagnostic 2 か所のみ。
   - 半完成 Hypothesis D-1 で動いていることが Task #2 survey で確認 (詳細:
     `private/notes/p9-close-q3-arch-survey.md`)。

## Decision

§9.12 (Phase 9 substrate audit) の **scope を以下に拡張** し、サブ行 §9.12-pre /
§9.12-A..I で実装段階に展開する。

### Q2 — 再検査スコープ resolution

| 条項 | 採択 |
|---|---|
| §2 P13 | Accept (維持) — Day-1 ZIR sized for full target |
| **§2 P14** | **Amend (sharpen)** — "**runtime** if-branching on feature flags のみ禁止。`comptime` 文脈の `if (comptime build_options.X)` は許容; build-option による DCE 用途では推奨" |
| §4.5 | Amend — DispatchTable interp 軸 = required (mvp 完成); validator/lower/emit/jit 軸 = per-op file pattern (= ADR-0023 §4.5 amend と整合; per `0023` Revision history) |
| §4.6 | Accept (Q3 と整合) — `-Dwasm=` / `-Dwasi=` build flag を全 layer 一貫で DCE 用に活用 |

### Q3 — Architecture 採択 = **Hypothesis C** (per-op file + comptime collector + build-option DCE)

選定理由 (設計品質軸):

| 観点 | A | B | **C** | D-1 |
|---|---|---|---|---|
| Build-option による真の DCE | 不可 (table runtime populate) | 可 | **可** | 不可 |
| 1 op = 1 ファイル | × | × (monolith) | **◎** | △ |
| 全 layer 一貫パターン | × | △ | **◎** | × |

C 採択により: (a) 1 op を理解するには 1 ファイル読めば 5 軸 handler 全部わかる
(b) `-Dwasm=v1_0` build で Wasm 2.0+ の handler が **literally absent** (c) CLI /
c_api / WASI への同パターン拡張で feature flag substrate が全 layer 一貫。詳細実装
形は ADR-0073 (build-option DCE substrate) で完備。

### Q4 — 監査と実装の境界

監査 deliverable = ADR + 決定 + 3 spike measurements + 最小実装サンプル (代表 op
`i32.add` を C パターンで実装し 6 build option 組合せで test 通過確認)。残りの op
の C 移行 + 全 layer DCE 拡張は §9.12-B で。Q5 / Q6 は §9.12-C / §9.12-D。Wasm 2.0
100% drainage (skip-impl 243 → 0) は §9.12-E で **Phase 9 完備の主軸 exit
criterion**。

### §9.12 ROADMAP scope amendment

§9.12 は以下のサブ行に展開される:

```
§9.12-pre   ADR drafts (本 ADR 含む 4 新規 + 2 amend) + 3 spike (autonomous)
§9.12-A     Scaffolding compression + enforcement layer 構築 (詳細: master plan §7)
§9.12-B     Q3 C 採択完成 + build-option DCE 全 layer 拡張 (ADR-0073 実装)
§9.12-C     Q5 hygiene landings (ADR-0072 + rule + lint + code)
§9.12-D     Q6 libc boundary (ADR-0070 + rule + sweep)
§9.12-E     ★ Wasm 2.0 完備 100% (skip-impl 243 → 0 + 網羅テスト 4 系統)
§9.12-F     Phase-9-eligible debt cohort
§9.12-G     Phase 10 prep substrate
§9.12-H     Bench baseline (Mac-only Wasm 2.0 + wasmtime)
§9.12-I     ADR + lesson + private/ closure
```

§9.13-0 (Cat IV windowsmini) と §9.13 (Phase 10 entry gate) は既存のまま。

## Alternatives considered

> Skeleton stage. 詳細展開は §9.12-pre で。

### Alternative A — Hypothesis A complete (DispatchTable 全軸 populated)

- Sketch: 9 feature × register() 実装 + validator/lower/emit を table consumption 化
- 不採用: **build-option による真の DCE 不可** (table は runtime populate)。Q3 採用評価で他案を下回る。

### Alternative B — comptime-gated switch (既存 switch を `if (comptime ...)` で包む)

- Sketch: DispatchTable 撤廃 + `src/instruction/` から validator/lower/emit に戻す
- 不採用: `validator.zig` 等が monolith のまま; 1 op = 1 ファイル整理が成立しない。設計品質軸で C より劣る。

### Alternative D-1 — Hybrid (現状の half-A + half-C 維持)

- Sketch: §9.12-B で最小限の仕上げ (placeholder 4 件埋め) + build-option consultation 追加
- 不採用: build-option 真の DCE 未対応; 設計が中途半端のまま継続。

### §9.12 scope を狭めて design decisions only に維持 (= 当初 ADR-0062 の通り)

- Sketch: §9.12 = decisions; 実装は Phase 10 へ
- 不採用: ユーザー要件 (Phase 9 完備 7 項目) が Phase 10 持ち越し不可と明示; 「整地済みで Phase 10 を始める」が要件。

## Consequences

- **Positive**:
  - 1 op = 1 ファイルで 5 軸全部 localize される (= bug 原因の root-cause が即座に判明)
  - `-Dwasm=v1_0` build が binary に Wasm 2.0+ コード literally 含まない (size + 攻撃面積 削減)
  - CLI / c_api / WASI が全 layer 一貫パターンで feature gate
  - Phase 9 完備 exit が "skip-impl == 0 + 網羅テスト 4 系統 green" で literal 検証可能

- **Negative**:
  - §9.12-B 実装スコープが大きい (5 dispatcher 全部 inline switch + collector 形に書き直し)
  - Zig 0.16 で 581-tag `inline switch` の compile-time wall が spike 計測待ち
  - §9.12 サブ行が 11 行に膨張 → ROADMAP §9 表が縦長 (見通し代償)

- **Neutral / follow-ups**:
  - ADR-0073 (build-option DCE substrate) を別途新規 ADR として fileing
  - ADR-0023 §4.5 amend (per-op file pattern 正式採用) を別途 amend
  - ADR-0050 amend (skip-impl one-way ratchet) を別途 amend
  - Phase Status widget 文言 update は本 ADR Accepted 後の commit で

## References

- ROADMAP §1, §2 (P/A), §4.5, §4.6, §9.12, §9.12-pre 〜 §9.12-I
- 関連 ADR:
  - ADR-0023 (src directory structure; §4.5 amend ペア)
  - ADR-0050 (ADR lifecycle; skip-impl ratchet amend ペア)
  - ADR-0056 (Phase 9 scope extension)
  - ADR-0062 (substrate audit gate anchor)
  - ADR-0065 (Wasm 1.0 instance work Phase 9 rescope)
  - ADR-0070 (libc dependency policy; Q6)
  - ADR-0072 (comment-as-invariant rule; Q5)
  - ADR-0073 (build-option DCE substrate; Q3 C 採用詳細)
- マスター計画書: [`.dev/phase9_completion_close_plan.md`](../phase9_completion_close_plan.md)
- 設計議論: [`.dev/phase9_completion_substrate_audit.md`](../phase9_completion_substrate_audit.md)
- Survey 出力 (gitignored): `private/notes/p9-close-q3-arch-survey.md`, `private/notes/p9-close-skip-impl-inventory.md`

## Revision history

| Date       | SHA          | Note                                                                              |
|------------|--------------|-----------------------------------------------------------------------------------|
| 2026-05-19 | `<backfill>` | Initial skeleton — §9.12 scope amendment justification; full draft in §9.12-pre.  |
