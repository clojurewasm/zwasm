# clang `--target=wasm64` + emscripten `-sMEMORY64=1` fixtures (Phase 10 / memory64)

**Toolchain**: clang 21 `--target=wasm64` (nostdlib) for the basic
memory64-addressing case; emcc 3.x `-sMEMORY64=1` for libc-using
big-allocation fixtures. Both emit Wasm 3.0 `(memory i64 ...)` modules.

## Landed fixtures

- `wasm64_load_store.{c,wasm,expect}` (cyc214) — `clang --target=wasm64`
  emits `(memory i64 2)`; the exported `test()` does an i64-addressed
  `i32.store` + `i32.load` (round-trip) → 42. Result-checked through the
  realworld-p10 JIT harness (`build.zig` `run_edge_realworld_p10` →
  `runI32Export`; `.expect` = `i32: 42`). **This fixture surfaced D-209**:
  clang/lld emits the memarg `offset` as a width-padded (9-byte) LEB128 —
  valid for a u64 (memory64) offset (≤ 10 bytes) but the validator +
  lowerer decoded it at u32 width and rejected it as `Error.Overlong`.
  The spec corpus only uses minimal-LEB offsets, so this realworld gap
  was invisible until a real clang binary was run. Fixed cyc214.

**Build recipe (nix-wrapped toolchain; per lesson 2026-05-30 clang recipe)**:
```sh
WASMLD=$(ls -d /nix/store/*lld*/bin | head -1)
PATH="$WASMLD:$PATH" NIX_HARDENING_ENABLE="" clang --target=wasm64 \
    -nostdlib -Wl,--no-entry -Wl,--export-all -O2 \
    -o wasm64_load_store.wasm wasm64_load_store.c
```
(`--target=wasm64` auto-enables memory64; the nix cc-wrapper prints a
cross-target warning but produces a correct binary. Same `-nostdlib`,
`--no-entry`, `--export-all`, `-O2`, `NIX_HARDENING_ENABLE=""` discipline
as the clang_musttail recipe.)

**Planned fixtures** (per design plan §4.3 — emcc + full-instantiation
harness gated, NOT clang-buildable: they need libc malloc/memcpy + a
>4 GiB allocation that `runI32Export` cannot drive):
- `big_alloc.c.wasm` — `malloc(5LL * 1024 * 1024 * 1024)`
  (> 4 GiB; verifies memory64 mmap + i64 offset materialise
  per ADR-0111 D5)
- `big_memcpy.c.wasm` — `memcpy(dst, src, 5LL * 1024 * 1024 * 1024)`
  (verifies bulk-memory bounds-check at 64-bit width)

**Build command (when impl ships)**:
```sh
emcc -sMEMORY64=1 <src>.c -o <name>.c.wasm
```

**Host requirement**: 64-bit host (no Win64-only restriction; both
arm64 + x86_64 work — the runtime mmap call returns a single
contiguous region per Memory).

**Status** (2026-05-26 update): the 10.M impl row interp + codegen
+ SIMD memarg are SHIPPED — memory64 paths are fully exercised by
`test/edge_cases/p10/memory64/` (3 fixtures: page-edge load,
bounds trap, store-load round-trip via i64 addr) and the
`test/spec/wasm-3.0-assert/memory64/` smoke corpus (6 manifests,
337 assert_return + 205 assert_trap directives baked from upstream
spec testsuite). The remaining gap for *this* directory's
realworld fixtures is **toolchain-side**, not impl-side:

- Needs `emcc -sMEMORY64=1` (emscripten 3.x) on the build host
  to compile `big_alloc.c` / `big_memcpy.c` into Wasm binaries.
- Needs a 64-bit test host (Mac aarch64 + Linux x86_64 qualify;
  Win64 also OK per ADR-0111 D5 — `MapViewOfFile3` for >4 GiB).

Once the build host has the toolchain set up (or pre-built
artifacts are sourced from upstream emscripten test suites),
drop the `big_alloc.c.wasm` + `big_memcpy.c.wasm` + matching
`.expect` files here. The `test/realworld/runner.zig` already
walks this directory; the fixtures will execute on landing.

Skip token retired from impl-driven to toolchain-driven:
**`SKIP-P10-MEM64-REALWORLD-TOOLCHAIN`** — emcc not in PATH or
not configured with `-sMEMORY64=1` support. The original
`SKIP-P10-MEM64-GAP` (impl-driven) is dissolved by this update.
