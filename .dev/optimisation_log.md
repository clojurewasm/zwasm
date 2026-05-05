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

## Day-1 採用済み (v2 の foundation 設計選択)

ROADMAP §2 (P/A 原則) と Phase 0-7 の ADR で確定し、v1 との
構造的差別化として**最初から組み込み済み**の最適化。これらは
Phase 8 以降の最適化候補ではなく、候補が**前提とする** baseline。

| ID    | 領域                | 採用内容                                                                          | v1 との差                                  | Refs                                                  |
|-------|---------------------|-----------------------------------------------------------------------------------|--------------------------------------------|-------------------------------------------------------|
| F-001 | IR shape            | ZIR + day-1 `?Liveness` slot in `ZirFunc`                                          | v1 は post-hoc (W54 regression の温床)     | ROADMAP §4.2 / §P13; ADR-0014                         |
| F-002 | JIT pipeline        | Single-pass JIT (parse→ZIR lower→regalloc→emit を 1 走査で)                         | v1 は 4-pass                                | ROADMAP §P6                                           |
| F-003 | Interp dispatch     | Threaded-code (tail-call) ループディスパッチ                                       | v1 は switch-based                          | `src/interp/`; §9.6 close                              |
| F-004 | JIT register strat  | Reserved invariant GPRs (ARM64 X19-X28 / x86_64 R15) でランタイムポインタ常駐    | v1 は per-op reload from `*Runtime`        | ADR-0017 (ARM64) / ADR-0026 (x86_64)                  |
| F-005 | Feature gate        | Dispatch table 強制 (主 parser/validator/interp/emit が feature を `@import` しない) | v1 はコード分散 + `if (feature_x)` 散在    | A12 forbidden list; `src/ir/dispatch_table.zig`        |
| F-006 | Trap stub strategy  | Function あたり単一 trap stub + `bounds_fixups` で memory/sig/trunc-trap を集約 | v1 は trap-per-op スタブ                    | `emit.zig:bounds_fixups`; ADR-0028 で per-reason 拡張   |
| F-007 | Memory model        | Instance arena allocator (bulk-free at instance close)                             | v1 は個別 alloc/free                        | ADR-0014 §6.K.3                                        |
| F-008 | ABI invariants      | Comptime ABI layout guards (`jit_abi.zig` の `@compileError` for offset/alignment) | v1 は runtime layout drift で発覚          | `src/engine/codegen/shared/jit_abi.zig`                |
| F-009 | Encoder design      | 同 op-family を `kind: SseScalarKind` + `opcode` で parameterized helper に集約 | n/a (新規)                                  | `inst.zig:encSseScalarBinary` 等                       |
| F-010 | Value representation | `extern union { i32, i64, f32, f64, v128, funcref, externref }` (型 tag 別途)    | v1 同等 (NaN-box 不採用は意図的; 下表参照) | `src/runtime/value.zig`; ADR-0014                     |
| F-011 | Slot model          | GPR/FP 別プール + scratch reservation (ARM64 X16/X17, x86_64 RAX out-of-pool)     | n/a (新規)                                  | `src/engine/codegen/{arm64,x86_64}/abi.zig`            |
| F-012 | Edge-case fixtures  | `test/edge_cases/p<N>/<concept>/<case>/` に boundary を即時固定                  | n/a (新規)                                  | ADR-0020; `.claude/rules/edge_case_testing.md`         |

## Day-1 棄却済み (意図的に v2 では採らなかった)

| ID    | 棄却対象                                               | 理由 / 代替                                                                | Refs                                                          |
|-------|--------------------------------------------------------|----------------------------------------------------------------------------|---------------------------------------------------------------|
| R-001 | NaN-boxed `Value` (ClojureWasm 等が採用)               | (a) 64-bit に詰める必要なし (host メモリ潤沢); (b) 型情報は ZIR で comptime 既知; (c) debug 困難 — `extern union` が clarity 勝ち | F-010; ADR-0014                                               |
| R-002 | v1 の post-hoc address-mode folding (D116)             | v1 で abandoned-then-reverted。Phase 8 で bench-driven 再評価する (O-001)。day-1 ON は採らない | v1 D116 post-mortem; O-001                                    |
| R-003 | Pervasive feature `if`-branching (`if cfg.simd_enabled`) | A12 forbidden — dispatch table 強制                                         | ROADMAP §A12; F-005                                           |
| R-004 | `std.Thread.Mutex` / `pub var` vtable / `std.io.AnyWriter` | §14 forbidden — `std.atomic.*` + 明示 VTable struct を使う                  | §14 forbidden list; `.claude/rules/zig_tips.md`               |
| R-005 | Per-trap-reason 個別 stub                              | 単一 stub + Diagnostic M3 (ADR-0028) で reason 識別 — code size 小さい   | F-006; ADR-0028                                               |
| R-006 | v1 の D117 dual-entry self-call workaround             | v2 は `RegClass.inst_ptr_special` を Phase 7 から day-1 で確保し回避       | `src/engine/codegen/shared/reg_class.zig`; v1 D117 post-mortem |
| R-007 | Implicit error set sprawl (`anyerror!T` 多用)          | `Error` enum を per-zone で明示。型システムで W54-class contract drift 防止 | `.claude/rules/zig_tips.md` "inferred error sets"; ADR-0014    |
| R-008 | `usingnamespace` (Zig 0.16 で削除済)                   | 明示 re-export 強制 — 暗黙的依存を排除                                      | `.claude/rules/zig_tips.md`                                   |

## 命名

- `F-NNN` (Foundation) — Day-1 採用。実装は完了済 / 設計に組込済。
- `R-NNN` (Rejected pre-emptively) — Day-1 棄却。再考トリガが明確な
  ものは候補テーブル (`O-NNN`) に `Investigating` で再登録される
  (例: R-002 ↔ O-001)。
- `O-NNN` — Phase 8+ の候補。下表参照。

## 候補テーブル

| ID    | Phase  | 候補                                                                                    | コスト見積          | 予想効果             | 判定           | Refs                              |
|-------|--------|-----------------------------------------------------------------------------------------|---------------------|----------------------|----------------|-----------------------------------|
| O-001 | 8 / 15 | Address-mode folding (LEA → store/load の immediate disp 統合; v1 D116 で abandoned)    | 2-3 day             | 5-10% mem-heavy bench | `Investigating` | v1 D116 post-mortem; R-002; bench `c_btree` |
| O-002 | 8      | x86_64 regalloc port (slot reuse + parallel-move; D-029 解消)                            | 1 week              | 3-5% (hot loops)      | `Deferred`     | D-029; `7.7-regalloc` 未着手; F-011  |
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
