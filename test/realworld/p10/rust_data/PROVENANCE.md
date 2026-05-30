# Rust → wasm32 fixture: static data + shadow stack (Phase 10 / realworld)

**Toolchain**: rustc 1.96.0 via nix `devShells.gen`
([`.dev/toolchain_provisioning.md`](../../../../.dev/toolchain_provisioning.md)).

- `data_sum.{rs,wasm,expect}` (cyc224) — `#![no_std]` sum of a `static [i32;8]`
  via indexed loads, with `core::hint::black_box` on the index so rustc CANNOT
  const-fold → the emitted wasm does real `i32.load` (data-segment-backed) +
  bounds-check `br_if` AND spills the index to the **shadow stack**
  (`__stack_pointer` global). 3+1+4+1+5+9+2+6 = 31.
- **This fixture surfaced a real runI32Export harness bug**: `setupRuntime` left
  defined globals at 0 instead of evaluating their init-exprs, so `__stack_pointer`
  (init `i32.const 1048576`) was 0 → `SP - n` wrapped to a huge OOB address → trap.
  Fixed cyc224 (`src/engine/setup.zig` now evaluates const global inits). The
  harness can now run shadow-stack modules (real `-O` rust/clang code), not just
  trivial no-stack fixtures.

**Build** (inside `nix develop .#gen`):
```sh
rustc --target wasm32-unknown-unknown -O --crate-type=cdylib -o data_sum.wasm data_sum.rs
```
**Result-check**: `run_edge_realworld_p10` → `runI32Export` `test` → `i32: 31`. ACTIVE.
