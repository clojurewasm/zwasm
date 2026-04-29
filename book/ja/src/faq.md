# FAQ & トラブルシューティング

## 一般

### zwasm はどの Wasm プロポーザルに対応していますか?

Wasm 3.0 の全 9 プロポーザルに加え、threads、wide arithmetic、custom page sizes に対応しています。詳細は [Spec Coverage](./spec-coverage.md) をご覧ください。

### zwasm は Windows に対応していますか?

はい。zwasm は macOS (ARM64) / Linux (x86_64, aarch64) / Windows (x86_64) で動作します。POSIX 系では JIT とメモリガードページに mmap / mprotect / シグナルハンドラを使用し、Windows では `kernel32.dll` の VirtualAlloc / VirtualProtect / Vectored Exception Handler を使用します。CI は 3 ターゲット triple すべてでフルテストを回しています。Windows での real-world プログラム互換は現在 25/25 (50 プログラムのうち C / C++ サブセット — Go / Rust / TinyGo の Windows プロビジョニングは W52 で追跡)。

### C や Python など他の言語から zwasm を使えますか?

はい。zwasm は C API (`libzwasm`) を提供しており、FFI を持つ任意の言語から利用できます。`zig build lib` で共有ライブラリをビルドし、各言語の FFI 機構 (Python `ctypes`、Rust `extern "C"`、Go `cgo` など) から `zwasm_*` 関数を呼び出してください。[C API とクロスランゲージ連携](./c-api.md)を参照してください。

### バイナリサイズを削減できますか?

はい。ビルド時のフィーチャーフラグで不要な機能を除外できます: `-Djit=false` (JIT なし、Linux で約 −150 KB)、`-Dwat=false` (WAT パーサなし、約 −150 KB)。`-Dcomponent=false` 単独は実行時に Component Model コードが既に dead-code-elimination されるため現状はサイズ変化なし。3 つすべてを組み合わせると Linux で約 1.26 MB (≈ −19 %) の最小バイナリになります。Mac での同等構成は約 0.92 MB です。[ビルド設定](./build-configuration.md)を参照してください。

### JIT なしで zwasm を使えますか?

はい。デフォルトではレジスタ IR インタープリタがすべての関数を処理します。JIT は `HOT_THRESHOLD = 3` (3 回呼ばれるか、ホットループでバックエッジを 3 回踏む) を満たした関数のみ起動されます。JIT を完全に除外してビルドするには `-Djit=false` を使用してください — JIT コンパイラがバイナリから除去され、Linux x86_64 で約 150 KB (≈10 %) 小さくなります。短時間で終わるスクリプトはそもそも JIT に昇格しないため、no-JIT ビルドと性能差はありません。

### WAT パーサとは何ですか?

zwasm は `.wat` テキスト形式のファイルを直接実行できます: `zwasm run program.wat`。WAT パーサはコンパイル時に `-Dwat=false` を指定することで無効化でき、バイナリサイズを削減できます。

## トラブルシューティング

### "trap: out-of-bounds memory access"

Wasm モジュールがリニアメモリの範囲外のメモリを読み書きしようとしました。これは zwasm ではなく Wasm モジュール側のバグです。モジュールのメモリがデータに対して十分な大きさがあるか確認してください。

### "trap: call stack overflow (depth > 1024)"

再帰的な関数呼び出しが深さ 1024 の制限を超えました。これは通常、Wasm モジュール内の無限再帰が原因です。

### "required import not found"

モジュールが必要とするインポートが提供されていません。`zwasm inspect` を使用してモジュールに必要なインポートを確認し、`--link` またはホスト関数で提供してください。

### "invalid wasm binary"

ファイルが有効な WebAssembly バイナリではありません。マジックバイト `\0asm` とバージョン `\01\00\00\00` で始まっているか確認してください。WAT ファイルには `.wat` 拡張子を使用してください。

### パフォーマンスが遅い

- `zig build -Doptimize=ReleaseSafe` でビルドしていることを確認してください。デバッグビルドは 5〜10 倍遅くなります。
- ホットな関数 (多数回呼び出される関数) は自動的に JIT コンパイルされます。実行時間の短いプログラムでは JIT の恩恵を受けられない場合があります。
- `--profile` を使用してオペコードの頻度と呼び出し回数を確認できます。

### メモリ使用量が多い

- リニアメモリを持つすべての Wasm モジュールはガードページ (仮想メモリ約 4 GiB、物理メモリではない) を確保します。これは正常な動作で、VSIZE は大きく表示されますが RSS は小さいままです。
- `--max-memory` を使用してモジュールが確保できる実際のメモリ量を制限できます。
