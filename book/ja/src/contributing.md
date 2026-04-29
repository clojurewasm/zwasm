# コントリビューターガイド

## ビルドとテスト

```bash
git clone https://github.com/clojurewasm/zwasm.git
cd zwasm

# Commit Gate を一括実行（build + tests + spec + e2e + realworld + FFI + minimal）
bash scripts/gate-commit.sh

# 個別ステップ（イテレーション時）
zig build
zig build test
zig build test -- "Module — rejects excessive locals"
python3 test/spec/run_spec.py --build --summary
bash scripts/run-bench.sh --quick
```

## 必要なツール

- Zig 0.16.0（バージョンは pin 済み。macOS / Linux は Nix devshell が `flake.nix`
  経由で提供。Windows では `pwsh scripts/windows/install-tools.ps1` を1度実行
  すれば `.github/versions.lock` どおりに揃います。）
- Python 3（spec / e2e / realworld テストランナー）
- [wasm-tools](https://github.com/bytecodealliance/wasm-tools) — spec テスト変換
- [hyperfine](https://github.com/sharkdp/hyperfine) — ベンチマーク
- [wasmtime](https://github.com/bytecodealliance/wasmtime) — realworld 互換比較対象
- [WASI SDK](https://github.com/WebAssembly/wasi-sdk) — realworld の C/C++ → wasm

開発環境セットアップの全体は `.dev/environment.md` を参照。pin は
`.github/versions.lock` / `flake.nix` で一元管理。

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
  e2e/            End-to-end tests (wasmtime misc_testsuite, 796 assertions)
  fuzz/           Fuzz testing infrastructure
  realworld/      Real-world compatibility tests (50 programs: Rust / C / C++ / TinyGo)
bench/
  run_bench.sh    ベンチマークランナー（インタラクティブ）
  record.sh       history.yaml に記録（5 runs + 3 warmup, full）
  ci_compare.sh   CI 用リグレッションチェック（Ubuntu vs Ubuntu）
  wasm/           ベンチマーク wasm モジュール
scripts/
  gate-commit.sh  Commit Gate ワンライナー（CLAUDE.md items 1-5 + 8）
  gate-merge.sh   Merge Gate ワンライナー（Commit Gate + sync + CI チェック）
  sync-versions.sh        versions.lock ↔ flake.nix 整合性
  run-bench.sh    bench/run_bench.sh のラッパ
  record-merge-bench.sh   マージ後 bench 記録（Mac のみ）
  windows/install-tools.ps1   Windows ツールチェーンプロビジョナ
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

- ユニットテストの通過（macOS + Ubuntu + Windows）
- スペックテストの通過（62,263 テスト）
- E2E テストの通過（796 アサーション）
- バイナリサイズ <= 1.60 MB（strip 後、Linux ELF ~1.56 MB。Mac Mach-O ~1.20 MB）
- ベンチマークの性能劣化が 20% 以内
- ReleaseSafe ビルドの成功
