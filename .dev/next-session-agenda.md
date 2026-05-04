# 次セッション議題 — 2026-05-04 セッション末で持ち越し

> **読み方**: 次セッションは handover.md → このファイル → 議論再開、の順で
> 読む。ここに書かれた「持ち越し論点」をユーザーと議論し、合意した部分から
> ROADMAP / ADR / `.claude/rules/` / refactor タスクとして展開する。
> 単なるブレインダンプであり、合意形成前の素材であることに注意。

## 持ち越しの大論点

ユーザーが次セッションで議論したいテーマ:

1. **Phase Plan の組み方は正しかったか**(`.dev/ROADMAP.md` §9, L1115 周辺)
   - 例: SIMD(Phase 9) / Wasm 3.0 / C API full(Phase 13)を Phase 7-8 より
     先に持ってくる順序の方が良くなかったか?
   - JIT を先に作るのではなく「v1 互換の表面 = wasm-c-api full + WASI 0.1 +
     spec testsuite full」を先に固めるのが正解だった可能性?
   - Phase 7+8 の JIT 開発が膨らみすぎていて、v1 規模カバーへの最短経路が
     見えにくくなっている疑い。

2. **介入 vs 自律ループのバランス**
   - 自律ループは「進捗速度を高める」装置だが、結果的に「ユーザー介入で
     こそ捕まえられた構造的判断」を素通りした事例が複数(後悔点 #9, #10)。
   - 「ループ中に重大な発見をした時に必ず止まって相談する」フックが必要?
   - `/continue` の停止 whitelist を緩める案 vs 「重要発見」の自己検出が
     現実的に可能かの疑問。

3. **ROADMAP / ADR / Rule の三層構造の運用論**
   - ROADMAP がこのセッションで一度も更新されなかったことに気付いた:
     §9.7 / 7.5 が一行のまま、実装は sub-7.5a〜7.5c-vi に分解されているが
     handover.md でしか追えない。
   - 「自律ループ中に発見した sub-row はどう正規化すべきか」のルール不在。
   - ADR-0017 の Revision history(X19 amendment)が「ADR が当初不完全
     だった」事実を覆い隠した。Revision history の使い方が緩い。

4. **AI 指示群(`.claude/`)に盛り込むべき教訓**
   - **後悔点 #9** から: 「修正に走る前に同種ケースを survey する」規律。
     現状 `/continue` Step 0 (Survey) は「タスク開始時」だが、
     「バグ発見時」のサーベイ規律はない。
   - **後悔点 #4** から: 「fixture 内のワークアラウンドパターンは debt
     起票必須」を `.claude/rules/edge_case_testing.md` に追記。
   - **後悔点 #5** から: 「default 値変更時のリスクチェックリスト」を
     `.claude/rules/zig_tips.md` または新規 rule に追加。
   - **後悔点 #8** から: 「自律ループ中の sub-row 分解は ROADMAP §18.2
     の 4 ステップで反映」を `/continue` に明記。今は handover-only。

5. **リファクタを挟みたい(後悔点 #1, #2, #6)**
   - **emit.zig 分割**(後悔点 #1): 3700+ 行の責務分離。Phase 7 がさらに
     膨らむ前に。
   - **liveness.zig の Frame ベース整理**(#2): 段階追加で読みづらく
     なった if-else if-else 連鎖を整理。
   - **テストの byte-offset 抽象化**(#6): hard-code を `prologue_size()
     + N` のような相対指定に。今後の prologue 拡張(x86_64, optimisation)
     で再度 124 site 直しを避ける。
   - **ROADMAP §9.7 sub-row 正規化**(#8): handover にしか無い 7.5a〜
     7.5c-vi を ROADMAP に反映、ADR-0019 の修正版に組み込む or 新規
     "ROADMAP §9 living updates rule" を起こす。

## 私が前のターンで列挙した後悔点(参照用、要約)

1. emit.zig 最初から責務分割すべき(最大)
2. liveness の段階拡張をその場凌ぎで広げた
3. `(if (result T))` のマージ問題を ADR-0017 設計時に気付けなかった
4. fixture ワークアラウンドの規範を edge_case rule に書いていない
5. `Allocation.max_reg_slots` のデフォルト値を 3 回変えた地雷
6. テストの byte-offset hard-code が prologue 拡張を高コスト化
7. ADR-0017 X19 amendment が「ADR 元設計不完全」を覆い隠した
8. 自律ループ中の sub-row 分解が ROADMAP に反映されなかった
9. **修正に走る前に同種ケース survey する規律不在**(双子最大)
10. ADR 4 本まとめ起票で依存順序が曖昧

## 次セッションでユーザーがやろうとしていること

ユーザーが明言:
> 「Phase Plan の組み方は正しかったか、SIMD や 3.0、C API full までを先に
> やるべきではなかったのかなど」を議論し、「AI 指示群への盛り込み、
> リファクタを挟みたい」

つまり:
1. **Phase ordering の再評価**(SIMD/3.0/C API を先に or 並列に持ってくる
   案の検討)
2. **AI 指示群(`.claude/rules/`, `/continue`, audit)の更新**(後悔点を
   ルールに昇華)
3. **リファクタ cycle**(emit.zig 分割 + その他)

これらは ROADMAP 修正(§18 amendment)を伴う可能性が高い。ADR を切る基準は
`.claude/rules/lessons_vs_adr.md` に従う。

## 次セッション開始時のチェック手順

1. `git log -10 --oneline` で最終状態(`8778349` D-027 fix が tip 付近)を確認
2. `.dev/handover.md` を読む(現状把握)
3. 本ファイル(`.dev/next-session-agenda.md`)を読む
4. ユーザーが議題を選んで指示(Phase ordering 再評価 / 指示群更新 /
   リファクタのどれから始めるか)
5. 議論結果に応じて ROADMAP/ADR/rule 更新 → 実装

ユーザーは現状コードを動かす作業ではなく、**設計と運用の上位レイヤーを
触りたい**ことに留意。コード変更を急がず、議論ファーストで。
