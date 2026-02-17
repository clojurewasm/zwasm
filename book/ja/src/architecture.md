# アーキテクチャ

zwasm は WebAssembly モジュールを複数段のパイプラインで処理します。デコード、バリデーション、レジスタ IR へのプリデコード、そしてインタプリタまたは JIT による実行です。

## パイプライン

```
.wasm binary
      |
      v
+-----------+
|  Decode   |  module.zig -- parse binary format, sections, types
+-----+-----+
      |
      v
+-----------+
| Validate  |  validate.zig -- type checking, operand stack simulation
+-----+-----+
      |
      v
+-----------+
| Predecode |  predecode.zig -- stack machine -> register IR
+-----+-----+
      |
      v
+-----------+
| Regalloc  |  regalloc.zig -- virtual -> physical register assignment
+-----+-----+
      |
      v
+----------------------+
|      Execution       |
|  +----------------+  |
|  |  Interpreter   |  |  vm.zig -- register IR dispatch loop
|  +-------+--------+  |
|          | hot path  |
|  +-------v--------+  |
|  |  JIT Compiler  |  |  jit.zig (ARM64), x86.zig (x86_64)
|  +----------------+  |
+----------------------+
```

## 実行ティア

zwasm は自動昇格を備えた階層型実行を採用しています。

1. **インタプリタ** — レジスタ IR 命令を直接実行します。すべての関数はここからスタートします。
2. **JIT (ARM64/x86_64)** — 関数の呼び出し回数またはバックエッジ回数が閾値を超えると、レジスタ IR がネイティブマシンコードにコンパイルされます。以降の呼び出しではネイティブコードが直接実行されます。

JIT の閾値はアダプティブです。ホットループはバックエッジカウントにより、より速くコンパイルがトリガーされます。

## ソースマップ

| ファイル | 役割 | LOC |
|------|------|-----|
| `module.zig` | バイナリデコーダ、セクションパース、LEB128 | ~2K |
| `validate.zig` | 型チェッカー、オペランドスタックシミュレーション | ~1.7K |
| `predecode.zig` | スタック IR → レジスタ IR 変換 | ~2K |
| `regalloc.zig` | 仮想レジスタ → 物理レジスタ割り当て | ~1.8K |
| `vm.zig` | インタプリタ、実行エンジン、ストア | ~7.3K |
| `jit.zig` | ARM64 JIT バックエンド | ~4.9K |
| `x86.zig` | x86_64 JIT バックエンド | ~3.9K |
| `types.zig` | コア型定義、値型 | ~1.3K |
| `opcode.zig` | オペコード定義 (全523個) | ~1.3K |
| `wasi.zig` | WASI Preview 1 (46 システムコール) | ~2.5K |
| `gc.zig` | GC プロポーザル: ヒープ、struct/array 型 | ~1.4K |
| `wat.zig` | WAT テキストフォーマットパーサー | ~3K |
| `cli.zig` | CLI フロントエンド | ~1.9K |
| `instance.zig` | モジュールインスタンス化、リンク | ~1K |

## レジスタ IR

zwasm は WebAssembly のスタックマシンを直接インタプリトする代わりに、プリデコード時に各関数本体をレジスタベースの中間表現 (IR) に変換します。これにより、実行時のオペランドスタック管理が不要になります。

- **スタック IR**: `local.get 0` / `local.get 1` / `i32.add` (3つのスタック操作)
- **レジスタ IR**: `add r2, r0, r1` (1命令)

レジスタ IR は仮想レジスタを使用し、レジスタアロケータによって物理レジスタにマッピングされます。ローカル変数が少ない関数は直接マッピングされ、多い関数はメモリにスピルされます。

## JIT コンパイル

JIT コンパイラはレジスタ IR をネイティブマシンコードに変換します。

- **ARM64**: フルサポート — 算術演算、制御フロー、浮動小数点、メモリ、call_indirect、SIMD
- **x86_64**: フルサポート — ARM64 と同等のカバレッジ

主な JIT 最適化:

- インライン自己呼び出し (再帰関数がトランポリンのオーバーヘッドなしに自身を呼び出し)
- スマートスピル/リロード (コールをまたいで生存しているレジスタのみスピル)
- ダイレクト関数呼び出し (既知のターゲットに対して関数テーブルルックアップをバイパス)
- デプスガードキャッシング (呼び出し深度チェックをメモリではなくレジスタで実行)

JIT は W^X メモリ保護を使用します。コードは RW ページに書き込まれ、実行前に RX に切り替えられます。シグナルハンドラが JIT コード内のメモリフォルトを Wasm トラップに変換します。

## モジュールのインスタンス化

```
WasmModule.load(bytes)       -> decode + validate + predecode
    |
    v
Instance.instantiate(store)  -> link imports, init memory/tables/globals
    |
    v
Vm.invoke(func_name, args)   -> execute via interpreter or JIT
```

`Store` はすべてのランタイム状態を保持します。メモリ、テーブル、グローバル変数、関数インスタンスです。複数のモジュールインスタンスがストアを共有することで、クロスモジュールリンクが可能です。
