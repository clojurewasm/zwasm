# Phase 9 完備 — マスター計画書 v2 (日本語) 2026-05-19

> **目的**: ユーザーの 7 要件 + 追加フィードバック (設計品質第一 / build-option DCE 全 layer 貫徹 / あきらめないための機械的 enforcement) を Phase 9 close 内ですべて達成し、Phase 10 (Wasm 3.0) に **負債ゼロ・整地済み・iteration 高速・諦めが物理的に不可能** な状態で着手できる substrate を確立する。
>
> **作成経緯**: 2026-05-18 〜 19 セッションで §9.9 [x] flip 後、ユーザーが要件 7 点 + 追加フィードバック 3 点 (skip-impl 100% 最優先 / コスト/リスク表現削除 / build-option DCE 軸採用) を提示。調査 → 統合 → 自己レビュー → 第 1 稿 → 方針調整 → 本第 2 稿。
>
> **状態**: 確定稿。本セッションで `.dev/phase9_completion_close_plan.md` に promote + scaffolding 一式 setup 済み。次回 `/continue` で §9.12-pre (ADR drafts + 3 spikes) から autonomous loop 起動。

---

## 第 1 章 — ユーザー要件 (verbatim) + フィードバック反映

### 1.1 要件 7 つ

| # | 要件 |
|---|---|
| (1) | Phase-9-eligible 負債・ADR すべて解消 |
| (2) | **Wasm 2.0 完備 100% PASS (arm/amd) + それを保証する網羅的テスト** |
| (3) | Phase 9 までに覚知した知見・反省を「労力厭わず」コードベース/ツール/指示に組み込む |
| (4) | Phase 10+ C API / WASI / Wasm 3.0 / CLI / build option で困らない modular / dep-direction / bug-resistant な整地 |
| (5) | Wasm 2.0 ベンチ Mac-only + 他ランタイム比較 (v1 参照可) |
| (6) | iteration 速度 — `.dev/` / `.claude/` / ツール / gates をドラスティックに整理 |
| (7) | クリーン化後 windowsmini 一括動作通し + Win 固有 bug 修正 |

### 1.2 追加フィードバック (3 点)

| # | 内容 |
|---|---|
| (i) | **skip-impl の 100% 化が最優先** (= Phase 9 完備の主軸 exit criterion) |
| (ii) | **コスト見積もり / リスク表現は妥協を誘発するので削除**。判断軸は「設計のきれいさ / 潜在バグの発生しにくさ / 解消しやすさ」 |
| (iii) | **Build-option による真の DCE + Runtime option の二段制御** を全 layer 一貫パターンで確立。`-Dwasm=v1_0` build では Wasm 2.0+ の code / CLI 引数 / c_api / WASI が **literal に不在** になる |

### 1.3 統括価値

「**あきらめないための工夫と完全性**」が substrate に焼き付いていること。spike を多用して試行錯誤しつつ、最終形では妥協方向への変化が gate / lint / `@compileError` / audit で **物理的にブロック** される。

---

## 第 2 章 — 実測 ground truth (2026-05-18 〜 19)

### 2.1 Wasm 2.0 完備度 = 未達

| ランナー | PASS | FAIL | Skipped | skip-impl | skip-adr |
|---|---:|---:|---:|---:|---:|
| `spec_assert_runner_non_simd` | 25325 | 0 | 688 | **193** | 495 |
| `simd_assert_runner` | 13301 | 0 | 440 | **50** | 390 |
| **合計** | 38626 | 0 | 1128 | **243** | 885 |

handover/debt の "skip-impl == 0" 主張は **不正確**。実測 243 directives 残存。

### 2.2 skip-impl 243 件の内訳

| トークン | 件数 | 元の corpus / 原因 |
|---|---:|---|
| `SKIP-CROSS-MODULE-IMPORTS` | 100 modules + ~66 cascade | imports (39) / elem (19) / data (19) / linking (16) / table_grow (2) / memory_grow (2) / global (2) / table (1)。`hasUnbindableImports()` 過剰 reject。 |
| `SKIP-NO-LINK-TYPECHECK` | 26 | imports (24) / linking (2)。`assert_unlinkable` の link-time type check 未実装。 |
| `SKIP-VALIDATOR-GAP` (SIMD) | 50 | simd_lane (36) / simd_align (11) / その他 (3)。`assert_invalid` のレーン番号範囲・align immediate 範囲検証ギャップ。 |
| `exports/manifest.txt` 内 `skip-impl` | 1 | `non-invoke-action` (`get` / `set` directive 未対応)。 |

### 2.3 ZirOp + Dispatcher 構造

- ZirOp: **568 + 13 pseudo = 581 tag**
- Wasm 3.0 slot 全部宣言済み (try_table / throw / return_call / call_ref / GC / memory64 / etc.)
- Dispatcher 拠点 5 か所:
  - `validator.zig` (1699 LOC, switch line 515)
  - `lower.zig` (1091 LOC, switch line 160)
  - `arm64/emit.zig` (1984 LOC, switch line 808 → `op_*.zig`)
  - `x86_64/emit.zig` (1956 LOC, 同形)
  - `interp/dispatch.zig + mvp.zig` — 既に Hypothesis A (中央 `DispatchTable.interp[op]` lookup)
- `DispatchTable` 4 軸 (parsers / interp / jit_arm64 / jit_x86) — **interp のみ populated**
- `src/feature/*/register.zig` — **mvp のみ実装済** (214 LOC); 他 9 features は placeholder (各 20 LOC)
- `src/instruction/wasm_X_Y/<op>.zig` — **3514 LOC が populated** (Wasm 1.0 / 2.0 大部分; Wasm 3.0 は placeholder)
- `build_options.wasm_level` consultation: **`cli/main.zig` の diagnostic 2 か所のみ** (validator/lower/emit/runtime はノータッチ)

### 2.4 debt / ADR / lessons / scaffolding 棚卸

- debt: 28 active (`now` 6, `blocked-by` 22)
- ADR: 77 件 (`Accepted` 49; ~22-25 件が Phase 1-8 DONE で `Closed (Phase X DONE)` 化候補)
- lessons: 39 件 (1 件 Citing 未 backfill)
- scaffolding: `ROADMAP.md` 2373 LOC (Phase 0-8 narrative 圧縮余地 800-1000 LOC), `continue/SKILL.md` 958 LOC (圧縮余地 300 LOC), private/audit-*.md 6 件 (古い 5 件 archive 余地)

---

## 第 3 章 — 設計軸と Q3 採択

### 3.1 評価軸 (前計画から変更)

| 軸 | 採用 | 不採用 |
|---|---|---|
| 設計のきれいさ (1 op = 1 ファイル / 全 layer 一貫 / 軸分離明瞭) | ✓ | |
| 潜在バグの発生しにくさ (build option で機能が "literal absent" / type-level enforcement) | ✓ | |
| 解消しやすさ (失敗時の root-cause が 1 ファイルで完結 / 不要 path が物理的にゼロ) | ✓ | |
| ~~実装コスト・工数~~ | | ✗ (妥協誘発) |
| ~~リスク見積もり~~ | | ✗ (妥協誘発) |
| ~~wall-clock タイムライン~~ | | ✗ (autonomous loop に任せる) |

### 3.2 Q2 — 再検査スコープ

| 条項 | 採択 |
|---|---|
| §2 P13 (Day-1 ZIR sized for full target) | **Accept (維持)** — 581 tags 宣言済み、Wasm 3.0 slot 揃い |
| §2 P14 (no pervasive build-time `if`) | **Amend (sharpen)** — "**runtime** if-branching on feature flags のみ禁止。`if (comptime build_options.X)` および `comptime` 文脈の DCE 用 `if` は許容"。Cranelift / Wasmer 流儀 (runtime feature toggle) は引き続き禁止 |
| §4.5 (DispatchTable feature modules) | **Amend** — "DispatchTable interp 軸 = required (mvp 完成); validator/lower/emit/jit 軸 = per-op file pattern (`src/instruction/wasm_X_Y/<op>.zig` で `pub const handlers = .{...}` を export し、comptime collector 経由で dispatch)" |
| §4.6 (`-Dwasm=` / `-Denable=` build flags) | **Accept (Q3 と整合)** — flags は build.zig で declared; collector が `build_options.wasm_level` で feature_level filter |

### 3.3 Q3 — アーキテクチャ採択 = **C** (per-op file + comptime collector + build-option DCE)

調査 (Task #2 survey) で得た事実:

| Hypothesis | Build-option DCE | 1 op = 1 ファイル | 全 layer 一貫 |
|---|---|---|---|
| A (DispatchTable 完成) | 不可 (table は runtime populate) | × | × |
| B (comptime if 包み) | 可 | × (中央 file が monolith) | △ |
| **C (per-op file + comptime inline_for)** | **可** | **◎** | **◎** |
| D-1 (現状 hybrid) | 不可 | △ | × |

**採択 = C**。理由: 設計のきれいさ・潜在バグの発生しにくさ・解消しやすさ の 3 軸で他を上回る。Build-option DCE が真に効くのは A/B/C のうち B/C のみ。1 op = 1 ファイルの整理 + 全 layer 一貫パターン が両立するのは C のみ。

C の compile-time wall (Zig 0.16 で 581-tag `inline switch` の eval quota / IR 膨張) は spike で測定。仮に wall に当たっても、`inline switch` を文字単位 split (Cranelift の `isle-split-match` 相当) で回避可能。**設計を妥協する理由にはしない**。

### 3.4 Q4 — 監査と実装の境界

監査 deliverable = ADR + 決定 + 3 spike measurements + 最小実装サンプル (代表 op `i32.add` を C パターンで実装、`-Dwasm={v1_0,v2_0,v3_0}` build で全部 green 確認)。残りの op の C 移行は §9.12-B (Q3 採用 C 完成) で。

### 3.5 Q5 — Substrate hygiene

| Trigger | 固定化 artifact |
|---|---|
| D-132 / D-133 op_table register-numeral hardcoding | `abi.zig` comptime disjointness check 拡張 + `audit_scaffolding §G` grep 強化 + D-133 sweep |
| Cat III runtime/instance hygiene | `.claude/rules/runtime_instance_layer.md` 新設 + lint |
| comment-as-invariant pattern | **`.claude/rules/comment_as_invariant.md` 新設** |
| `bug_fix_survey` 規律 | `.claude/rules/bug_fix_survey.md` 強化 + `/continue` Step 4 chekclist inline |
| test stress axes | `.claude/rules/edge_case_testing.md` § "stress axes" 追加 + corpus design ADR |

### 3.6 Q6 — libc 依存境界

| 納品物 |
|---|
| ADR `0070_libc_dependency_policy.md` (necessary / replaceable / convenience 3 区分) |
| `.claude/rules/libc_boundary.md` (auto-load on `src/**/*.zig`) |
| ROADMAP §14 amendment ("Unconscious libc fanout" 禁止項目化) |
| `scripts/check_libc_boundary.sh` + `audit_scaffolding §G.5` 拡張 |
| Sample migration: `std.c.write` / `_exit` / `getenv` / `munmap` (~5-10 sites) → `std.posix.*` |

---

## 第 4 章 — Build-option DCE substrate アーキ案

### 4.1 全 layer 一貫パターン

`-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2}` × (将来) `-Denable=<features>` の **build option 軸** で、各 layer が **literal に "ない" 状態** を実現する。

### 4.2 ZirOp / validator / lower / JIT / interp

各 op が以下を export:

```zig
// src/instruction/wasm_X_Y/<op>.zig (canonical 形)
pub const op_tag: ZirOp = .i32_add;
pub const wasm_level: WasmLevel = .v1_0;
pub const enable_features: []const Feature = &.{};  // 将来用
pub const handlers = .{
    .validate = validate_i32_add,
    .lower    = lower_i32_add,
    .arm64    = emit_arm64_i32_add,
    .x86_64   = emit_x86_64_i32_add,
    .interp   = interp_i32_add,
};

fn validate_i32_add(ctx: *ValidatorCtx) !void { ... }
fn lower_i32_add(ctx: *LowerCtx)         !void { ... }
fn emit_arm64_i32_add(ctx: *Arm64EmitCtx) !void { ... }
fn emit_x86_64_i32_add(ctx: *X86_64EmitCtx) !void { ... }
fn interp_i32_add(ctx: *InterpCtx)       !void { ... }
```

中央 dispatch (各 axis ごとに 1 ファイル):

```zig
// src/ir/dispatch_collector.zig (新設)
const all_op_modules = collectAllOpModules();  // comptime
// comptime に src/instruction/wasm_X_Y/*.zig を全部 import + collect

pub fn validate(op: ZirOp, ctx: *ValidatorCtx) !void {
    return inline switch (op) {
        inline else => |tag| blk: {
            const op_mod = comptime opModuleFor(tag);
            if (comptime op_mod.wasm_level > build_options.wasm_level) {
                @compileError("op " ++ @tagName(tag) ++ " not in build (wasm_level=" ++ @tagName(build_options.wasm_level) ++ ")");
            }
            break :blk op_mod.handlers.validate(ctx);
        },
    };
}
```

`-Dwasm=v1_0` build で Wasm 2.0+ の `validate_*` 関数は **comptime に到達されず → binary に含まれない**。

### 4.3 CLI (`src/cli/`)

```zig
// src/cli/args.zig
pub const args = .{
    .{ .name = "--wasm-level",   .wasm_level = null,   .wasi_level = null,   .handler = handle_wasm_level },
    .{ .name = "--wasi-dir",     .wasm_level = null,   .wasi_level = .p1,    .handler = handle_wasi_dir },
    .{ .name = "--enable-gc",    .wasm_level = .v3_0,  .wasi_level = null,   .handler = handle_gc_flag },
};

pub fn parseArgs(...) !void {
    inline for (args) |arg| {
        if (comptime arg.wasm_level) |lvl| {
            if (comptime lvl > build_options.wasm_level) continue;  // 登録自体しない
        }
        if (comptime arg.wasi_level) |lvl| {
            if (comptime lvl > build_options.wasi_level) continue;
        }
        // arg は build に含まれる → parse 時の照合に登場
    }
}
```

`-Dwasm=v1_0` build で `--enable-gc` は parser の照合表に **登場しない** → `zwasm run --enable-gc foo.wasm` は "unknown argument: --enable-gc" になる。`zwasm --help` にも出ない。

### 4.4 C API (`src/api/wasm.zig` + `include/wasm.h`)

```zig
// src/api/wasm.zig (canonical pattern)
pub const exports = .{
    .{ .name = "wasm_module_new",      .wasm_level = null,   .impl = wasm_module_new },
    .{ .name = "wasm_v128_extract",    .wasm_level = .v2_0,  .impl = wasm_v128_extract },
    .{ .name = "wasm_gc_struct_new",   .wasm_level = .v3_0,  .impl = wasm_gc_struct_new },
};

comptime {
    for (exports) |e| {
        if (e.wasm_level) |lvl| {
            if (lvl > build_options.wasm_level) continue;  // export 自体しない
        }
        @export(e.impl, .{ .name = e.name, .linkage = .strong });
    }
}
```

`-Dwasm=v1_0` build で `wasm_v128_extract` シンボルは binary に存在しない (nm / dumpbin で出ない)。`include/wasm.h` 側は preprocessor `#if ZWASM_WASM_LEVEL >= 2` で declaration を gate (build.zig が `wasm.h` 用 header configure step を発生)。

### 4.5 WASI (`src/wasi/`)

同パターン。`wasi_p1_*` / `wasi_p2_*` の各 syscall が `wasi_level` metadata を持ち、build option で DCE。

### 4.6 全 layer 一貫の意義

- 1 機能を追加するとき、修正対象は **1 op file + (テスト) のみ**
- Feature が増えても dispatcher は変わらず (comptime collector が自動拡張)
- Bug があるとき、原因 op が一発で localize される (= "X 機能" を grep すれば 1 ファイルにヒット)
- Build option を加減すると **本当に消える/出る** → サイズ・依存・surface すべて影響

---

## 第 5 章 — Phase 9 完備 サブ行構成 + 納品物

### 5.1 サブ行一覧 (11 sub-row + 2 hard gate)

```
§9.12       🔒 Substrate audit decision gate (collab; ADR Accept のみ)
§9.12-pre   ADR drafts (Q2/Q3/Q4/Q5/Q6 + Q3 C 採用と DCE 軸) + 3 spike (autonomous)
§9.12-A     Iteration-speed scaffolding compression + enforcement layer 構築
§9.12-B     Q3 C 採択完成 (per-op file 全 op + comptime collector + build-option DCE 全 layer 拡張)
§9.12-C     Q5 hygiene landings (rules + lints + code)
§9.12-D     Q6 libc boundary
§9.12-E     Wasm 2.0 完備 100% (skip-impl 243 → 0 + 網羅テスト 4 系統 green)  ← Phase 9 完備の主軸 exit
§9.12-F     Phase-9-eligible debt cohort
§9.12-G     Phase 10 prep substrate (Wasm 3.0 slot 検証 + c_api テスト + CLI extensibility + Zone enforce)
§9.12-H     Bench baseline (Mac-only Wasm 2.0 + wasmtime 比較)
§9.12-I     ADR + lesson + private/ closure
§9.13-0     Cat IV windowsmini reconcile (D-084 / D-028 / D-136 + cross-platform sweep)
§9.13       🔒 Phase 10 entry gate (collab review)
```

### 5.2 依存 DAG

```
§9.12-pre (ADR drafts + spikes; autonomous)
   ↓
§9.12 (collab decision gate)
   ↓
§9.12-A (scaffolding compression + enforcement layer)  ← 以降の全 sub-row が enforcement に守られる
   ↓
§9.12-B (Q3 C 完成 + DCE 全 layer)
   ↓
§9.12-C (Q5 hygiene) ⇄ §9.12-D (Q6 libc) — 並行可
   ↓
§9.12-E (Wasm 2.0 100% drainage)  ← Phase 9 完備の主軸 exit
   ↓
§9.12-F (debt cohort) ⇄ §9.12-H (Bench) — 並行可
   ↓
§9.12-G (Phase 10 prep substrate)
   ↓
§9.12-I (ADR + lesson + private/ closure)
   ↓
§9.13-0 (windowsmini batch + cross-platform sweep)
   ↓
§9.13 🔒 (Phase 10 entry gate)
```

### 5.3 各サブ行の納品物 + Exit 条件

#### §9.12 — Substrate audit decision gate 🔒 (collab)

- 入力: §9.12-pre が autonomous で起草した ADR drafts + 3 spike measurement
- 納品: ユーザーが Q2-Q6 + Q3 C 採択 + Build-option DCE 全 layer 拡張 (ADR-0073) を Accept
- Exit: ROADMAP §1 / §2 P/A / §4.5 / §4.6 / §14 amendment が決定; ADR drafts が `Status: Accepted` 化
- 自律 loop: skip (collab session)

#### §9.12-pre — ADR drafts + 3 spikes (autonomous)

- ADR drafts (5-7 件):
  - ADR-0070 libc_dependency_policy
  - ADR-0071 phase9_substrate_audit_resolution (Q2 P14 sharpening + Q3 C 採択 + Q4 boundary)
  - ADR-0072 comment_as_invariant_rule (Q5)
  - ADR-0073 build_option_dce_substrate (build-option による DCE を全 layer 一貫で確立する原則)
  - ADR-0023 §4.5 amendment (per-op file pattern 正式採用)
  - (任意) ADR-0050 amendment (skip-impl one-way ratchet)
- Spike 3 件 (`private/spikes/`):
  - `q3-zig-inline-switch/` — 581-tag `inline switch (op) { inline else => |tag| { ... } }` の Zig 0.16 compile time + binary size 計測
  - `q3-interp-dispatch-bench/` — `DispatchTable.interp[op]` 間接 call vs zware `@call(.always_tail, ...)` の cycle 差
  - `q3-build-option-dce-poc/` — 代表 op (`i32.add`) を C パターンで実装し `-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2}` の 6 build で:
    - binary size 確認 (`-Dwasm=v1_0` が一番小さい)
    - symbol table 確認 (`-Dwasm=v1_0` に Wasm 2.0+ シンボル不在)
    - 全 build で test pass
- Exit: 5-7 ADR が `Status: Proposed` で land、3 spike が measurement + README で結論報告 → §9.12 collab review にバトンタッチ

#### §9.12-A — Scaffolding compression + enforcement layer 構築

##### Scaffolding compression

- `ROADMAP.md` Phase 0-8 narrative → `.dev/archive/roadmap_phase0_8.md` (-800-1000 LOC)
- `.claude/skills/continue/SKILL.md` 圧縮 — past anti-pattern を `LOOP.md` 経由で archive (-300 LOC)
- `.dev/phase8_transition_gate.md` (closed) → `.dev/archive/phase_gates/`
- `.dev/next-session-agenda.md` (338 LOC) 棚卸し
- `private/audit-*.md` 古い 5 件 → `private/archive/audits/`
- `private/notes/*.md` 棚卸し
- `private/spikes/break-inner/` / `d134_sigaction_shim/` archive
- 既存 8 gates (`zig fmt`, `zone_check`, `file_size_check`, `spill_aware_check`, `zig build lint`, `check_skip_adrs`, `check_adr_history`, `check_lesson_citing`, `check_invariant_comments`) の実行時間計測 + 統合余地検討 + noise reduction + skip rule 拡張

##### Enforcement layer 構築 (第 7 章詳細; ここで land)

- 第 7 章の 9 enforcement item をすべて実装し、gate_commit / pre-push / `audit_scaffolding` 各拡張に組み込み
- `bench/results/skip_impl_history.yaml` initialize (current 243 を baseline として seed)
- `.dev/p9_completion_progress.yaml` initialize (initial state)

- Exit: cold-start 読み込み目安 -40%; gate_commit 平均時間 -20%; 9 enforcement item すべて pre-commit / pre-push に hook 済み; ratchet history + progress tracker yaml seeded

#### §9.12-B — Q3 C 採択完成 + build-option DCE 全 layer 拡張

##### Per-op file 全 op 移行

- 残り Wasm 1.0 placeholder (`control.zig` / `parametric.zig` / `variable.zig`) 完成
- Wasm 2.0 placeholder (`multi_value.zig`) 完成
- SIMD-128 op を `src/engine/codegen/{arm64,x86_64}/op_simd*.zig` から `src/instruction/wasm_2_0/simd_128/<op>.zig` 配下に分離 (ADR-0023 §4.5 amend と整合)
- 各 op file が `pub const op_tag` / `wasm_level` / `enable_features` / `handlers = .{ .validate, .lower, .arm64, .x86_64, .interp }` を export することを comptime check で保証

##### 中央 collector + dispatcher

- `src/ir/dispatch_collector.zig` 新設 — `collectAllOpModules()` comptime function
- 5 dispatcher (`validator.zig`, `lower.zig`, `arm64/emit.zig`, `x86_64/emit.zig`, `interp/dispatch.zig`) を **inline switch + collector consumption** 形に書き直し
- Inline switch の compile-time wall に当たれば `inline switch` を tag 範囲で split (Cranelift `isle-split-match` 相当)

##### Build-option DCE 拡張

- ZirOp/validator/lower/JIT/interp 軸: 上記で確立
- **CLI** (`src/cli/args.zig`): 引数登録を declarative form (`args = .{ ... }`) に書き直し; `comptime` filter で build option DCE
- **C API** (`src/api/wasm.zig` + `include/wasm.h`): export 関数を declarative form (`exports = .{ ... }`); `comptime @export` filter; `wasm.h` 用 preprocessor gate
- **WASI** (`src/wasi/`): syscall を declarative form; `wasi_level` metadata; `comptime` filter

##### Test

- `-Dwasm=v1_0` / `v2_0` / `v3_0` × `-Dwasi=p1` / `p2` = 6 build 全部 green
- `test/build_completeness/` の build-DCE E2E が green

- Exit: `zig build -Dwasm=v1_0 -Dwasi=p1 test-all` 〜 `-Dwasm=v3_0 -Dwasi=p2 test-all` 全 green; `scripts/check_build_dce.sh` 0; per-op file 完全性 comptime check 通過

#### §9.12-C — Q5 hygiene landings

- `.claude/rules/comment_as_invariant.md` 新設
- `abi.zig` comptime disjointness check 拡張: `table_emit_scratch_gprs` / `memory_emit_scratch_gprs` named-constant array 化 + comptime assertion
- D-133 sweep: arm64 `op_table.zig` / `op_memory.zig` hardcoded X10/X11/X12 を named-constant 経由に
- `.claude/rules/edge_case_testing.md` に "stress axes" 節追加
- `audit_scaffolding §G` grep 追加 (D-132/D-133 検出強化)
- `.claude/rules/bug_fix_survey.md` 強化 + `/continue` Step 4 checklist inline
- `.claude/rules/runtime_instance_layer.md` 新設 (Cat III code layer 専用 zone rule)
- Exit: D-133 closed; comment_as_invariant rule land; audit grep 検出 0 件; rule auto-load 確認

#### §9.12-D — Q6 libc boundary

- ADR-0070 `libc_dependency_policy.md` (`Status: Accepted`)
- `.claude/rules/libc_boundary.md` (auto-load)
- ROADMAP §14 amendment
- `scripts/check_libc_boundary.sh` + `audit_scaffolding §G.5` 拡張
- Sample migration: `std.c.write` / `_exit` / `getenv` / `munmap` ~5-10 sites → `std.posix.*`
- Exit: `bash scripts/check_libc_boundary.sh` 0; 全 host で test-all green

#### §9.12-E — Wasm 2.0 完備 100% ★ (Phase 9 完備の主軸 exit)

##### 主タスク

- **SKIP-CROSS-MODULE-IMPORTS 100 modules**: `hasUnbindableImports()` の reject 条件を緩める + 各 import-shape class に対応する resolver 追加 (imports / elem / data / linking / table* / memory* / global)
- **SKIP-NO-LINK-TYPECHECK 26**: `Instance.checkImportType()` 実装 + `applyAssertUnlinkable` callback
- **SKIP-VALIDATOR-GAP SIMD 50**: `simd_lane` (lane index range) + `simd_align` (alignment immediate range) の `assert_invalid` 対応
- **`exports/manifest.txt` non-invoke-action 1**: action dispatcher 拡張 (`get` / `set` directive)
- **D-079 v128 cross-module imports (ii)**: ADR-0052 §3 globals 拡張

##### 網羅テスト 4 系統 (要件 (2) の「保証する網羅的テスト」)

- spec corpus (`test-spec-wasm-2.0-assert` + `test-spec-simd`): **skip-impl == 0** (Mac + ubuntunote bit-identical)
- edge_cases corpus (`test-edge-cases`): 全 PASS — 新 fixture が必要なら land
- realworld corpus (Wasm 2.0 範囲の TinyGo / Rust): 全 PASS (emcc 系は D-026 Phase 11 deferred)
- differential vs wasmtime (`test-wasmtime-misc-runtime`): 全 PASS
- 各 ZirOp の unit test カバレッジ: 全 op カバー (`grep -c 'test \"' src/instruction/wasm_{1_0,2_0}/**/*.zig`)

##### Exit 条件 (literal)

- `spec_assert_runner_non_simd: N passed, 0 failed, 495 skipped (= 0 skip-impl + 495 skip-adr)` Mac + ubuntunote bit-identical
- `simd_assert_runner: 13301 passed, 0 failed, 390 skipped (= 0 skip-impl + 390 skip-adr)` Mac + ubuntunote bit-identical
- 4 testsuite 系統 (spec / edge_cases / realworld / differential) すべて green
- `scripts/check_skip_impl_ratchet.sh` 0 (= ratchet が 0 を維持; 後の chunk が増やせない)

#### §9.12-F — Phase-9-eligible debt cohort

| Row | Action |
|---|---|
| D-094 | x86_64 multi-result indirect-result-buffer discharge or confirm dissolved by D-140 / D-148 chain |
| D-090 | lower.zig type-stack walker (validator mirror) |
| D-062 | arm64 v128 9th+ stack overflow path |
| D-141 | file_size_check WARN 20 files — Q3 C 採用で大部分 dissolve; 残り個別 ADR |
| D-081 | emit.zig source split — Q3 C 採用で dissolve 確認 |
| D-055 | emit_test_*.zig migration |

- Exit: debt active rows < 15

#### §9.12-G — Phase 10 prep substrate

- ZirOp Wasm 3.0 slot ↔ Wasm spec 番号対応表を `.dev/wasm_3_0_zirop_mapping.md` に出力 (`dispatch_collector.zig` が machine-generate)
- `src/instruction/wasm_3_0/` の placeholder ファイルを Phase 10 features 全体に拡張 (GC / EH / tail-call / memory64 / multi-memory / typed func refs 全 features に placeholder)
- `src/api/instance.zig` (1424 LOC) health audit + helper extraction (D-139 前倒し discharge): c_api Instance-path test を最小カバレッジ追加 (instantiate / call / drop / destroy / cross-module / multi-result)
- CLI `--invoke <fn> <args>` mode 追加 (Phase 11 bench で必要)
- `include/wasm.h` 上流 diff チェック
- `bash scripts/zone_check.sh --gate` 移行 (info → enforce); zone violation 0 確認
- `.dev/architecture/zone_layout.md` 新設 (ROADMAP §A1 抽出 + 最新化)
- Exit: Phase 10 features の全 ZirOp が `comptime` で `Error.UnsupportedOpForBuildLevel` reject (= Phase 10 で `comptime` guard 緩めるだけで実装着手可); `zone_check --gate` 0; c_api 基本 path テスト land

#### §9.12-H — Bench baseline (Mac-only Wasm 2.0 + wasmtime 比較)

- `scripts/run_bench.sh --compare=wasmtime` flag 追加 (~150 LOC)
- `--capture-rss` via `/usr/bin/time -l` (Mac)
- Mac aarch64 ReleaseSafe で 26 fixtures × hyperfine `--warmup 3 --runs 5`
- `bench/results/history.yaml` に `runtime: zwasm` / `runtime: wasmtime` 別 row 追加
- D-074 partial 解消 (wazero / wasmer / bun / node + `-Dwith-bench-compare` flag は Phase 11)
- Exit: history.yaml に "p9-close: Wasm-2.0 baseline (Mac aarch64)" row; zwasm vs wasmtime mean_ms ratio doc 化

#### §9.12-I — ADR + lesson + private/ closure

- D-149 discharge: ADR Phase-9 cohort SHA backfill (75 placeholders → 0); commit `chore(adr): SHA backfill — Phase 9 完備 cohort`
- ADR Status canonical pass: ~22-25 件 `Accepted` → `Closed (Phase X DONE)` (Phase 1-8 終了済のもの)
- `skip_cross_module_register.md` Status 文言 canonical 化
- `skip_cross_module_action.md` Status re-eval (§9.12-E 完了で `Closed (Phase 9 §9.12-E DONE)` 化)
- Lesson backfill: `2026-05-18-class-c-callee-without-caller-segvs-fac.md` Citing 埋め
- Lesson promotion 候補スキャン (3+ citations のものは ADR 化)
- Exit: `check_adr_history.sh --gate` 0; `check_lesson_citing.sh` 0; ADR `Accepted` 数 < 30

#### §9.13-0 — Cat IV windowsmini reconcile + cross-platform sweep

- windowsmini に reset + `zig build test-all` 実行
- D-084 (Win64 v128 marshal residual)
- D-136 (Win64 SEH bridge for assert_trap recovery)
- D-028 (windowsmini SSH IPC flake re-eval)
- Q6 で出た新規 `std.posix.*` 移行で Windows 互換性確認
- Q3 C wasm_level guard が `-Dtarget=x86_64-windows-gnu` で機能するか
- Build-option DCE が Windows build でも効くか確認
- Exit: windowsmini `test-all` 3-host bit-identical; `skip-impl == 0` 全 3 host; `should_gate_windows.sh --record` で gating 復活

#### §9.13 — Phase 10 entry gate 🔒 (collab)

- `.dev/phase10_transition_gate.md` collab review
- Phase 10 scope / Wasm 3.0 feature order / Track D 確認
- Phase Status widget flip: Phase 9 = DONE, Phase 10 = IN-PROGRESS
- Exit: ユーザー [x]

---

## 第 6 章 — ROADMAP 修正案

### 6.1 §9 表

| Row | Status |
|---|---|
| 9.9 | [x] (現行のまま) |
| 9.9-II | [x] `fb063b09` |
| 9.9-III | [x] `2dbd3f15` |
| 9.9-IV | [~] moved to §9.13-0 |
| 9.10 | [~] moved to Phase 11 |
| 9.11 | [x] `f06a3c9b` |
| **9.12** | 🔒 [ ] (Substrate audit decision gate; collab; ADR Accept only) |
| **9.12-pre** | [ ] (ADR drafts + 3 spikes; autonomous) |
| **9.12-A** | [ ] (Scaffolding compression + enforcement layer 構築) |
| **9.12-B** | [ ] (Q3 C 採択完成 + build-option DCE 全 layer 拡張) |
| **9.12-C** | [ ] (Q5 hygiene landings) |
| **9.12-D** | [ ] (Q6 libc boundary) |
| **9.12-E** | [ ] (★ Wasm 2.0 完備 100% — skip-impl 243 → 0 + 網羅テスト 4 系統) |
| **9.12-F** | [ ] (Phase-9-eligible debt cohort) |
| **9.12-G** | [ ] (Phase 10 prep substrate) |
| **9.12-H** | [ ] (Bench baseline) |
| **9.12-I** | [ ] (ADR + lesson + private/ closure) |
| 9.13-0 | [ ] (Cat IV windowsmini + cross-platform sweep) |
| 9.13 | 🔒 [ ] (Phase 10 entry gate; collab) |

### 6.2 Phase Status widget 文言

修正前:
> | 9 | IN-PROGRESS | Wasm 1.0 + 2.0 (incl. SIMD) 完備 on 3 hosts (per ADR-0056 + ADR-0065) |

修正後 (§9.12 collab gate で ADR-0071 が Accepted になった後の commit で適用; 本セッションでは変更しない):
> | 9 | IN-PROGRESS | Wasm 1.0 + 2.0 (incl. SIMD) **literal 100%** (skip-impl == 0 across spec + edge_cases + realworld + differential) on 3 hosts + Phase 10 substrate readiness (build-option DCE 全 layer; per ADR-0056 + ADR-0065 + ADR-0071 + ADR-0073) |

### 6.3 ADR 新規 / amend

| 動作 | ADR | 内容 |
|---|---|---|
| 新規 | **ADR-0070** | `libc_dependency_policy.md` (Q6) |
| 新規 | **ADR-0071** | `phase9_substrate_audit_resolution.md` (Q2 P14 sharpening + Q3 C 採択 + Q4 boundary) |
| 新規 | **ADR-0072** | `comment_as_invariant_rule.md` (Q5) |
| 新規 | **ADR-0073** | `build_option_dce_substrate.md` (build-option による DCE を全 layer 一貫で確立する原則) |
| Amend | ADR-0023 §4.5 | per-op file pattern 正式採用; DispatchTable interp 軸 required, validator/lower/emit/jit 軸 = per-op file |
| Amend | ADR-0056 / ADR-0065 | Revision history 追加 |
| Amend | ADR-0050 | skip-impl one-way ratchet 追加 (D-3 / D-4) |
| Amend | ADR-0062 §9.12 row text | 実装 sub-rows 9.12-A..I を §9.12 から外したことを明記 |

### 6.4 ROADMAP §14 forbidden list amendment

追加項目: "Unconscious libc fanout (new `std.c.*` calls without ADR justification or rule exception)" with cite to ADR-0070.

追加項目: "skip-impl 数を増やす方向の変更 (ADR で justify されない場合)" with cite to ADR-0050 D-3.

### 6.5 §18 amendment policy 該当性

- §9 表のサブ行追加 = **routine status update** (§18 ADR 不要)
- Phase Status widget 文言変更 = **load-bearing** = ADR-0071 で覆う
- §14 amendment = **load-bearing** = ADR-0070 + ADR-0050 amend で覆う
- §4.5 amend = **load-bearing** = ADR-0023 amend で覆う

---

## 第 7 章 — あきらめないための機械的 enforcement layer (9 item)

「諦め方向への変化」が gate / lint / `@compileError` / audit で **物理的にブロック** される substrate。§9.12-A で全部 land。

### 7.1 Build-option DCE 強制

| Deliverable | 着地 | Fire timing |
|---|---|---|
| `scripts/check_build_dce.sh` | gate_commit + gate_merge | pre-commit (subset) + pre-push (full) |
| `audit_scaffolding §H` (新) | 既存 skill 拡張 | 定期 audit |
| `test/build_completeness/` + `test-build-completeness` step | build.zig + test-all | per chunk gate |

内容: 6 build option 組み合わせ (`-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2}`) で build + symbol table grep + binary size 確認。`-Dwasm=v1_0` build に `wasm_2_0_*` シンボルが残っていたら FAIL。

### 7.2 Per-op file 完全性

| Deliverable | 着地 | Fire timing |
|---|---|---|
| `src/ir/dispatch_collector.zig` (新) | comptime check | `zig build` で即発火 |

内容: 全 ZirOp tag を enumerate; 対応する `src/instruction/wasm_X_Y/<op>.zig` が無い → `@compileError`; 各 op file が `op_tag` / `wasm_level` / `handlers = .{...5軸...}` のいずれかを欠落 → `@compileError`。Compile error 文言は「何が欠けているか」+「どこに足すか」を含む。

### 7.3 Skip-impl one-way ratchet

| Deliverable | 着地 | Fire timing |
|---|---|---|
| `scripts/check_skip_impl_ratchet.sh` | pre-push + CI | pre-push hook |
| `bench/results/skip_impl_history.yaml` | git-tracked | 各 chunk close 時に row 追加 |
| `audit_scaffolding §F.5b` (新) | 既存 skill 拡張 | 定期 audit |

内容: 現 commit の skip-impl 数を前 commit と比較; 増えていたら FAIL。例外は ADR で justify + yaml に `exempt: <ADR-NNNN>` で登録。ADR 無しの skip-impl 増加は不可能。

### 7.4 諦め検知 (anti-workaround / anti-fallback)

| Deliverable | 着地 | Fire timing |
|---|---|---|
| `.claude/rules/no_fallback_on_failure.md` (新) | auto-load on `src/**/*.zig` | 編集時 |
| `.claude/rules/no_workaround.md` 既存 | 強化 (SKIP-* 増加禁止文言追加) | 編集時 |
| `scripts/check_fallback_patterns.sh` (新) | pre-commit | pre-commit hook |
| `audit_scaffolding §G.6` (新) | 既存 skill 拡張 | 定期 audit |

内容: `catch {}` / `catch \|err\| return null` / `catch \|err\| default` / `catch \|err\| switch (err) { else => skip }` などの silent-degradation pattern を禁止。エラーは必ず named error として propagate するか、ADR で正当化された exhaustive switch のみ。

### 7.5 Spike lifecycle 強制

| Deliverable | 着地 | Fire timing |
|---|---|---|
| `.claude/rules/spike_lifecycle.md` (新; `extended_challenge.md` Step 4 抽出 + 強化) | auto-load on `private/spikes/**` | 編集時 |
| `scripts/audit_spikes.sh` 既存 | 強化 (lifecycle 違反検出) | 定期 audit |
| `audit_scaffolding §G.4` 既存 | 拡張 (reject lesson land 確認) | 定期 audit |

内容: spike は Status ∈ {running, merged-into-prod, rejected, archived}; rejected/archived 時に lesson 必須; running > 14d で audit flag。「実験はいいが結果を記録せず捨てるのは禁止」。

### 7.6 Chunk-close literal exit gate

| Deliverable | 着地 | Fire timing |
|---|---|---|
| `scripts/check_subrow_exit.sh` (新) | pre-push hook | pre-push when `[x]` flip 含む |
| ROADMAP §9.12-X 各 sub-row の exit 条件 | 明文化 (automated-checkable form) | 既存編集 |
| `audit_scaffolding §K` (新) | 既存 skill 拡張 | 定期 audit |

内容: sub-row の `[x]` flip が含まれる commit は exit 条件が literally 満たされているかチェック。例: §9.12-E close commit は skip-impl == 0 物理確認; §9.12-B close commit は build_completeness 全 green 確認。

### 7.7 Q3 C 設計整合性 audit

| Deliverable | 着地 | Fire timing |
|---|---|---|
| `.claude/skills/dispatch_consistency_audit/SKILL.md` (新) | slash-command 可能 skill | 任意 invocation |
| `audit_scaffolding §H` 包含 | 既存 skill 拡張 | 定期 audit (boundary 時 fire) |

内容: ZirOp tag count = per-op file count = 5 軸 handler 実装 count の三位一致確認; feature_level metadata 整合性; build option 別の DCE が期待通り効くかサンプリング確認。

### 7.8 Phase 9 完備 progress tracker (machine-readable)

| Deliverable | 着地 | Fire timing |
|---|---|---|
| `.dev/p9_completion_progress.yaml` | git-tracked | 各 chunk close で update |
| `scripts/p9_completion_status.sh` (新) | live status | 手動 + Step 0.5b |
| `.claude/rules/no_handover_predictions.md` 既存 | 適用 | (既存規律) |

内容: sub-row × op × layer の matrix で migration 進捗。`bash scripts/p9_completion_status.sh` で **現在 yaml と source の整合性 + 残工程の概要** を出力 (§9.9 期の `p9_simd_status.sh` の Phase-9-完備版)。

### 7.9 Feature-level metadata の comptime 検証

| Deliverable | 着地 | Fire timing |
|---|---|---|
| `src/ir/feature_level_check.zig` (新) | comptime | `zig build` で発火 |
| `.dev/spec_compliance_table.md` | doc | machine-generated by dispatch_collector |

内容: 各 op の `wasm_level` と Wasm spec の対応を comptime check; spec 定義との乖離を `@compileError`。

### 7.10 まとめ — 何が物理的に不可能になるか

| ID | 不可能化される事象 |
|---|---|
| 7.1 | `-Dwasm=v1_0` build に Wasm 2.0/3.0 コードが紛れること |
| 7.2 | 新規 ZirOp tag を per-op file 無しで追加すること |
| 7.3 | skip-impl 数を増やす方向の変更 (ADR 無しで) |
| 7.4 | エラーを silent に握り潰す / fallback で逃げること |
| 7.5 | spike を結果記録なしで放置 / 削除すること |
| 7.6 | sub-row を [x] flip するときに exit 条件が満たされていない状態で commit すること |
| 7.7 | dispatch consistency (3 ファイル軸の不一致) を放置すること |
| 7.8 | 進捗 narrative を予測 / fiction で書くこと (live measurement のみ) |
| 7.9 | 間違った feature_level metadata を op file に付与すること |

これらすべてが gate / lint / `@compileError` / audit で fire する状態にしてから §9.12-B 以降に入る (= §9.12-A で land)。

---

## 第 8 章 — インクリメンタル工程 + spike 運用

### 8.1 Spike の役割

- **発見系**: 未知の Zig 0.16 挙動 (`inline switch` 581-tag wall 等)、ABI 詳細 (D-148 Codeberg #35343 系)、ホスト固有挙動 (D-134 系) を localize
- **検証系**: 設計案の PoC (`q3-build-option-dce-poc` のような E2E 確認)
- **比較系**: 代替アプローチ間の cycle/size/maintainability 比較 (`q3-interp-dispatch-bench`)

各 spike は self-contained で消せる (= `private/spikes/<name>/`)。production への取り込み時に `merged-into-prod` Status へ; 不採用は `rejected` + lesson 必須 (7.5 enforcement)。

### 8.2 工程の刻み方

- 1 chunk = 1 op or 1 layer migration or 1 enforcement 着地 (小さい単位)
- 失敗したら pinpoint revert; 同じ commit を amend しない (`/continue` LOOP.md の規律通り)
- progress tracker yaml (7.8) で「どこまで進んだか」を machine-readable に
- handover は live measurement の引用のみ; 予測ゼロ (7.8 規律)

### 8.3 駄目筋を切り戻す手順

1. Spike か本実装か判定
2. Spike なら `Status: rejected` + lesson land + 削除
3. 本実装なら `git revert <chunk-sha>` で commit ピンポイント取り消し
4. ratchet history (7.3) に "rolled back, ADR-NNNN" entry 追加
5. 別アプローチで再度 spike から

### 8.4 「労力厭わず」の意味

- enforcement layer (第 7 章) が物理的にブロックする「諦め」を **試みない**
- 妥協方向への変化は gate で必ず止まる → 別ルートを spike で探す
- spike を 3-5 回試してから best のものを取り込む、は許容
- 「とりあえず skip して進める」を **substrate が拒否**

---

## 第 9 章 — 進め方の提案 + 次の continue で着手可能な状態

### 9.1 本セッションで setup 完了する項目 (autonomous)

1. 本マスター計画書を `.dev/phase9_completion_close_plan.md` に promote (git-tracked)
2. ROADMAP §9 サブ行展開 (§9.12 / §9.12-pre / §9.12-A..I / §9.13-0 / §9.13)
3. Phase Status widget 文言更新
4. handover.md 更新 — 次の `/continue` が §9.12-pre から autonomous で着手可能な形に
5. ADR-0070 / 0071 / 0072 / 0073 の **skeleton** (Status: Proposed; Context + Decision placeholder; References) + ADR-0050 / ADR-0023 の **amend skeleton** (Revision history 行を追加; 本文 amend draft) を `.dev/decisions/` に land
6. `.claude/rules/` 新規 rule の **skeleton** (no_fallback_on_failure / spike_lifecycle / comment_as_invariant / libc_boundary / runtime_instance_layer / incremental_substrate_migration)
7. `.claude/skills/dispatch_consistency_audit/SKILL.md` の **skeleton**
8. `scripts/` 新規 enforcement script の **skeleton** (実行可能 shebang + 基本 grep/check; 完成は §9.12-A 中で)
9. `bench/results/skip_impl_history.yaml` を current 243 で seed
10. `.dev/p9_completion_progress.yaml` を initial state で seed
11. `phase9_completion_substrate_audit.md` を Q3 C 採択 tentative に update (substrate audit 完了予定)
12. `private/notes/` archive (古い survey は keep; spike skeleton は次 session で create)

本セッションでの commit 単位:

- **commit 1**: `chore(p9b): Phase 9 完備 master plan + ROADMAP §9.12 sub-row 展開` — master plan promote + ROADMAP + handover + substrate audit doc update
- **commit 2**: `chore(p9b): enforcement scaffold — rules + skills + scripts + seed yaml skeletons` — `.claude/rules/` + `.claude/skills/` + `scripts/` + `bench/results/skip_impl_history.yaml` + `.dev/p9_completion_progress.yaml`
- **commit 3**: `chore(p9b): ADR skeletons — 0070 / 0071 / 0072 / 0073 + 0050 / 0023 amend drafts`

### 9.2 次のセッションで `/continue` 起動後に走る工程

1. handover の Cold-start procedure に従って §9.12-pre を識別
2. §9.12-pre 着手 — ADR drafts を populate (skeleton を実 ADR に); spike 3 件を実装 + 計測
3. すべて land 後、§9.12 collab gate を fire → ユーザーに Q2-Q6 + ADR Accept をリクエスト
4. ユーザー Accept で §9.12-A 以降が autonomous で進行

### 9.3 確信度

- 第 2 章 ground truth: HIGH (実測)
- 第 3 章 Q3 C 採択: HIGH (設計品質軸で他案を上回る)
- 第 4 章 DCE substrate arch: HIGH (spike `q3-build-option-dce-poc` で実証予定)
- 第 5 章 サブ行 + 納品物: HIGH
- 第 6 章 ROADMAP 修正案: HIGH (機械的)
- 第 7 章 enforcement layer: HIGH (各 item は既存パターン (gate / rule / audit) の延長)
- 第 8 章 インクリメンタル工程: HIGH (既存 /continue loop 運用と整合)
- 第 9 章 セットアップ: HIGH (本セッション内で完了させる)

---

## 第 10 章 — 参照

### 10.1 作業ファイル (gitignored, private/)

- `private/notes/p9-close-bench-survey.md` (v1 + OSS bench infra)
- `private/notes/p9-close-q3-arch-survey.md` (Q3 仮説 vs OSS, 942 行)
- `private/notes/p9-close-skip-impl-inventory.md` (243 skip-impl 内訳)
- `private/notes/p9-close-inventory.md` (debt + ADR + scaffolding)
- `private/notes/p9-close-phase10-readiness.md` (C API / build flags / ZirOp)
- `private/notes/p9-close-master-design.md` (第 1 ドラフト)
- `private/notes/p9-close-self-review.md` (自己レビュー)
- `private/notes/p9_close_master_plan_ja_v1.md` (v1 = 旧計画)
- `private/notes/p9_close_master_plan_ja.md` (本ファイル v2)

### 10.2 git-tracked target (本セッションで land)

- `.dev/phase9_completion_close_plan.md` (本計画の committed 版)
- `.dev/ROADMAP.md` (§9 サブ行 + Phase Status widget)
- `.dev/handover.md` (§9.12-pre cold-start)
- `.dev/decisions/0070_libc_dependency_policy.md` (skeleton)
- `.dev/decisions/0071_phase9_substrate_audit_resolution.md` (skeleton)
- `.dev/decisions/0072_comment_as_invariant_rule.md` (skeleton)
- `.dev/decisions/0073_build_option_dce_substrate.md` (skeleton)
- `.dev/phase9_completion_substrate_audit.md` (Q3 C tentative update)
- `.claude/rules/no_fallback_on_failure.md` (skeleton)
- `.claude/rules/spike_lifecycle.md` (skeleton)
- `.claude/rules/comment_as_invariant.md` (skeleton)
- `.claude/rules/libc_boundary.md` (skeleton)
- `.claude/rules/runtime_instance_layer.md` (skeleton)
- `.claude/rules/incremental_substrate_migration.md` (skeleton)
- `.claude/skills/dispatch_consistency_audit/SKILL.md` (skeleton)
- `scripts/check_build_dce.sh` (skeleton, executable)
- `scripts/check_skip_impl_ratchet.sh` (skeleton)
- `scripts/check_fallback_patterns.sh` (skeleton)
- `scripts/check_subrow_exit.sh` (skeleton)
- `scripts/check_libc_boundary.sh` (skeleton)
- `scripts/p9_completion_status.sh` (skeleton)
- `bench/results/skip_impl_history.yaml` (seed; current 243 baseline)
- `.dev/p9_completion_progress.yaml` (initial state)

### 10.3 既存参照

- `.dev/ROADMAP.md` (Phase Status widget at line 1175 area; §9.12 sub-row table at 1665+)
- `.dev/phase9_completion_substrate_audit.md` (Q2-Q6 質問詳細; ADR-0062 anchor)
- `.dev/phase10_transition_gate.md` (§9.13 hard gate doc)
- `.dev/debt.md` (28 active rows; 6 now)
- ADR-0023 (src directory structure; §4.5 amend 候補)
- ADR-0029 (skip-impl/skip-adr semantics)
- ADR-0050 (ADR lifecycle / Status canonical)
- ADR-0056 (Phase 9 scope extension)
- ADR-0062 (substrate audit gate anchor)
- ADR-0065 (Wasm 1.0 instance work Phase 9 rescope)
