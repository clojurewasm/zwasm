# CLI リファレンス

## コマンド

### `zwasm run` / `zwasm <file>`

WebAssembly モジュールを実行します。`run` サブコマンドは省略可能です。`zwasm file.wasm` は `zwasm run file.wasm` と同等です。

```bash
zwasm <file.wasm|.wat> [options] [args...]
zwasm run <file.wasm|.wat> [options] [args...]
```

デフォルトでは `_start`（WASI エントリーポイント）を呼び出します。特定のエクスポート関数を呼び出すには `--invoke` を使用してください。

**使用例:**

```bash
# WASI モジュールを実行（_start を呼び出す）
zwasm hello.wasm --allow-all

# WAT テキスト形式のファイルを実行（コンパイル不要）
zwasm program.wat

# 特定のエクスポート関数を呼び出す
zwasm math.wasm --invoke add 2 3
```

#### 引数の型

関数の引数は型を認識します。zwasm は関数の型シグネチャを使用して、整数、浮動小数点数、負の数を正しくパースします。

```bash
# 整数
zwasm math.wat --invoke add 2 3          # → 5

# 負の数（-- は不要）
zwasm math.wat --invoke negate -5        # → -5
zwasm math.wat --invoke abs -42          # → 42

# 浮動小数点数
zwasm math.wat --invoke double 3.14      # → 6.28
zwasm math.wat --invoke half -6.28       # → -3.14

# 64ビット整数
zwasm math.wat --invoke fib 50           # → 12586269025
```

結果は自然な形式で表示されます:
- i32/i64: 符号付き10進数（例: `-1`、`4294967295` ではなく）
- f32/f64: 10進数（例: `3.14`、生のビット表現ではなく）

引数の数は関数シグネチャに対して検証されます:

```bash
zwasm math.wat --invoke add 2             # error: 'add' expects 2 arguments, got 1
```

#### WASI モジュール

WASI モジュールは `_start` を使用し、`args_get` 経由で文字列引数を受け取ります。WASI の引数と zwasm のオプションを区別するには `--` を使用してください:

```bash
# WASI モジュールに文字列引数を渡す
zwasm app.wasm --allow-all -- hello world
zwasm app.wasm --allow-read --dir ./data -- input.txt

# 環境変数（注入された変数は --allow-env なしでもアクセス可能）
zwasm app.wasm --env HOME=/tmp --env USER=alice

# サンドボックスモード: 全権限を拒否 + fuel 10億 + メモリ 256MB
zwasm untrusted.wasm --sandbox
zwasm untrusted.wasm --sandbox --allow-read --dir ./data
```

#### マルチモジュールリンク

```bash
# インポートモジュールをリンクして関数を呼び出す
zwasm app.wasm --link math=math.wasm --invoke compute 42
```

#### リソース制限

```bash
# 命令数（fuel メータリング）とメモリを制限
zwasm untrusted.wasm --fuel 1000000 --max-memory 16777216
```

### `zwasm inspect`

モジュールのインポートとエクスポートを表示します。

```bash
zwasm inspect [--json] <file.wasm|.wat>
```

```bash
# 人間が読める形式
zwasm inspect examples/wat/01_hello_add.wat

# JSON 出力（スクリプト用）
zwasm inspect --json math.wasm
```

**オプション:**
- `--json` — JSON 形式で出力

### `zwasm validate`

モジュールを実行せずに妥当性を検証します。

```bash
zwasm validate <file.wasm|.wat>
```

### `zwasm features`

サポートしている WebAssembly プロポーザルの一覧を表示します。

```bash
zwasm features [--json]
```

### `zwasm version`

バージョン文字列を表示します。

### `zwasm help`

使い方の情報を表示します。

## run オプション

### 実行

| フラグ | 説明 |
|------|-------------|
| `--invoke <func>` | `_start` の代わりに `<func>` を呼び出す |
| `--batch` | バッチモード: stdin から呼び出しコマンドを読み取る |
| `--link name=file` | モジュールをインポートソースとしてリンク（繰り返し指定可） |

### WASI ケーパビリティ

| フラグ | 説明 |
|------|-------------|
| `--sandbox` | 全ケーパビリティを拒否 + fuel 10億 + メモリ 256MB |
| `--allow-all` | すべての WASI ケーパビリティを付与 |
| `--allow-read` | ファイルシステムの読み取りを許可 |
| `--allow-write` | ファイルシステムの書き込みを許可 |
| `--allow-env` | 環境変数へのアクセスを許可 |
| `--allow-path` | パス操作（open, mkdir, unlink）を許可 |
| `--dir <path>` | ホストディレクトリをプリオープン（繰り返し指定可） |
| `--env KEY=VALUE` | WASI 環境変数を設定（常にアクセス可能） |

### リソース制限

| フラグ | 説明 |
|------|-------------|
| `--max-memory <N>` | メモリ上限（バイト単位、`memory.grow` を制限） |
| `--fuel <N>` | 命令 fuel の上限（使い切るとトラップ） |

### デバッグ

| フラグ | 説明 |
|------|-------------|
| `--profile` | 実行プロファイルを表示（オペコード頻度、呼び出し回数） |
| `--trace=CATS` | トレースカテゴリ: `jit,regir,exec,mem,call`（カンマ区切り） |
| `--dump-regir=N` | 関数インデックス N のレジスタ IR をダンプ |
| `--dump-jit=N` | 関数インデックス N の JIT ディスアセンブリをダンプ |

## バッチモード

`--batch` を使用すると、zwasm は stdin から呼び出しコマンドを1行ずつ読み取ります:

```
add 2 3
mul 4 5
fib 10
```

```bash
echo -e "add 2 3\nmul 4 5" | zwasm math.wasm --batch --invoke add
```

## 終了コード

| コード | 意味 |
|------|---------|
| 0 | 成功 |
| 1 | ランタイムエラー（トラップ、スタックオーバーフロー等） |
| 2 | 不正なモジュールまたはバリデーションエラー |
| 126 | ファイルが見つからない |
