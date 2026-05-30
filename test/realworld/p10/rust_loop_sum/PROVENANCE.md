# Rust → wasm32 fixtures (Phase 10 / realworld)

**Toolchain**: `rustc 1.96.0 (ac68faa20 2026-05-25)` — provided by the
nix `devShells.gen` (see `.dev/toolchain_provisioning.md`). Mac-generation-
only; the committed `.wasm` runs on every host via the edge-runner.

## Landed fixtures

- `loop_sum.{rs,wasm,expect}` (cyc221) — a `#![no_std]` Rust function summing
  0..10 in a real `while` loop, exported as `test() -> i32` → 45. The first
  REAL Rust-toolchain realworld fixture: rustc's own codegen (loop, locals,
  br_if) exercised end-to-end through the zwasm JIT (`runI32Export`), unlike
  hand-written WAT. Result-checked by the realworld-p10 edge-runner
  (`build.zig run_edge_realworld_p10`; `.expect` = `i32: 45`).

## Build recipe (inside `nix develop .#gen`)

```sh
nix develop .#gen --command \
  rustc --target wasm32-unknown-unknown -O --crate-type=cdylib \
    -o loop_sum.wasm loop_sum.rs
```

`#![no_std]` + a `#[panic_handler]` keep it std/libc-free so it links and
runs through the no-instantiation edge-runner. `-O` keeps the body small
(no shadow-stack spill).

## Result-check harness

`zig build test-edge-cases` → `run_edge_realworld_p10` walks
`test/realworld/p10/**`, JIT-runs each `.wasm`'s `test` export via
`runI32Export`, and byte-checks the result against `.expect`.

**Status**: ACTIVE. Follow-ons: a non-folding arithmetic fixture; go→wasip1;
emcc `-sMEMORY64=1` (the planned `clang_wasm64/` big-alloc corpus).
