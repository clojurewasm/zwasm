# 0073 — Build-option による全 layer 一貫 DCE substrate

- **Status**: Proposed
- **Date**: 2026-05-19
- **Author**: continue loop §9.12 substrate audit cycle (2026-05-19 user フィードバック反映)
- **Tags**: phase-9, substrate, build-option, dce, feature-flag, all-layer-consistent

> **状態**: skeleton。§9.12-pre で full draft に展開 (実装詳細 + 3 spike 計測結果含)。

## Context

ユーザー 2026-05-19 フィードバック (Q3 採択方針):

> Build-option (`-Dwasm` / `-Dwasi` / `-Denable`) ではじくと、その機能のコードが
> **literal に "ない"** = コマンドライン引数も存在しない = 機能的にも使えない
> という設計にしたい。当初これを意識していなかったため分岐が散る可能性が高いが、
> インクリメンタル + spike で進める価値あり。

現状の事実:
- `build.zig` で `-Dwasm=v1_0|v2_0|v3_0` (default v3_0), `-Dwasi=p1|p2` (default
  p1), `-Dengine=interp|jit|both` 等 declared
- 但し `build_options.wasm_level` consultation は CLI `main.zig` の diagnostic 2
  か所 + `diagnostic/trace.zig` のみ
- validator / lower / emit / runtime / c_api / CLI / WASI どこも build-option で
  feature gate していない (全 levels 含む binary が常に生成)
- `src/instruction/wasm_X_Y/<op>.zig` の placeholder 構造は既存 (3514 LOC populated)
  だが、build-option DCE pattern は未確立

## Decision

**Build-option による DCE を全 layer で同一パターンで確立** する。

### 全 layer 共通パターン

各 declarative element (op / CLI arg / c_api export / WASI syscall) が:

```zig
pub const wasm_level: ?WasmLevel = ...;   // null = 全 build で有効
pub const wasi_level: ?WasiLevel = ...;
pub const enable_features: []const Feature = &.{};  // 将来用
```

中央 collector (各 layer 1 ファイル):

```zig
inline for/switch (registered_elements) |e| {
    if (comptime e.wasm_level) |lvl| {
        if (comptime lvl > build_options.wasm_level) continue;  // または @compileError
    }
    // ... element の登録 or dispatch
}
```

`-Dwasm=v1_0` build では Wasm 2.0+ の handler / CLI arg / c_api export / WASI
syscall が **comptime に到達されない → binary に存在しない**。

### 各 layer の具体

#### Layer 1: ZirOp + validator + lower + JIT + interp

`src/instruction/wasm_X_Y/<op>.zig` が `pub const handlers = .{...5軸...}` を
export。`src/ir/dispatch_collector.zig` (新設) が comptime に全 op file を import +
filter + 中央 dispatcher (`validator.zig`, `lower.zig`, `arm64/emit.zig`,
`x86_64/emit.zig`, `interp/dispatch.zig`) を `inline switch` で構築。

#### Layer 2: CLI (`src/cli/`)

CLI 引数を declarative form (`args = .{ ... }`) で宣言。各 arg が `wasm_level` /
`wasi_level` metadata を持ち、parser の comptime filter で build option DCE。
`-Dwasm=v1_0` build で `--enable-gc` 引数は parser に存在せず "unknown
argument" になる。`zwasm --help` にも出ない。

#### Layer 3: C API (`src/api/wasm.zig` + `include/wasm.h`)

C API export 関数を declarative form (`exports = .{ ... }`); comptime
`@export(...)` filter で symbol DCE。`include/wasm.h` 側は build.zig の header
configure step で `#if ZWASM_WASM_LEVEL >= 2` 等の preprocessor gate を生成。
`-Dwasm=v1_0` build で `wasm_v128_extract` シンボルは nm / dumpbin で出ない。

#### Layer 4: WASI (`src/wasi/`)

WASI syscall も同パターン。`wasi_p1_*` / `wasi_p2_*` が `wasi_level` metadata を
持ち、build option で DCE。

### Enforcement (ADR-0071 と整合)

- `scripts/check_build_dce.sh` — 6 build option 組合せで symbol table grep + size 確認
- `audit_scaffolding §H` (新) — DCE が壊れる兆候を flag
- `test/build_completeness/` — E2E test (各 build で機能が "ない" ことを確認)

## Alternatives considered

> Skeleton — §9.12-pre で実装 detail + 3 spike 計測結果込みで展開。

### Alternative — runtime feature toggle (Wasmer 流儀)

- Sketch: 1 binary に全機能含み、runtime の `--wasm-level` で reject
- 不採用: build-option による真の DCE = "binary に literal に無い" を満たさない。攻撃面積 / size 削減目的に合わない。
- 補完: runtime option は **同時並存可** (= runtime に build 含まれる中から更に絞れる)。デフォルト build (`-Dwasm=v3_0`) は全機能含み、`--wasm-level=2.0` 引数で runtime に降格できる二段制御。

### Alternative — build option 軸を ZirOp layer のみで確立

- Sketch: CLI / c_api / WASI への拡張を Phase 10 に持ち越す
- 不採用: ユーザー要件 (4) "Phase 10+ で困らない" 設計を満たさない。全 layer 一貫が要件。

## Consequences

- **Positive**:
  - `-Dwasm=v1_0` build が literal に minimal binary (size + 攻撃面積)
  - CLI / c_api / WASI が build option で機能 surface 全部消える
  - 同一パターン (`declarative form + comptime filter`) で 4 layer が統一 → 新 layer
    追加時の boilerplate 既知
  - Phase 10 で Wasm 3.0 feature 追加時、build option `-Dwasm=v3_0` のみで全 layer
    の handler が一斉に有効化

- **Negative**:
  - 既存 5 dispatcher を inline switch + collector consumption に書き直し
  - CLI / c_api / WASI の declarative form 化 (既存コードの reshape)
  - Zig 0.16 の `inline switch (op) { inline else => |tag| ... }` が 581 tags で
    compile-time wall に当たる可能性 → §9.12-pre spike で計測

- **Neutral / follow-ups**:
  - `inline switch` wall に当たれば tag 範囲 split (Cranelift `isle-split-match`
    相当) で回避
  - `wasm.h` の preprocessor gate 生成は build.zig の `addConfigHeader` で可能か
    要確認

## References

- ROADMAP §2 P14 (sharpening), §4.5 (per-op file pattern), §4.6 (build flags)
- ADR-0023 (src directory structure; §4.5 amend ペア)
- ADR-0071 (Phase 9 substrate audit resolution; Q3 採用根拠)
- ADR-0050 (skip-impl one-way ratchet と整合)
- ユーザーフィードバック 2026-05-19 (build-option DCE 軸採用)
- 3 spike: `private/spikes/q3-zig-inline-switch/`, `q3-interp-dispatch-bench/`,
  `q3-build-option-dce-poc/` (§9.12-pre で create + 計測)

## Revision history

| Date       | SHA          | Note                                                                              |
|------------|--------------|-----------------------------------------------------------------------------------|
| 2026-05-19 | `<backfill>` | Initial skeleton — build-option DCE substrate; full draft + 3 spike in §9.12-pre. |
