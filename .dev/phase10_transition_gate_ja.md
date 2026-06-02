# Phase 9 → Phase 10 遷移ゲート (日本語版・再現実反映)

> **Doc-state**: DRAFT (未コミット; レビュー用)
> **派生元**: `.dev/phase10_transition_gate.md` (2026-05-12 作成)
> **再生成日**: 2026-05-24 (Phase 9 close `00cb63de` / `add3da3d` 後)
> **位置づけ**: 原文は §9.12 番号付け期 + Tier-0 リフレーム前に作成されたため、本書は ADR-0062 renumber (§9.12 → §9.13) / ADR-0067 (ubuntunote ピボット) / ADR-0104 (Phase 9 真スコープ正直会計) / ADR-0110 (Value=16 widen) / `check_phase9_close_invariants.sh` 機構導入後の現実に合わせて書き直したもの。

## なぜこのゲートが存在するか

Phase 10 は Wasm 3.0 機能サーフェスを実装する — **4 つの実質的な新サブシステム** (WasmGC / Exception Handling / Tail Call / memory64) が対象。各サブシステムは:

1. 独自の設計 ADR を要する (Validator 拡張範囲 / IR ZirOp ディスパッチ形 / per-arch emit 戦略 / trap・landing-pad ABI / GC ルートスキャンプロトコル)。
2. ロードベアリングなデータ形に触れる (`Value` extern union 拡張、`bounds_fixups` per-tag 例外ペイロード、tail-call フレーム collapse、64-bit メモリオフセット配管)。
3. 単独スコープでは隣接サブシステムと衝突しうる (GC ルートスキャンは tail-call のフレーム collapse 意味論に協調が必要、EH のスタック巻戻しは GC 管理ローカルを認識する必要)。

Phase 9 (SIMD-128) は単一サブシステム + 確立された prior art (wasmtime / v8 SSE4.1 ベースライン)。Phase 10 は 4 サブシステム + より sparse な prior art + より tight な相互依存。**意図的懐疑シーケンシング**なしに開くと、v1 が regalloc post-hoc 階層最適化で踏んだ W54 級「累積的先送り」失敗モードのリスク。

ゲートは意図的に**協調的** — 自律ループは証拠 (`audit_scaffolding`、debt walk、コード状態棚卸し) を生成するが、**per-subsystem スコープ決定**は人間協調戦略判断を要する。

## 既に自動確認済み(invariants gate 経由)

ADR-0104 で導入された `scripts/check_phase9_close_invariants.sh --gate` (現在 **18/18 PASS**) が以下を機械的にカバー:

- I1: `SKIP-WIN64-EXHAUSTION` / `SKIP-WIN64-CALL-INDIRECT-TRAP` / `SKIP-WIN64-MULTI-RESULT` arm すべて削除済み (D-162 / D-163 / D-164 closed)
- I2: c_api Wasm-2.0 utilisation tests (4 ブロック) `src/api/instance.zig` に存在
- I3: Zig facade (`Runtime` / `Module` / `Instance` / `Value`) 最小サブセット + facade テスト
- I4: `wast_runtime_runner` smoke が `test-all` に配線済み
- I5: `.dev/debt.yaml` に `trigger-not-fired` masquerade なし
- I6: ADR-0105 + ADR-0106 Status: `Closed (implemented)` (`Accepted` または `Closed` のどちらも許容)
- I7: `phase9_close_master.md` Doc-state ACTIVE / handover.md が参照

加えて以下が自動確認済み:

- **3-host test-all green**:
  - Mac aarch64 (常時 foreground); ubuntunote x86_64 (per-chunk background; Step 0.7 で前サイクル検証); windowsmini Win64 (Phase boundary single-shot reconcile — `14f35e66` で GREEN, 13351 + 25457 + 266 + 5 + 212 + 55 PASS, 0 failed)
  - OrbStack は ADR-0067 で per-chunk gate から退役 (D-134 Rosetta 競合);Mac ローカル scratch ホストのみ
- **§9.10**: `[~] moved to Phase 11` マーカー landed (Track A Option 3 / ADR-0043 amend)
- **`scripts/zone_check.sh --gate`**: exit 0
- **`scripts/file_size_check.sh --gate`**: exit 0 (EXEMPT marker / ADR-0099 D2 経路で許容済みファイル群あり)
- **§9.13-V** (Value=16 widen / ADR-0110): closed `9204847a`
- **§9.13-0** (Cat IV windowsmini reconcile sweep): closed `add3da3d`
- **§9.12-A〜I**: すべて `[x]`
- **D-079 (i) + (ii) v128 cross-module imports**: 閉鎖 (`00cb63de` で regression-detector test + 業界監査 lesson `2026-05-24-c_api-v128-spec-boundary.md`)
- **D-157 SKIP-NO-LINK-TYPECHECK = 0**: 閉鎖 (§9.13-0 Phase A.1)
- **D-139 c_api Instance lifecycle audit**: 閉鎖 (§9.13-0 Phase A.2)

## チェックリスト (Phase 10 オープン前に全 ☑ 必須)

### 1. Phase 9 機能完成 — **すべて自動確認済み**

- [x] `zig build test-all` 3-host green (Mac + ubuntunote + windowsmini) — 最新 `add3da3d` 時点で確認済み
- [x] §9.9 spec gate: `skip-impl = 0` literal across spec + edge_cases + realworld + differential
- [x] §9.10 disposition (`[~] moved to Phase 11`)
- [x] §9.13-V Value=16 widen (ADR-0110)
- [x] §9.13-0 Cat IV windowsmini reconcile
- [ ] **§9.11 audit pass** (`audit_scaffolding` skill Phase-boundary 実行) — `private/audit-2026-05-18.md` は存在するが Phase 9 close 用ではない。**Phase 10 オープン直前に 1 回実行が必要** (autonomous; user touchpoint ではない)
- [ ] **§9.x SHA backfill** (`master plan §5.4`: 17 行) — Phase 9 close batch commit (autonomous; `chore(p9): backfill §9.x SHA pointers`)
- [ ] **bench Phase 9 close ベースライン** を `bench/results/history.yaml` に追記 (ADR-0012 §7 cadence; Phase 10 計測のゼロ点)

> 残り 3 項目は自律ループが §9.13 [x] 後に処理する mechanical work — user 判断不要。

### 2. Phase 10 prep-cycle deferred-work closure — **すべて自動確認済み**

原文 §2 は 2026-05-11/12 の Phase 10 prep cycle 成果物を確認するもの。現在の状態:

- [x] Track A (§9.10 → Phase 11): `[~]` マーカー landed
- [x] Track B (D-057 / D-065 ソース分割): 6 chunks landed; `file_size_check --gate` exit 0
- [x] Track C (ADR-0029 Path B + skip-ADR vocab + `check_skip_adrs.sh` gate): landed
- [x] Track D (本ゲート文書): landed (本書は派生・再生成版)
- [x] 加えて **§9.12-G** で `src/instruction/wasm_3_0/` placeholder 拡張済み (GC / EH / tail-call / memory64 / multi-memory / typed func refs)
- [x] **§9.12-D** libc dependency boundary (ADR-0070)
- [x] **§9.12-C** Q5 hygiene + comment-as-invariant rule

### 3. サブシステム別 Phase 10 開始チェックリスト (人間判断を要する)

Phase 10 の 4 サブシステムは実装チャンク開始**前**に設計地盤が必要。自律ループの最初の誤りは「設計 ADR なしで first chunk を始める」こと。以下を協調レビューで決定:

#### 3a. WasmGC

- [ ] **設計 ADR** filed: 新規番号 (推奨: 次空き番号 — ADR-0055/56/57/58 は Phase 9 で他用途に消費済みのため再割当不可) で `.dev/decisions/NNNN_wasmgc_design.md` を起こす。カバー範囲:
  - `Value` extern union 拡張 (`ref T` → tagged pointer scheme; ROADMAP §4.10 lines 884–894)
  - ヒープアロケータ (`mark_sweep.zig`) integration
  - GC ルートスキャンプロトコル (stack + globals 列挙)
  - バリア戦略 (sub-typed ref writes 用 write barrier)
- [x] ZIR ZirOp 目録確認: `zir.zig` に `struct.new` / `array.new` / `ref.test` / `ref.cast` / `i31.*` 番地確保済み (lines 577–611); §9.12-G で `wasm_3_0/` placeholders 拡張済み
- [ ] Validator 拡張スコープ: `validate/validator.zig` の GC オプコード handler 命名; sub-typing lattice ルール起草
- [ ] Per-arch emit 戦略: `src/engine/codegen/{x86_64,arm64}/op_gc.zig` を orchestrator stub として作成; recipe ファミリー列挙
- [ ] **spec proposal バージョン pin**: Wasm 3.0 GC at W3C 仕様 phase X.Y (commit ID / release tag を `.dev/proposal_watch.md` に記録)
- [ ] **D-082 sub-row (b) 再評価**: externref segment fixture — この設計パスで fix する可能性 (機会主義的前倒し; ゲート原本 Q4 (α) flip-rule 維持)

#### 3b. Exception Handling (EH)

- [ ] **設計 ADR** filed: 新規番号で `eh_design.md`. カバー範囲:
  - try-table / throw / throw_ref オプコード
  - per-tag 例外ペイロード形 (`bounds_fixups` 拡張)
  - landing-pad ABI (frame 巻戻しシーケンス; regalloc spill 復元との integration)
  - panic-vs-throw 区別 (Wasm trap ≠ Wasm exception)
- [x] ZIR ZirOp 目録確認: `try_table` + `throw` + `throw_ref` が `zir.zig:561-568` に存在
- [ ] Validator 拡張スコープ: try-table label-class 解決 + tag-type チェック
- [ ] Per-arch emit 戦略: landing pad 出力形 / prologue・epilogue / regalloc spill 復元との協調
- [ ] **spec proposal バージョン pin**
- [ ] **GC との協調**: 設計 ADR は GC ルートスキャンが in-flight exception state とどう相互作用するかを文書化 (unwound frames を stack-walk する際 GC ルートを一貫して列挙する必要)

#### 3c. Tail Call

- [ ] **設計 ADR** filed: 新規番号で `tail_call_design.md`. カバー範囲:
  - return_call / return_call_indirect / return_call_ref オプコード
  - フレーム collapse 意味論 (caller フレームを callee 本体実行前に置換)
  - regalloc の帰結 (caller の locals/spills lifetime が tail-call で終わる; 新しい caller-save invariants)
- [x] ZIR ZirOp 目録確認: `return_call` + `return_call_indirect` + `return_call_ref` が `zir.zig:567-569` に存在
- [ ] Validator 拡張スコープ: tail-call call-stack lint
- [ ] Per-arch emit 戦略: per-arch フレーム collapse シーケンス
  - ARM64: FP/LR 復元、SP = caller-of-caller の SP、callee へ branch
  - x86_64: RBP 復元、RSP 調整、calling convention 保ったまま callee へ jmp
- [ ] **spec proposal バージョン pin**
- [ ] **EH との協調**: tail-call が try-frame を跨いで許される/許されないか (Wasm 3.0 spec stance を引用)

#### 3d. memory64

- [ ] **設計 ADR** filed: 新規番号で `memory64_design.md`. カバー範囲:
  - `memarg` 64-bit オフセットフラグ
  - アドレッシングモード出力 with 64-bit displacement (ARM64: LDR/STR with 64-bit offset via scratch reg; x86_64: 64-bit displacement via address-mode prefix)
  - bounds-check 形調整 (現在の `bounds_fixups` は 32-bit メモリオフセット前提; 拡幅必要)
- [x] ZIR ZirOp 目録確認: ROADMAP §4 line 476 注記 (同じ load/store ops を memarg フラグで再利用); §9.12-G で flag plumbing 拡張済み
- [ ] Validator 拡張スコープ: 64-bit-memory モジュールレベルフラグ検出
- [ ] Per-arch emit 戦略: 64-bit displacement 出力パターン; 既存 32-bit fast-path への非劣化保証
- [ ] **spec proposal バージョン pin**

> **原本 §3d D-079 (ii) discharge plan 項目**: D-079 は §9.13-0 Phase A.3 (`00cb63de`) で閉鎖済み — このゲートでの再確認は不要 (本書から除外)

### 4. 設計クリーンネス外挿

Phase 10 の 4 サブシステムは以下を**violate しない**:

- [x] **Zone アーキテクチャ** (ADR-0023): `bash scripts/zone_check.sh --gate` 現在 exit 0
- [ ] Phase 10 entry 時点でも `zone_check --gate` exit 0 維持 (新サブシステムが新規 layering 違反を導入しない確認 — 各設計 ADR self-check 項目)
- [ ] **単一アロケータ** (ADR-0014 §6.K.2): GC ヒープアロケータが `Runtime` アロケータ階層と integration; 並列アロケータチェーン導入禁止
- [ ] **§14 forbidden list compliance**: 各設計 ADR が "Single field serving two distinct semantic axes" anti-pattern (`.claude/rules/single_slot_dual_meaning.md`) を self-check
  - GC: tagged pointer scheme
  - EH: `bounds_fixups` 拡張
  - Tail Call: フレーム collapse indicator
- [ ] **AOT 互換性** (Phase 12 horizon): 各 Phase 10 サブシステムの emit 出力が AOT serialise で消費可能。JIT-only ショートカット (例: hot path での immediate patching) が AOT で再現不能であってはならない
- [ ] **v1 からのコピペ禁止** (ROADMAP P10): v1 の GC / EH / tail-call / memory64 実装は survey (Step 0) として読むのは OK; v2 は再導出

#### 4a. Phase 10 → Phase 11 deferred-work 依存 DAG

Phase 10 close 後、Phase 11 (WASI 0.1 full + bench infra) が吸収する事項:

```
    ┌──────────────────────────────────────────────────┐
    │ Phase 10 prep cycle deferrals (Tracks A + C)     │
    └────────────────────────────────┬─────────────────┘
                                     │
            ┌────────────────────────┴──────────┐
            │                                    │
    ┌───────▼─────────────────┐    ┌────────────▼───────────────┐
    │ §9.10 → Phase 11        │    │ D-082 (D-072 (c)-path)     │
    │ (Track A Option 3)      │    │  ├─ (a) 4 embenchen        │
    │ SIMD per-op gap         │    │  │   fixtures (Phase 11)   │
    │ analysis vs (wasmtime,  │    │  └─ (b) 1 externref        │
    │ wazero, wasmer) +       │    │      fixture (Phase 11     │
    │ Phase 15 debt filing    │    │      default OR Phase 10   │
    │ + 3× threshold + D122   │    │      if GC reftype work    │
    │                          │    │      surfaces it)         │
    └───────────┬─────────────┘    └────────────────────────────┘
                │
                │ (D-074 "Phase 11 natural carrier";
                │  bench infra cohort)
                │
    ┌───────────▼──────────────────────────────────────┐
    │ Phase 11 bench infra cohort (D-074 discharge):   │
    │  - `-Dwith-bench-compare` build flag             │
    │  - wazero/wasmer in flake.nix                     │
    │  - SIMD per-op micro-bench corpus                 │
    │  - gap-analysis script                            │
    │  - Phase 15 debt-entry filing convention          │
    └───────────────────────────────────────────────────┘
```

加えて Phase 10+ で見るべき新規候補:

- **D-058 / D-059** (`check_rule_paths.sh` / `check_skill_descriptions.sh` lint): blocked-by "Phase 10 boundary `audit_scaffolding` review"
- **D-171 / D-172 / D-173** (c_api scalar accessors: `wasm_extern_as_global/table/memory` + `wasm_global_new/get/set` / `wasm_table_get/set/size/grow` / `wasm_memory_data/...`): blocked-by "Phase F (Phase 10 open) c_api spec-accessor completion sub-row" — Phase 10 開いた直後の対象

#### 4b. サブシステム間協調マトリクス

| ペア                  | 相互作用                                                           | 文書化先         |
|-----------------------|--------------------------------------------------------------------|------------------|
| GC × EH              | スタック巻戻しが GC ルートを一貫列挙                               | §3a / §3b ADRs |
| GC × Tail Call       | フレーム collapse が callee 実行前に GC ルート到達性を保つ         | §3a / §3c ADRs |
| GC × memory64        | 64-bit memory の bounds-check 形が GC バリア出力と干渉しない       | §3a / §3d ADRs |
| EH × Tail Call       | try-frame 越え tail-call の許容/不許容 (spec stance)               | §3b / §3c ADRs |
| EH × memory64        | 64-bit メモリ領域参照の例外ペイロード                              | §3b / §3d ADRs |
| Tail Call × memory64 | locals/spills 内 64-bit メモリポインタとフレーム collapse 相互作用 | §3c / §3d ADRs |

### 5. 戦略レビュー (協調・人間 in-loop)

**ここが今回のゲートの実体** — 自律ループでは決断できない項目:

- [ ] ROADMAP §1 (mission) と §2 (P/A) を再読: Phase 10 入口は約束と一致するか
- [ ] **`meta_audit` skill 起動** — ROADMAP §1/§2/§9/§14/§15 と直近 ADR 群 (Phase 9 ADR-0041 / 0049 / 0051 / 0052 / 0053 / 0054 / 0055-and-up; 特に直近の 0099 (file-size cap reframing) / 0104 (Phase 9 honest accounting) / 0110 (Value=16 widen)) への意図的懐疑パス。出力: `.dev/meta_audits/2026-05-24-phase10-entry.md`
- [ ] **Phase 10 スコープ確認**: 「Wasm 3.0 feature-complete」フレーミングを維持するか
  - 代替検討: GC を Phase 10a に分離; memory64 を Phase 14 thread / memory64 コホートと merge; function references を Phase 10 に含めるか (ROADMAP §1.2 「Wasm 3.0 完備」現行解釈: 4 サブシステムのみ、function-references は除外)
  - 原本 §9 Q1 = 「4 サブシステム維持」決定済み (2026-05-12); 再検証は本ゲート任意
- [ ] **サブシステム順序決定**: どれから開く?
  - 原本 §9 Q2 default = **memory64 → Tail Call → EH → GC** (small → large 設計サーフェス):
    - memory64: 最小設計サーフェス (既存 load/store にフラグ点灯)
    - Tail Call: regalloc 連動だが範囲限定
    - EH: 巻戻し + regalloc spill 復元を横断
    - GC: 最大サーフェス (ヒープマネージャ + バリア + ルートスキャン)
  - **再検証**: §9.13-V Value=16 widen 完了で Phase 10 の前提が変わっていないか
- [ ] **新規 ADR 番号割当**: 原本 §9 Q3 は ADR-0055..0058 を予定したが**消費済み**。Phase 10 設計 ADR は新番号 (次空き = 現状 ADR-0107 以降の連番) で起こす。Track A は ADR-0043 in-place amend / Track B は ADR-0054 / Track C は ADR-0029 in-place amend — これらは確定; Phase 10 4 サブシステムは新規番号
- [ ] **採用トリガー監査**: `.dev/optimisation_log.md` の `O-NNN` 候補で Phase 10 関連 (GC 割当 fast-path 候補等) があるか
- [ ] **D-082 sub-row (b) early-discharge**: 原本 §9 Q4 (α) flip-rule 維持確認 — Phase 10 GC chunks が externref segment 処理に触れたら同チャンクで fix + `skip_externref_segment.md` 退役
- [ ] **D-171 / D-172 / D-173 sequencing 確認**: Phase F = "Phase 10 open" c_api spec-accessor completion sub-row として何時/どの形で実行するか合意 (lesson `2026-05-24-c_api-v128-spec-boundary.md` 参照; scalar accessors は wasm-c-api 仕様標準完成作業 — v0.1.0 RC blocked ではないが Phase 10 開直後の自然な対象)
- [ ] **決定ログ**: §1/§2/§4/§5/§9/§14 amendment が結果するなら `.dev/decisions/NNNN_phase10_entry.md` ADR を起こす

## §6. ROADMAP 配線 (hard-gate detector ロードベアリング)

`/continue` skill の hard-gate detector は以下を要求:

1. **Phase Status widget**: Phase 10 行に `🔒` — ✅ ROADMAP line 1184 で確認
2. **§9 タスク表ハードゲート行**: 本ゲート文書ファイルパス + `🔒` を含む — ✅ **§9.13** で確認 (line 1318)
   - 原本 §6 は「§9.12 行」と書いているが、ADR-0062 renumber 以降は **§9.13**
3. **`.claude/skills/continue/SKILL.md` ハードゲートリスト**: "Phase 9 → 10 gate at §9.9 / 9.13" が登録済み — ✅ 確認

## §7. ゲート exit 条件

`§9.13` 行は**上記 5 セクション全て ☑ で初めて `[x]`** に flip。それまで:

- 自律 `/continue` ループは Phase 10 を開かない
- 次タスク参照が `9.13` に到達すると `ScheduleWakeup` を armed しない — 代わりに 1 文ハンドオフ「Phase 10 entry gate (`.dev/phase10_transition_gate.md`) needs collaborative review; pausing autonomous mode.」をサーフェスする
- ユーザーが本チェックリスト各セクションを walk して ☑ を入れていき、最後にゲート clear を依頼

`§9.13` flip 後、自律ループは以下を自動処理:
- Phase Status widget `9 | IN-PROGRESS → DONE`
- §9.x 17 行 SHA backfill (master plan §5.4) を 1 commit で実行
- `phase9_close_master.md` → `Doc-state: ARCHIVED-IN-PLACE` (→ `.dev/archive/phase9/` 配下に移動も検討)
- Phase 10 サブシステム順序 (§5 で決定) に従って `.dev/decisions/NNNN_<sub>_design.md` を Step 0 サーベイ後に起草

## §8. なぜ本ゲートに ADR を起こさないか

`archive/phase_gates/phase8_transition_gate.md` §「Why no ADR for this gate?」と同様: gate doc + ROADMAP 行 + SKILL.md carve-out が一緒に**ワークフロー regime** を定義する (§1/§2/§4/§5 design choice ではない)。ROADMAP §18.2 deviation watch は ADR が必要な §-番号を列挙するが、「Phase boundary procedure」はそこに含まれない。§9 タスク表のインライン新規行は §18 の「ルーチン状態更新 / フェーズ表展開」経路でゲート不要に通る。

将来のサイクルが本ゲートを**削除**する判断には ADR が必要 — ロードベアリングなワークフロールールの逆転。

## §9. 解決済み問い (原本 2026-05-12 決定 / 再検証)

| Q  | 原本決定 (2026-05-12)                                                                                                | 2026-05-24 再評価                                                                                                                                                            |
|----|----------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Q1 | Phase 10 スコープ = 4 サブシステム維持 (function-references 除外、サブフェーズ分割なし)                              | **再確認推奨** — §9.13-V (Value=16 widen) 完了で前提変化なし; 4 サブシステム維持で進める判断は依然妥当                                                                     |
| Q2 | サブシステム順序 = memory64 → Tail Call → EH → GC                                                                 | **維持** — Value=16 widen で v128 first-class 化済み; memory64 の bounds_fixups 拡幅は引き続き最小設計サーフェス候補                                                        |
| Q3 | ADR 番号: Track A=ADR-0043 in-place / Track B=ADR-0054 / Track C=ADR-0029 in-place / Phase 10 4 ADR = ADR-0055..0058 | **ADR-0055..0058 消費済み** (Win64 v128 marshal / Phase 9 scope ext / spec_assert factoring / table_ops JIT)。Phase 10 4 ADR は**次空き番号 (ADR-0111 以降)** で再割当が必要 |
| Q4 | D-082 sub-row (b) = (α) flip-rule (GC chunk が externref segment に触れたら同チャンクで fix)                        | **維持** — `/continue` Step 0.5 barrier walk が早期 discharge 機会を自動 surface                                                                                            |
| Q5 | ゲート粒度 = (α) item-level 22 ☑ inline (per-subsystem 設計 ADR がより深い checklist を持ちうる)                    | **維持** — 本書も同形を保つ                                                                                                                                                 |

## §10. 決定ログ

| 日付       | 決定                                                                                                                                                   | 記録者           |
|------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|------------------|
| 2026-05-12 | 初版 gate doc landed (Phase 10 prep mode Track D deliverable); §3 + §4 framework drafted                                                             | autonomous loop  |
| 2026-05-12 | Q1=4 サブシステム維持 / Q2=memory64→TailCall→EH→GC / Q3=ADR-0055..0058 / Q4=(α) flip-rule for D-082 (b) / Q5=(α) item-granularity                 | user (prep mode) |
| 2026-05-24 | 本日本語版 (`_ja.md`) 派生; ステイル箇所 (§9.12→§9.13 renumber / ADR-0055..0058 消費済み / D-079 (ii) `00cb63de` closed / OrbStack 退役) を現実反映 | autonomous loop  |

## §11. 参照

- `.dev/phase10_transition_gate.md` (原本; 本書はその日本語版・再現実反映派生)
- `.dev/archive/phase_gates/phase8_transition_gate.md` (テンプレート; 構造ミラー)
- `.claude/skills/continue/SKILL.md` §「Exception — hard human-in-loop transition gates」
- `.dev/phase9_close_master.md` §6 Phase 9 = DONE exit predicate (current authoritative)
- `scripts/check_phase9_close_invariants.sh` (18 invariants gate; ADR-0104)
- ROADMAP §9 Phase Status widget (line 1183-1184), §9.10 (Track A disposition), §9.13-0 (Cat IV reconcile), §9.13-V (Value=16), §9.13 (本ゲート)
- ROADMAP §4.10 (GC subsystem) + §4 ZIR catalogue (lines 476–611 — Phase 10 オプコード番地確保済み)
- ADR-0023 §「feature/」 ディレクトリ構造 (gc / exception_handling / tail_call / memory64 スロット確保)
- ADR-0014 §6.K (redesign / Value extern union 基盤)
- ADR-0028 M3 (リングバッファ; EH per-tag payload 拡張)
- ADR-0029 (skip 意味論; Track C Path B)
- ADR-0043 (SIMD perf eval スコープ; Track A reshapes)
- ADR-0049 (windowsmini per-chunk deferral; Phase boundary reconciliation)
- ADR-0062 (§9.12 → §9.13 renumber)
- ADR-0067 (ubuntunote ピボット; OrbStack 退役)
- ADR-0070 (libc dependency policy)
- ADR-0099 (file-size cap reframing; smell-detection)
- ADR-0104 (Phase 9 真スコープ正直会計; invariants gate 機構導入)
- ADR-0110 (Value=16 widen; v128 first-class)
- `.dev/debt.yaml`: D-026 (emcc env-stub host-func wiring; Phase 11), D-058 / D-059 (Phase 10 boundary audit deliverables), D-074 (Phase 11 bench infra), D-082 (D-072 (c)-path), D-171 / D-172 / D-173 (c_api scalar accessors; Phase F = Phase 10 open)
- `.dev/phase10_prep/track_{a,b,c}_*.md` (Phase 10 prep deliverables)
- `.dev/lessons/2026-05-24-c_api-v128-spec-boundary.md` (業界監査; D-079 / D-170 / D-171-3 リフレーム根拠)
- `.dev/proposal_watch.md` (Wasm proposal バージョントラッキング)
