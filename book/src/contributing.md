# Contributor Guide

## Build and test

```bash
git clone https://github.com/syumai/zwasm.git
cd zwasm

# Build
zig build

# Run unit tests
zig build test

# Run a specific test
zig build test -- "Module — rejects excessive locals"

# Run spec tests (requires wasm-tools)
python3 test/spec/run_spec.py --build --summary

# Run benchmarks
bash bench/run_bench.sh --quick
```

## Requirements

- Zig 0.15.2
- Python 3 (for spec test runner)
- [wasm-tools](https://github.com/bytecodealliance/wasm-tools) (for spec test conversion)
- [hyperfine](https://github.com/sharkdp/hyperfine) (for benchmarks)

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
  e2e/            End-to-end tests (wasmtime misc_testsuite)
  fuzz/           Fuzz testing infrastructure
bench/
  run_bench.sh    Benchmark runner
  record.sh       Record results to history.yaml
  wasm/           Benchmark wasm modules
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
- Unit test pass (macOS + Ubuntu)
- Spec test pass (62,158 tests)
- E2E test pass (356 assertions)
- Binary size <= 1.5 MB
- No benchmark regression > 20%
- ReleaseSafe build success
