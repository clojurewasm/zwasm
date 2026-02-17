# コントリビューターガイド

## ビルドとテスト

```bash
git clone https://github.com/clojurewasm/zwasm.git
cd zwasm

# ビルド
zig build

# ユニットテストの実行
zig build test

# 特定のテストのみ実行
zig build test -- "Module — rejects excessive locals"

# スペックテストの実行（wasm-tools が必要）
python3 test/spec/run_spec.py --build --summary

# ベンチマークの実行
bash bench/run_bench.sh --quick
```

## 必要なツール

- Zig 0.15.2
- Python 3（スペックテストランナー用）
- [wasm-tools](https://github.com/bytecodealliance/wasm-tools)（スペックテスト変換用）
- [hyperfine](https://github.com/sharkdp/hyperfine)（ベンチマーク用）

## コード構成

```
src/
  types.zig       Public API (WasmModule, WasmFn, etc.)
  module.zig      Binary decoder
  validate.zig    Type checker
  predecode.zig   Stack → register IR
  regalloc.zig    Register allocation
  vm.zig          Interpreter + execution engine
  jit.zig         ARM64 JIT backend
  x86.zig         x86_64 JIT backend
  opcode.zig      Opcode definitions
  wasi.zig        WASI Preview 1
  gc.zig          GC proposal
  wat.zig         WAT text format parser
  cli.zig         CLI frontend
  instance.zig    Module instantiation
test/
  spec/           WebAssembly spec tests
  e2e/            End-to-end tests (wasmtime misc_testsuite)
  fuzz/           Fuzz testing infrastructure
bench/
  run_bench.sh    Benchmark runner
  record.sh       Record results to history.yaml
  wasm/           Benchmark wasm modules
```

## 開発ワークフロー

1. フィーチャーブランチを作成: `git checkout -b feature/my-change`
2. まず失敗するテストを書く（TDD）
3. テストを通すための最小限のコードを実装する
4. テストを実行: `zig build test`
5. インタープリターやオペコードを変更した場合は、スペックテストも実行する
6. 説明的なメッセージでコミットする
7. `main` に対してプルリクエストを作成する

## コミットガイドライン

- 1コミットにつき1つの論理的な変更
- コミットメッセージ: 命令形で簡潔な件名をつける
- テストの変更はテスト対象のコードと同じコミットに含める

## CI チェック

プルリクエストでは以下が自動的にチェックされます:

- ユニットテストの通過（macOS + Ubuntu）
- スペックテストの通過（62,158 テスト）
- E2E テストの通過（356 アサーション）
- バイナリサイズ <= 1.5 MB
- ベンチマークの性能劣化が 20% 以内
- ReleaseSafe ビルドの成功
