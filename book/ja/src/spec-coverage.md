# 仕様カバレッジ

zwasm は WebAssembly 3.0 への完全準拠を目指しています。すべての仕様テストが macOS ARM64 および Linux x86_64 で合格しています。

**テスト結果**: 62,158 / 62,158 (100.0%)

## コア仕様

| 機能 | オペコード数 | ステータス |
|------|-------------|-----------|
| MVP (core) | 172 | 完了 |
| Sign extension | 7 | 完了 |
| Non-trapping float-to-int | 8 | 完了 |
| Bulk memory | 9 | 完了 |
| Reference types | 5 | 完了 |
| Multi-value | - | 完了 |
| **コア合計** | **201+** | **100%** |

## SIMD

| 機能 | オペコード数 | ステータス |
|------|-------------|-----------|
| SIMD (v128) | 236 | 完了 |
| Relaxed SIMD | 20 | 完了 |
| **SIMD 合計** | **256** | **100%** |

## Wasm 3.0 プロポーザル

9 つの Wasm 3.0 プロポーザルすべてが完全に実装されています:

| プロポーザル | オペコード数 | 仕様テスト | ステータス |
|-------------|-------------|-----------|-----------|
| Memory64 | 既存を拡張 | Pass | 完了 |
| Tail calls | 2 | Pass | 完了 |
| Extended const | 既存を拡張 | Pass | 完了 |
| Branch hinting | メタデータセクション | Pass | 完了 |
| Multi-memory | 既存を拡張 | Pass | 完了 |
| Relaxed SIMD | 20 | 85/85 | 完了 |
| Exception handling | 3 | Pass | 完了 |
| Function references | 5 | 104/106 | 完了 |
| GC | 31 | Pass | 完了 |

## 追加プロポーザル

| プロポーザル | オペコード数 | ステータス |
|-------------|-------------|-----------|
| Threads | 79 (0xFE prefix) | 完了 (310/310 spec) |
| Wide arithmetic | 4 | 完了 (99/99 e2e) |
| Custom page sizes | - | 完了 (18/18 e2e) |

## WASI Preview 1

46 / 46 システムコール実装済み (100%):

| カテゴリ | 数 | 関数 |
|---------|-----|------|
| args | 2 | args_get, args_sizes_get |
| environ | 2 | environ_get, environ_sizes_get |
| clock | 2 | clock_time_get, clock_res_get |
| fd | 14 | read, write, close, seek, stat, prestat, readdir, ... |
| path | 8 | open, create_directory, remove, rename, symlink, ... |
| proc | 2 | exit, raise |
| random | 1 | random_get |
| poll | 1 | poll_oneoff |
| sock | 4 | NOSYS スタブ |

## Component Model

| 機能 | ステータス |
|------|-----------|
| WIT パーサー | 完了 |
| バイナリデコーダー | 完了 |
| Canonical ABI | 完了 |
| WASI P2 アダプター | 完了 |
| CLI サポート | 完了 |

121 件の Component Model テストが合格しています。

## WAT パーサー

テキストフォーマットパーサーは以下をサポートしています:
- v128 を含むすべての値型
- 名前付きローカル、グローバル、関数、型
- インラインエクスポートとインポート
- S 式構文とフラット構文
- データセクションと要素セクション
- すべてのプレフィックスオペコード: 0xFC (bulk memory, trunc_sat), 0xFD (SIMD + lane ops), 0xFE (atomics)
- Wasm 3.0 オペコード: try_table, call_ref, br_on_null, throw_ref など
- GC プレフィックス (0xFB): GC 型アノテーションと struct/array エンコーディング
- 100% WAT ラウンドトリップ: 62,156/62,156 の仕様テストモジュールが正しくパース・再エンコード

## オペコード総数

| カテゴリ | 数 |
|---------|-----|
| Core | 201+ |
| SIMD | 256 |
| GC | 31 |
| Threads | 79 |
| その他 | 14+ |
| **合計** | **581+** |
