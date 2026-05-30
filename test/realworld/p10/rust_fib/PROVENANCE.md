# Rust → wasm32 fixture: recursive fib (Phase 10 / realworld)

**Toolchain**: rustc 1.96.0 via nix `devShells.gen`
(see [`.dev/toolchain_provisioning.md`](../../../../.dev/toolchain_provisioning.md)).
Mac-generation-only; the committed `.wasm` runs on every host via the edge-runner.

- `fib.{rs,wasm,expect}` (cyc222) — `#![no_std]` recursive fib; `#[inline(never)]`
  keeps it a REAL call (the emitted wasm has `` calling ``, not a folded
  constant), exercising the wasm call stack + call/return through the zwasm JIT.
  `test()->i32` = fib(10) = 55. Distinct from `rust_loop_sum` (which is a loop).

**Build** (inside `nix develop .#gen`):
```sh
rustc --target wasm32-unknown-unknown -O --crate-type=cdylib -o fib.wasm fib.rs
```

**Result-check**: `zig build test-edge-cases` → `run_edge_realworld_p10` → `runI32Export`
`test` → `.expect` = `i32: 55`. **Status**: ACTIVE.
