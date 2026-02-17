# 組み込みガイド

zwasm を Zig ライブラリとして使用し、アプリケーション内で WebAssembly モジュールをロード・実行できます。

## セットアップ

`build.zig.zon` に zwasm を追加します:

```zig
.dependencies = .{
    .zwasm = .{
        .url = "https://github.com/clojurewasm/zwasm/archive/refs/tags/v1.0.0.tar.gz",
        .hash = "...",  // zig build will provide the correct hash
    },
},
```

`build.zig` に以下を記述します:

```zig
const zwasm_dep = b.dependency("zwasm", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zwasm", zwasm_dep.module("zwasm"));
```

## 基本的な使い方

```zig
const zwasm = @import("zwasm");
const WasmModule = zwasm.WasmModule;

// Load a module from bytes
const mod = try WasmModule.load(allocator, wasm_bytes);
defer mod.deinit();

// Call an exported function
var args = [_]u64{ 10, 20 };
var results = [_]u64{0};
try mod.invoke("add", &args, &results);

const sum: i32 = @bitCast(@as(u32, @truncate(results[0])));
```

## ロードのバリエーション

| メソッド | 用途 |
|--------|----------|
| `load(alloc, bytes)` | 基本的なモジュール、WASI なし |
| `loadFromWat(alloc, wat_src)` | WAT テキスト形式からロード |
| `loadWasi(alloc, bytes)` | WASI 付きモジュール (cli_default ケーパビリティ) |
| `loadWasiWithOptions(alloc, bytes, opts)` | カスタム設定の WASI |
| `loadWithImports(alloc, bytes, imports)` | ホスト関数付きモジュール |
| `loadWasiWithImports(alloc, bytes, imports, opts)` | WASI とホスト関数の両方 |
| `loadWithFuel(alloc, bytes, fuel)` | 命令フューエル制限付き |

## ホスト関数

ネイティブの Zig 関数を Wasm インポートとして提供できます:

```zig
const zwasm = @import("zwasm");

fn hostLog(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));

    // Pop argument from operand stack
    const value = vm.popOperandI32();
    std.debug.print("log: {}\n", .{value});

    // Push return value (if function returns one)
    // try vm.pushOperand(@bitCast(@as(i32, result)));
}

const imports = [_]zwasm.ImportEntry{
    .{
        .module = "env",
        .source = .{ .host_fns = &.{
            .{ .name = "log", .callback = hostLog, .context = 0 },
        }},
    },
};

const mod = try WasmModule.loadWithImports(allocator, wasm_bytes, &imports);
```

## WASI 設定

```zig
// loadWasi() defaults to cli_default caps (stdio, clock, random, proc_exit).
// Use loadWasiWithOptions for full access or custom capabilities:
const opts = zwasm.WasiOptions{
    .args = &.{ "my-app", "--verbose" },
    .env_keys = &.{"HOME"},
    .env_vals = &.{"/tmp"},
    .preopen_paths = &.{"./data"},
    .caps = zwasm.Capabilities.all,
};

const mod = try WasmModule.loadWasiWithOptions(allocator, wasm_bytes, opts);
```

## メモリアクセス

モジュールのリニアメモリに対して読み書きできます:

```zig
// Read 100 bytes starting at offset 0
const data = try mod.memoryRead(allocator, 0, 100);
defer allocator.free(data);

// Write data at offset 256
try mod.memoryWrite(256, &.{ 0x48, 0x65, 0x6C, 0x6C, 0x6F });
```

## モジュールリンク

複数のモジュールをリンクできます:

```zig
// Load the "math" module and register its exports
const math_mod = try WasmModule.load(allocator, math_bytes);
defer math_mod.deinit();
try math_mod.registerExports("math");

// Load another module that imports from "math"
const imports = [_]zwasm.ImportEntry{
    .{ .module = "math", .source = .{ .wasm_module = math_mod } },
};
const app_mod = try WasmModule.loadWithImports(allocator, app_bytes, &imports);
defer app_mod.deinit();
```

## インポートの検査

インスタンス化の前に、モジュールが必要とするインポートを確認できます:

```zig
const import_infos = try zwasm.inspectImportFunctions(allocator, wasm_bytes);
defer allocator.free(import_infos);

for (import_infos) |info| {
    std.debug.print("{s}.{s}: {d} params, {d} results\n", .{
        info.module, info.name, info.param_count, info.result_count,
    });
}
```

## リソース制限

リソース使用量を制御できます:

```zig
// Fuel limit: traps after N instructions
const mod = try WasmModule.loadWithFuel(allocator, wasm_bytes, 1_000_000);

// Memory limit: via WASI options or direct Vm access
```

## エラーハンドリング

すべてのロード・実行メソッドはエラーユニオンを返します。主要なエラー型は以下のとおりです:

- **`error.InvalidWasm`** --- バイナリ形式が不正
- **`error.ImportNotFound`** --- 必要なインポートが提供されていない
- **`error.Trap`** --- unreachable 命令が実行された
- **`error.StackOverflow`** --- 呼び出し深度が 1024 を超過
- **`error.OutOfBoundsMemoryAccess`** --- メモリアクセスが範囲外
- **`error.OutOfMemory`** --- アロケータが失敗
- **`error.FuelExhausted`** --- 命令フューエル制限に到達

完全なリストは [エラーリファレンス](../docs/errors.md) を参照してください。

## アロケータの制御

zwasm はロード時に `std.mem.Allocator` を受け取り、すべての内部メモリ確保に使用します。アロケータはユーザーが制御できます:

```zig
// Use the general purpose allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const mod = try WasmModule.load(gpa.allocator(), wasm_bytes);

// Or use an arena for batch cleanup
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const mod = try WasmModule.load(arena.allocator(), wasm_bytes);
```

## API の安定性

型と関数は 3 つの安定性レベルに分類されます:

- **Stable**: SemVer に準拠します。マイナー/パッチリリースで破壊的変更はありません。対象: `WasmModule`、`WasmFn`、`WasmValType`、`ExportInfo`、`ImportEntry`、`HostFnEntry`、`WasiOptions`、およびそれらのすべてのパブリックメソッド。

- **Experimental**: マイナーリリースで変更される可能性があります。対象: `runtime.Store`、`runtime.Module`、`runtime.Instance`、`loadLinked`、WIT 関連関数。

- **Internal**: ライブラリ利用者からはアクセスできません。`types.zig` 以外のソースファイル内のすべての型が対象です。

完全なリストは [docs/api-boundary.md](https://github.com/clojurewasm/zwasm/blob/main/docs/api-boundary.md) を参照してください。
