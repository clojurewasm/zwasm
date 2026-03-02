# C API とクロスランゲージ連携

[組み込みガイド](./embedding-guide.md)では Zig からの利用方法を紹介しました。しかし zwasm は C ライブラリでもあります — C FFI を持つ任意の言語から WebAssembly モジュールをロード・実行できます。この章では C API のビルド方法、C や Python からの呼び出し方、ホスト関数・WASI・メモリ操作について解説します。

## ライブラリのビルド

```bash
zig build lib                              # libzwasm をビルド (.dylib / .so / .a)
zig build lib -Doptimize=ReleaseSafe       # 最適化ビルド
```

出力ファイル:

| 出力 | パス |
|------|------|
| 共有ライブラリ | `zig-out/lib/libzwasm.dylib` (macOS) または `libzwasm.so` (Linux) |
| 静的ライブラリ | `zig-out/lib/libzwasm.a` |
| C ヘッダ | `include/zwasm.h` |

ヘッダファイル `include/zwasm.h` が C API の唯一の定義元です。すべての型は不透明ポインタで、すべての関数は `zwasm_` プレフィックスを使用します。

## クイックスタート: C

モジュールをロードし、エクスポート関数を呼び出して結果を取得します:

```c
#include <stdio.h>
#include "zwasm.h"

/* Wasm module: (func (export "f") (result i32) (i32.const 42)) */
static const uint8_t WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b
};

int main(void) {
    zwasm_module_t *mod = zwasm_module_new(WASM, sizeof(WASM));
    if (!mod) {
        fprintf(stderr, "Error: %s\n", zwasm_last_error_message());
        return 1;
    }

    uint64_t results[1] = {0};
    if (!zwasm_module_invoke(mod, "f", NULL, 0, results, 1)) {
        fprintf(stderr, "Invoke error: %s\n", zwasm_last_error_message());
        zwasm_module_delete(mod);
        return 1;
    }

    printf("f() = %llu\n", (unsigned long long)results[0]);

    zwasm_module_delete(mod);
    return 0;
}
```

ビルドと実行:

```bash
zig build lib && zig build c-test
./zig-out/bin/example_c_hello
# f() = 42
```

## クイックスタート: Python (ctypes)

Python の組み込み `ctypes` モジュールを使用した例です。コンパイル済みバインディングは不要です:

```python
import ctypes, os

lib = ctypes.CDLL("zig-out/lib/libzwasm.dylib")  # Linux では .so

# 関数シグネチャの宣言
lib.zwasm_module_new.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
lib.zwasm_module_new.restype = ctypes.c_void_p
lib.zwasm_module_delete.argtypes = [ctypes.c_void_p]
lib.zwasm_module_delete.restype = None
lib.zwasm_module_invoke.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p,
    ctypes.POINTER(ctypes.c_uint64), ctypes.c_uint32,
    ctypes.POINTER(ctypes.c_uint64), ctypes.c_uint32,
]
lib.zwasm_module_invoke.restype = ctypes.c_bool
lib.zwasm_last_error_message.argtypes = []
lib.zwasm_last_error_message.restype = ctypes.c_char_p

# C の例と同じ Wasm バイト列
wasm = bytes([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b,
])

mod = lib.zwasm_module_new(wasm, len(wasm))
assert mod, f"Error: {lib.zwasm_last_error_message().decode()}"

results = (ctypes.c_uint64 * 1)(0)
ok = lib.zwasm_module_invoke(mod, b"f", None, 0, results, 1)
assert ok, f"Invoke error: {lib.zwasm_last_error_message().decode()}"

print(f"f() = {results[0]}")  # f() = 42

lib.zwasm_module_delete(mod)
```

実行:

```bash
zig build lib
python3 examples/python/basic.py
```

## API リファレンス

関数はドメインごとにグループ化されています。すべてのシグネチャは `include/zwasm.h` に定義されています。

### エラーハンドリング

| 関数 | 説明 |
|------|------|
| `zwasm_last_error_message()` | 最後のエラーを null 終端文字列で返す。エラーなしの場合は `""` を返す。スレッドローカル。 |

### モジュールのライフサイクル

| 関数 | 説明 |
|------|------|
| `zwasm_module_new(wasm_ptr, len)` | バイナリバイト列からモジュールを作成。エラー時は `NULL`。 |
| `zwasm_module_new_wasi(wasm_ptr, len)` | デフォルトケーパビリティで WASI モジュールを作成。 |
| `zwasm_module_new_wasi_configured(wasm_ptr, len, config)` | カスタム設定で WASI モジュールを作成。 |
| `zwasm_module_new_with_imports(wasm_ptr, len, imports)` | ホスト関数インポート付きでモジュールを作成。 |
| `zwasm_module_delete(module)` | モジュールの全リソースを解放。 |
| `zwasm_module_validate(wasm_ptr, len)` | インスタンス化せずにバイナリを検証。 |

### 関数呼び出し

| 関数 | 説明 |
|------|------|
| `zwasm_module_invoke(module, name, args, nargs, results, nresults)` | エクスポート関数を名前で呼び出す。 |
| `zwasm_module_invoke_start(module)` | `_start`（WASI エントリポイント）を呼び出す。 |

### エクスポートの検査

| 関数 | 説明 |
|------|------|
| `zwasm_module_export_count(module)` | エクスポート関数の数。 |
| `zwasm_module_export_name(module, idx)` | idx 番目のエクスポート名。 |
| `zwasm_module_export_param_count(module, idx)` | エクスポートのパラメータ数。 |
| `zwasm_module_export_result_count(module, idx)` | エクスポートの戻り値数。 |

### メモリアクセス

| 関数 | 説明 |
|------|------|
| `zwasm_module_memory_data(module)` | リニアメモリへの直接ポインタ。メモリ拡張で無効化される。 |
| `zwasm_module_memory_size(module)` | 現在のメモリサイズ（バイト単位）。 |
| `zwasm_module_memory_read(module, offset, len, out_buf)` | 境界チェック付き読み出し。 |
| `zwasm_module_memory_write(module, offset, data, len)` | 境界チェック付き書き込み。 |

### WASI 設定

| 関数 | 説明 |
|------|------|
| `zwasm_wasi_config_new()` | 設定ハンドルを作成。 |
| `zwasm_wasi_config_delete(config)` | 設定ハンドルを解放。 |
| `zwasm_wasi_config_set_argv(config, argc, argv)` | コマンドライン引数を設定。 |
| `zwasm_wasi_config_set_env(config, count, keys, key_lens, vals, val_lens)` | 環境変数を設定。 |
| `zwasm_wasi_config_preopen_dir(config, host_path, host_len, guest_path, guest_len)` | ホストディレクトリをマッピング。 |

### ホスト関数インポート

| 関数 | 説明 |
|------|------|
| `zwasm_import_new()` | インポートコレクションを作成。 |
| `zwasm_import_delete(imports)` | インポートコレクションを解放。 |
| `zwasm_import_add_fn(imports, module, name, callback, env, params, results)` | ホスト関数を登録。 |

## 値エンコーディング

Wasm の値は `uint64_t` 配列として渡されます。エンコーディングは Wasm の生の値表現に対応しています:

| Wasm 型 | C エンコーディング | 備考 |
|---------|-------------------|------|
| `i32` | `uint64_t` にゼロ拡張 | 上位 32 ビットはゼロ |
| `i64` | `uint64_t` そのまま | 変換不要 |
| `f32` | IEEE 754 ビットパターンをゼロ拡張 | `float` へは `memcpy` を使用、キャスト不可 |
| `f64` | IEEE 754 ビットパターンを `uint64_t` に | `double` へは `memcpy` を使用、キャスト不可 |

例 — `f64` 引数を渡す場合:

```c
double val = 3.14;
uint64_t arg;
memcpy(&arg, &val, sizeof(arg));

uint64_t result[1];
zwasm_module_invoke(mod, "sqrt", &arg, 1, result, 1);

double out;
memcpy(&out, &result[0], sizeof(out));
```

## ホスト関数

ホスト関数は、Wasm モジュールがインポートとして呼び出せる C コールバックです。

コールバックシグネチャ:

```c
typedef bool (*zwasm_host_fn_callback_t)(
    void *env,              /* ユーザーコンテキストポインタ */
    const uint64_t *args,   /* 入力パラメータ */
    uint64_t *results       /* 出力バッファ */
);
```

動作例 — `print_i32` ホスト関数:

```c
#include <stdio.h>
#include "zwasm.h"

static bool print_i32(void *env, const uint64_t *args, uint64_t *results) {
    (void)env;
    (void)results;
    printf("wasm says: %d\n", (int32_t)args[0]);
    return true;
}

int main(void) {
    zwasm_imports_t *imports = zwasm_import_new();
    zwasm_import_add_fn(imports, "env", "print_i32", print_i32, NULL, 1, 0);

    zwasm_module_t *mod = zwasm_module_new_with_imports(wasm_bytes, wasm_len, imports);
    /* ... 呼び出し後にクリーンアップ ... */
    zwasm_module_delete(mod);
    zwasm_import_delete(imports);
}
```

`env` ポインタを使用すると、グローバル変数を使わずに任意のコンテキスト（構造体、ファイルハンドルなど）をコールバックに渡せます。

## WASI プログラム

設定ビルダーパターンを使用して、カスタム設定で WASI プログラムを実行できます:

```c
/* WASI の設定 */
zwasm_wasi_config_t *config = zwasm_wasi_config_new();

const char *argv[] = {"myapp", "--verbose"};
zwasm_wasi_config_set_argv(config, 2, argv);

zwasm_wasi_config_preopen_dir(config, "/tmp/data", 9, "/data", 5);

/* WASI 設定付きでモジュールを作成 */
zwasm_module_t *mod = zwasm_module_new_wasi_configured(wasm_bytes, wasm_len, config);

/* プログラムを実行 */
zwasm_module_invoke_start(mod);

/* クリーンアップ */
zwasm_module_delete(mod);
zwasm_wasi_config_delete(config);
```

デフォルトケーパビリティ (stdio, clock, random) のみの単純な WASI プログラムの場合:

```c
zwasm_module_t *mod = zwasm_module_new_wasi(wasm_bytes, wasm_len);
zwasm_module_invoke_start(mod);
zwasm_module_delete(mod);
```

## スレッドセーフティ

- **エラーバッファ**: `zwasm_last_error_message()` はスレッドローカルバッファを返します。複数スレッドからの呼び出しは安全です。
- **モジュール**: `zwasm_module_t` はスレッドセーフ**ではありません**。同一モジュールに対して複数スレッドから同時に関数を呼び出さないでください。スレッドごとに個別のモジュールインスタンスを作成してください。

## 次のステップ

- [ビルド設定](./build-configuration.md) — コンパイルに含める機能のカスタマイズ
- `examples/c/` と `examples/python/` — リポジトリ内の動作する例
- `include/zwasm.h` — ドキュメントコメント付きの完全な C ヘッダ
