# Contributor Guide

## Build and test

```bash
git clone https://github.com/clojurewasm/zwasm.git
cd zwasm

# Run the entire Commit Gate (build + tests + spec + e2e + realworld + FFI + minimal)
bash scripts/gate-commit.sh

# Or, the underlying steps directly when iterating:
zig build
zig build test
zig build test -- "Module — rejects excessive locals"
python3 test/spec/run_spec.py --build --summary
bash scripts/run-bench.sh --quick
```

## Requirements

- Zig 0.16.0 (toolchain pinned; on macOS / Linux Nix devshell delivers it
  via `flake.nix`. On Windows run `pwsh scripts/windows/install-tools.ps1`
  to provision it from `.github/versions.lock`.)
- Python 3 (spec / e2e / realworld test runners)
- [wasm-tools](https://github.com/bytecodealliance/wasm-tools) — spec test conversion
- [hyperfine](https://github.com/sharkdp/hyperfine) — benchmarks
- [wasmtime](https://github.com/bytecodealliance/wasmtime) — realworld compat oracle
- [WASI SDK](https://github.com/WebAssembly/wasi-sdk) — realworld C/C++ → wasm

See `.dev/environment.md` for the full developer setup; toolchain pins
live in `.github/versions.lock` / `flake.nix`.

## Code structure

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
  realworld/      Real-world compatibility tests (50 programs: Rust, C, C++, TinyGo)
bench/
  run_bench.sh    Benchmark runner (interactive)
  record.sh       Record results to history.yaml (5 runs + 3 warmup, full)
  ci_compare.sh   CI regression check (Ubuntu vs Ubuntu)
  wasm/           Benchmark wasm modules
scripts/
  gate-commit.sh  Commit Gate one-liner (CLAUDE.md items 1-5 + 8)
  gate-merge.sh   Merge Gate one-liner (Commit Gate + sync + CI check)
  sync-versions.sh        versions.lock ↔ flake.nix consistency
  run-bench.sh    Wrapper around bench/run_bench.sh
  record-merge-bench.sh   Post-merge bench record (Mac only)
  windows/install-tools.ps1   Windows toolchain provisioner
```

## Development workflow

1. Create a feature branch: `git checkout -b feature/my-change`
2. Write a failing test first (TDD)
3. Implement the minimum code to pass
4. Run tests: `zig build test`
5. If you changed the interpreter or opcodes, run spec tests
6. Commit with a descriptive message
7. Open a PR against `main`

## Commit guidelines

- One logical change per commit
- Commit message: imperative mood, concise subject line
- Include test changes in the same commit as the code they test

## CI checks

PRs are automatically checked for:
- Unit test pass (macOS + Ubuntu + Windows)
- Spec test pass (62,263 tests)
- E2E test pass (796 assertions)
- Binary size <= 1.60 MB (stripped, Linux ELF ~1.56 MB; Mac Mach-O ~1.20 MB)
- No benchmark regression > 20%
- ReleaseSafe build success
