# ビルド設定

zwasm はデフォルトですべての機能を含めてビルドされます。組み込みシステム、エッジ関数、最小コンテナなどサイズに制約のある環境では、不要な機能をコンパイル時に除外できます。

## フィーチャーフラグ

`zig build` にフラグを渡して機能を有効・無効にできます:

| フラグ | 説明 | デフォルト |
|--------|------|-----------|
| `-Djit=false` | JIT コンパイラ (ARM64/x86_64) を無効化。インタープリタのみ。 | `true` |
| `-Dcomponent=false` | Component Model (WIT, Canon ABI, WASI P2) を無効化。 | `true` |
| `-Dwat=false` | WAT テキスト形式パーサを無効化。バイナリのみのロード。 | `true` |
| `-Dsimd=false` | SIMD オペコード (v128 演算) を無効化。 | `true` |
| `-Dgc=false` | GC プロポーザル (struct/array 型) を無効化。 | `true` |
| `-Dthreads=false` | スレッドとアトミック演算を無効化。 | `true` |

例:

```bash
zig build -Doptimize=ReleaseSafe -Djit=false -Dwat=false
```

## サイズへの影響

Linux x86_64、ReleaseSafe、strip 済みで計測:

| バリアント | フラグ | サイズ (概算) | 差分 |
|-----------|--------|-------------:|-----:|
| フル (デフォルト) | (なし) | 約 1.23 MB | — |
| JIT なし | `-Djit=false` | 約 1.03 MB | −16% |
| Component Model なし | `-Dcomponent=false` | 約 1.13 MB | −8% |
| WAT なし | `-Dwat=false` | 約 1.15 MB | −6% |
| 最小構成 | `-Djit=false -Dcomponent=false -Dwat=false` | 約 940 KB | −24% |

最小構成でも非 JIT のスペックテストはすべて通過し、完全な Wasm 3.0 命令セット（インタープリタ実行）をサポートします。

## よくあるプロファイル

### インタープリタのみ

最小バイナリ。ピークスループットよりも起動レイテンシが重要な場合に適しています:

```bash
zig build -Doptimize=ReleaseSafe -Djit=false
```

### 最小 CLI

コア Wasm バイナリの実行に不要なものをすべて除外:

```bash
zig build -Doptimize=ReleaseSafe -Djit=false -Dcomponent=false -Dwat=false
```

### フル (デフォルト)

全機能有効。一般的な用途に推奨:

```bash
zig build -Doptimize=ReleaseSafe
```

## 仕組み

フィーチャーフラグは `build.zig` 内で `b.option(bool, ...)` として定義され、コンパイル時オプションとして Zig モジュールに渡されます。ソースファイルでは `@import("build_options")` で確認します:

```zig
const build_options = @import("build_options");

if (build_options.enable_jit) {
    // JIT コンパイルパス
} else {
    // インタープリタのみのパス
}
```

機能が無効の場合、Zig のデッドコード除去により関連コードはすべてバイナリから除去されます。ランタイムオーバーヘッドはゼロです — 無効化された機能は出力に存在しません。

## フラグ付きライブラリビルド

フィーチャーフラグはライブラリターゲットでも使用できます:

```bash
# 最小共有ライブラリをビルド (JIT なし、Component Model なし)
zig build lib -Doptimize=ReleaseSafe -Djit=false -Dcomponent=false
```

生成される `libzwasm.so` / `.dylib` はサイズが小さくなりますが、完全な C API は引き続き公開されます。無効化された機能に依存する関数を呼び出すと、`zwasm_last_error_message()` 経由でエラーが返されます（例: `-Dcomponent=false` でコンポーネントバイナリをロードした場合）。

## CI サイズマトリクス

CI パイプラインには `size-matrix` ジョブが含まれており、5 つのバリアント（full, no-jit, no-component, no-wat, minimal）をビルドして strip 後のサイズを報告します。新しいコードが追加された際の予期しないサイズ増加を検出します。

詳細な設定は `.github/workflows/ci.yml` を参照してください。
