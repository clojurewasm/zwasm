# Realworld fixture sources (regenerated set)

> **Doc-state**: ACTIVE

Sources for committed `test/realworld/wasm/*.wasm` fixtures that have been
REGENERATED in v2 (the original 50-fixture set was vendored binary-only from
v1 at b03b853f; sources are added here as fixtures need fixes — D-313).

Ground truth for the sha256 fixtures' expected constant:
`printf 'Hello, SHA-256!' | shasum -a 256` =
`d0e8b8f11c98f369016eb2ed3c541e1f01382f9d5b3104c9ffd06b6175a46271`
(the v1-vendored fixtures baked a WRONG value, `3d61375c…`, and self-reported
`verify: FAIL`; the run-runner's stdout assert now RED-gates that — D-313).

## c/sha256_hash.c → wasm/c_sha256_hash.wasm

Built inside `nix develop .#gen` (Mac generation host; see
`.dev/toolchain_provisioning.md`):

```sh
emcc -O2 -sSTANDALONE_WASM=1 -o test/realworld/wasm/c_sha256_hash.wasm \
    test/realworld/src/c/sha256_hash.c
```

(v1 used wasi-sdk clang; the gen shell pins emscripten instead — standalone
mode emits the same WASI preview1 import surface.)

## rust_sha256/ → wasm/rust_sha256.wasm

```sh
cd test/realworld/src/rust_sha256
cargo build --release --target wasm32-wasip1
cp target/wasm32-wasip1/release/sha256.wasm ../../wasm/rust_sha256.wasm
```

## zig/*.zig → wasm/zig_*.wasm

Zig is on PATH in `nix develop .#gen` (same pinned 0.16.0 as the runtime
itself — self-language dogfood-adjacent corpus). Each source compiles
standalone to wasm32-wasi and writes to stdout via `fd_write` (AssemblyScript
dropped WASI, so Zig is the lean WASI-stdout generator here):

```sh
cd test/realworld/src/zig
for f in hello fib prime_sieve; do
    zig build-exe "$f.zig" -target wasm32-wasi -O ReleaseSmall
    cp "$f.wasm" "../../wasm/zig_$f.wasm"
done
rm -f *.wasm *.o
```

- `hello` — minimal WASI stdout line.
- `fib` — recursive fib(0..24) + i64 math + `bufPrint` (deep call-chain JIT stress).
- `prime_sieve` — Sieve of Eratosthenes over a stack array (linear memory + nested loops).
