# Optimisation log — 採用 / 棄却 ledger

> **Phase 8 以降の最適化候補と判断結果のトラッカー**。Phase 7
> 終了時点の baseline (interpreter / JIT 単純実装) を起点に、
> `bench/` の hyperfine 計測を参照して採否を決める。
>
> v1 では「interpreter で速い」観測点が複数あった (W43/W44/W45
> 系の hoist、coalescer、address-mode folding 等)。v2 はこれを
> 構造化して **採用 / 棄却 / 保留** をログに残し、後追いで
> 「過去に試した・棄却した」を再発見する W54 同型の事故を防ぐ。

## 編集規則

- 1 候補 = 1 行。Phase / コスト見積 / 予想効果 / 判定 / Refs。
- 判定欄は `Adopted` / `Rejected` / `Deferred` / `Investigating`
  のいずれか。
- `Adopted` には実装 commit の SHA。`Rejected` には ADR / lesson
  への pointer (理由が再利用可能なら lesson 必須)。
- `Deferred` は **必ず** trigger 条件を併記 (e.g. "bench で hot
  になったら", "Wasm 3.0 SIMD landing 後", "FFI overhead が
  10% 超えたら")。漠然とした "later" は不可。
- 候補は **思いついた時点で追加** する。実装するかどうかは
  別の判断。Brain-dump として機能させる。

## ステータス語彙の根拠

`Investigating` 中に時間を使い切ったら `Rejected` か `Deferred`
にする。3 cycle 経っても `Investigating` のままなら audit_
scaffolding §F が拾う。

## 候補テーブル

| ID    | Phase  | 候補                                                                                    | コスト見積          | 予想効果             | 判定           | Refs                              |
|-------|--------|-----------------------------------------------------------------------------------------|---------------------|----------------------|----------------|-----------------------------------|
| O-001 | 8 / 15 | Address-mode folding (LEA → store/load の immediate disp 統合; v1 D116 で abandoned)    | 2-3 day             | 5-10% mem-heavy bench | `Investigating` | v1 D116 post-mortem; bench `c_btree` |
| O-002 | 8      | x86_64 regalloc port (slot reuse + parallel-move; D-029 解消)                            | 1 week              | 3-5% (hot loops)      | `Deferred`     | D-029; `7.7-regalloc` 未着手     |
| O-003 | 8      | Threaded-code interp dispatch (computed goto / tail-call) — 既に Phase 6 で WAMR 同等  | already in `interp/` | baseline                 | `Adopted`      | §9.6 close                       |
| O-004 | 8 / 15 | Inline cache for cross-module `call` (D-026 解消後)                                     | 3-4 day             | 10-20% if call-heavy  | `Deferred`     | D-026; trigger=cross-module bench landing |
| O-005 | 11+    | AOT compilation pipeline (cranelift backend or own emitter? — ADR要)                     | 2-3 weeks           | 30-50% startup-after-warm | `Deferred`     | ROADMAP §11; trigger=Phase 10 close |
| O-006 | 15     | Liveness-aware regalloc (W54 mirror; v2 day-1 ZIR substrate で前提済み)                  | 1 week              | 5-10% (regalloc 依存) | `Deferred`     | ADR-0014 §6.K.5; trigger=O-002 後  |
| O-007 | 8      | i32.shr_s/u with constant rhs → fused IMM form (現状は MOV+SHR; v1 で速かった observation) | 1 day               | 2-5% in shift-heavy   | `Investigating` | bench: rust_sha256 (shift dense) |
| O-008 | 8      | Memory bounds-check 折りたたみ (連続アクセスで 1 回に統合; v1 D43)                       | 3 day               | 10-30% mem-bench      | `Deferred`     | trigger=Phase 8 mem-bench landing |
| O-009 | 11+    | Multi-value (Wasm 1.1) 直接対応 (現状 single-result UnsupportedOp) — Wasm 3.0 ride       | varies              | feature-completeness | `Deferred`     | spec proposal phase 4; ROADMAP §11 |
| O-010 | 15     | Loop unrolling for tight numeric kernels (v1 W45)                                       | 1 week              | 5-15% kernel bench    | `Deferred`     | trigger=fixed-size loop pattern detection |

## 候補追加テンプレ

```
| O-NNN | <Phase> | <一行説明 — 何を最適化するか> | <day/week 単位> | <%> | `Investigating`/`Deferred`/`Adopted`/`Rejected` | <links> |
```

## Phase 7 終了時のチェックリスト (Phase 8 移行前)

Phase 7 close (= §9.7 全 row [x]) の audit_scaffolding が、この
log を以下の項目で検査する:

1. **負債 vs 最適化の交差点**: `.dev/debt.md` の各 row が
   この log のどの O-NNN に対応するか (または「最適化ではなく
   構造的瑕疵」として独立)。重複は片方を pointer 化する。
2. **Phase 7 でできた前提**: x86_64 baseline + 3-host gate +
   bench infra が揃ったので、Phase 8 の最適化候補は **bench
   numbers driven** で採否判断する (勘の最適化を Adopted に
   しない、O-001/O-007 の `Investigating` ラベルが load-bearing)。
3. **設計の「ゴチャつき」確認**: AOT / Wasm 3.0 / WASI 拡張 /
   SIMD まで見据えて、ここで採用される最適化が `src/engine/`
   の zone 構造を破らないかチェック (例: O-005 AOT は
   `engine/codegen/aot/` 既存モジュール想定; O-008 mem-bounds
   折りたたみは `ir/analysis/` レイヤで; どちらも追加先が
   既に予約されている)。

## 命名

- `O-NNN` は連番。削除可・rejected 後も保持 (将来再評価時に
  「同じことをまた検討した」が分かるように)。`debt.md` の
  `D-NNN` と同じ運用。

## 関連ファイル

- `.dev/debt.md` — 構造的負債 (今やるべき / blocked-by)。最適化
  ではなく欠落補修。
- `.dev/lessons/INDEX.md` — 観測ログ。`Rejected` 案件の理由を
  lesson に書いて O-NNN から pointer する運用がきれい。
- `bench/results/history.yaml` — 実測データ。`Adopted` の
  before/after を残す。
- `.dev/decisions/` — `Adopted` で load-bearing な設計選択を
  伴う場合は ADR 起こす。
