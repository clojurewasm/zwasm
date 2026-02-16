# Contributing to zwasm

Thank you for your interest in contributing!

## Quick start

```bash
git clone https://github.com/clojurewasm/zwasm.git
cd zwasm
zig build test    # Run all tests (~425)
```

Requires **Zig 0.15.2**. See [Requirements](#requirements) for optional tools.

## Development workflow

1. Create a feature branch: `git checkout -b feature/my-change`
2. Write a failing test first (TDD)
3. Implement the minimum code to pass
4. Run tests: `zig build test`
5. If you changed the interpreter or opcodes, run spec tests:
   `python3 test/spec/run_spec.py --build --summary`
6. Commit with a descriptive message (one logical change per commit)
7. Open a PR against `main`

## Requirements

- **Zig 0.15.2** (required)
- Python 3 (for spec test runner)
- [wasm-tools](https://github.com/bytecodealliance/wasm-tools) (for spec test conversion)
- [hyperfine](https://github.com/sharkdp/hyperfine) (for benchmarks)

## Code structure

```
src/
  types.zig       Public API (WasmModule, WasmFn, etc.)
  module.zig      Binary decoder
  validate.zig    Type checker
  predecode.zig   Stack -> register IR
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
  spec/           WebAssembly spec tests (62,158 tests)
  e2e/            End-to-end tests (356 assertions)
  fuzz/           Fuzz testing infrastructure
bench/
  run_bench.sh    Benchmark runner
  wasm/           Benchmark wasm modules
examples/
  basic.zig       Load and call a function
  memory.zig      Read/write linear memory
  inspect.zig     List exports with signatures
```

## CI checks

PRs are automatically checked for:

- Unit tests pass (macOS + Ubuntu)
- Spec tests pass (62,158 tests)
- E2E tests pass (356 assertions)
- Binary size <= 1.5 MB
- No benchmark regression > 20%
- ReleaseSafe build success

## Commit guidelines

- One logical change per commit
- Imperative mood subject line (e.g., "Add validation for table types")
- Include tests in the same commit as the code they test

## Reporting issues

- Bug reports: use the [bug report template](https://github.com/clojurewasm/zwasm/issues/new?template=bug_report.yml)
- Feature requests: use the [feature request template](https://github.com/clojurewasm/zwasm/issues/new?template=feature_request.yml)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
