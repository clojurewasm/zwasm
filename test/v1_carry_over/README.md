# v1 carry-over regression corpus (§9.6 / 6.0)

zwasm v1 vendored a `test/e2e/wast/` bundle of regression-specific
`.wast` files — fuzz-found bugs, edge cases reported against
wasmtime's `misc_testsuite`, and embenchen integration patterns —
that were never absorbed back into the upstream WebAssembly spec
testsuite. v2 inherits this coverage so a regression v1 caught
once doesn't reappear in v2.

## Layout

Each subdirectory mirrors `test/spec/wasm-2.0/<name>/`: a
`manifest.txt` plus the `.wasm` files referenced by it. The same
`test/spec/wast_runner.zig` consumes the layout — `valid` /
`invalid` / `malformed` directives, parse + validate gate.

## Vendoring policy

- **Source**: `~/Documents/MyProducts/zwasm/test/e2e/wast/` (the
  v1 reference clone). Override path via `ZWASM_V1_REPO`.
- **Tool**: `wast2json` from wabt (already pinned in `flake.nix`).
- **Regen**: `bash scripts/regen_v1_carry_over.sh`. Adds an
  entry to `NAMES` is positive opt-in — every emitted module
  must pass `zig build test-v1-carry-over` before commit.
- **Scope (current)**: Wasm 1.0 / 2.0 features only. GC / EH /
  threads / SIMD / multi-memory carry-overs land alongside their
  enabling phases (10 / 9 / post-Phase-15).
- **Externally-authored**: the `.wast` files originated in
  wasmtime's `crates/wast/tests/misc_testsuite/`; v1 vendored
  them, v2 re-vendors. The
  [`no_copy_from_v1` rule](../../.claude/rules/no_copy_from_v1.md)
  exempts third-party test fixtures.

## Adding a regression

1. Pick the `.wast` filename from v1's `test/e2e/wast/`.
2. Append it to `NAMES` in `scripts/regen_v1_carry_over.sh`.
3. `bash scripts/regen_v1_carry_over.sh`.
4. `zig build test-v1-carry-over` — must pass on Mac AND
   OrbStack Ubuntu AND windowsmini SSH.
5. If the build fails on a host, the entry surfaces a v2
   validator gap. Open a follow-up §9.6 task; do not silently
   drop the entry.

## Out of scope (today)

Runtime assertion checks (`assert_return`, `assert_trap`) are
not part of the parse + validate gate the current runner
provides. The §9.6 / 6.1 + 6.2 tasks add the realworld coverage
+ differential gate that exercises runtime behaviour; the
matching extension to this corpus lands when those tasks need
runtime-checking modules here.
