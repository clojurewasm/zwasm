# 他のランタイムとの比較

zwasm と他の WebAssembly ランタイムの比較です。

## 概要

| 特徴 | zwasm | wasmtime | wasm3 | wasmer |
|------|-------|----------|-------|--------|
| 言語 | Zig | Rust | C | Rust/C |
| バイナリサイズ | 1.3 MB | 56 MB | ~100 KB | 30+ MB |
| メモリ (fib) | 3.5 MB | 12 MB | ~1 MB | 15+ MB |
| 実行方式 | Interp + JIT | AOT/JIT | Interpreter | AOT/JIT |
| Wasm 3.0 | 完全対応 | 完全対応 | 部分対応 | 部分対応 |
| GC プロポーザル | 対応 | 対応 | 非対応 | 非対応 |
| SIMD | 完全対応 (256 ops) | 完全対応 | 部分対応 | 完全対応 |
| WASI | P1 (46 syscalls) | P1 + P2 | P1 (部分的) | P1 + P2 |
| プラットフォーム | macOS, Linux | macOS, Linux, Windows | 多数 (JIT なし) | macOS, Linux, Windows |

## zwasm を選ぶべきとき

**小さなフットプリント**: バイナリサイズとメモリ使用量が重要な場合。zwasm は wasmtime の 43 分の 1 のサイズです。

**Zig エコシステム**: Zig アプリケーションに組み込む場合。zwasm は C 依存なしのネイティブな `zig build` 依存関係として統合できます。

**仕様の完全性**: GC、SIMD、スレッド、例外処理を含む完全な Wasm 3.0 サポートを小さなランタイムで必要とする場合。

**高速な起動**: インタプリタが即座に実行を開始します。JIT コンパイルはホットな関数に対してバックグラウンドで行われます。

## 他のランタイムを選ぶべきとき

**最大スループット**: wasmtime の Cranelift AOT コンパイラは高度に最適化されたネイティブコードを生成します。長時間の計算負荷が高いワークロードでは、wasmtime のほうが高速な場合があります。特に SIMD 多用のワークロードでは、zwasm は現在約 22 倍遅くなります（スタックインタプリタ、SIMD JIT 未実装）。

**Windows サポート**: zwasm は現在 macOS と Linux をサポートしています。Windows で使用する場合は wasmtime または wasmer を選択してください。

**最小サイズ**: wasm3 は約 100 KB でマイクロコントローラ上でも動作します。JIT なしで最も小さなランタイムが必要な場合は、wasm3 のほうが適しているかもしれません。

**WASI Preview 2**: wasmtime は最も完全な WASI P2 実装を備えています。zwasm の P2 サポートは P1 アダプタレイヤーを介して提供されます。
