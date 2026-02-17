# はじめに

このガイドでは、ゼロから WebAssembly モジュールを実行するまでを 5 分以内で解説します。

## 前提条件

- [Zig 0.15.2](https://ziglang.org/download/) 以降

## インストール

### ソースからビルド

```bash
git clone https://github.com/clojurewasm/zwasm.git
cd zwasm
zig build -Doptimize=ReleaseSafe
```

バイナリは `zig-out/bin/zwasm` に生成されます。PATH の通ったディレクトリにコピーしてください:

```bash
cp zig-out/bin/zwasm ~/.local/bin/
```

### インストールスクリプト

```bash
curl -fsSL https://raw.githubusercontent.com/clojurewasm/zwasm/main/install.sh | bash
```

### Homebrew (macOS/Linux) — 近日公開予定

```bash
brew install clojurewasm/tap/zwasm  # not yet available
```

### インストールの確認

```bash
zwasm version
```

## 最初のモジュールを実行する

### 1. WAT ファイルから実行

`hello.wat` を作成します:

```wat
(module
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add))
```

実行します:

```bash
zwasm hello.wat --invoke add 2 3
# Output: 5
```

### 2. WASI モジュール

WASI（ファイルシステム、標準出力など）を使用するモジュールの場合:

```bash
zwasm hello_wasi.wasm --allow-all
```

必要な権限のみを付与することもできます:

```bash
zwasm hello_wasi.wasm --allow-read --dir ./data
```

### 3. モジュールの検査

モジュールのエクスポートとインポートを確認します:

```bash
zwasm inspect hello.wasm
```

### 4. モジュールの検証

モジュールを実行せずに有効性を検証します:

```bash
zwasm validate hello.wasm
```

## Zig ライブラリとして使う

`build.zig.zon` に zwasm を依存関係として追加します:

```zig
.dependencies = .{
    .zwasm = .{
        .url = "https://github.com/clojurewasm/zwasm/archive/refs/tags/v1.0.0.tar.gz",
        .hash = "...",  // zig build will tell you the correct hash
    },
},
```

次に `build.zig` で以下を記述します:

```zig
const zwasm_dep = b.dependency("zwasm", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zwasm", zwasm_dep.module("zwasm"));
```

API の使い方については[埋め込みガイド](./embedding-guide.md)を参照してください。

## その他のサンプル

リポジトリには、初級から上級まで順に並んだ 33 個の WAT サンプルが `examples/wat/` にあります:

```bash
zwasm examples/wat/01_hello_add.wat --invoke add 2 3      # basics
zwasm examples/wat/02_if_else.wat --invoke abs -7          # if/else
zwasm examples/wat/03_loop.wat --invoke sum 100            # loops → 5050
zwasm examples/wat/05_fibonacci.wat --invoke fib 10        # recursion → 55
zwasm examples/wat/24_call_indirect.wat --invoke apply 0 10 3  # tables → 13
zwasm examples/wat/25_return_call.wat --invoke sum 1000000 # tail calls
zwasm examples/wat/30_wasi_hello.wat --allow-all           # WASI → Hi!
zwasm examples/wat/32_wasi_args.wat --allow-all -- hi      # WASI args
```

各ファイルのヘッダーコメントに実行方法が記載されています。Zig での埋め込みサンプルは `examples/zig/` にあります。

## 次のステップ

- [CLI リファレンス](./cli-reference.md) — すべてのコマンドとフラグ
- [埋め込みガイド](./embedding-guide.md) — zwasm を Zig ライブラリとして使う
- [仕様カバレッジ](./spec-coverage.md) — サポートされている Wasm プロポーザル
