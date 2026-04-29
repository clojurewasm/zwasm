# Contributing to zwasm

Thank you for your interest in contributing!

## Quick start

```bash
git clone https://github.com/clojurewasm/zwasm.git
cd zwasm
bash scripts/gate-commit.sh   # Build + tests + spec + e2e + realworld + minimal
```

Requires **Zig 0.16.0**. See [Requirements](#requirements) below. Full
developer setup (Mac / Linux / Windows, Nix devshell, Windows installer)
in [`.dev/environment.md`](./.dev/environment.md).

## Development workflow

1. Create a feature branch: `git checkout -b develop/<task>`
2. Write a failing test first (TDD)
3. Implement the minimum code to pass
4. Run the Commit Gate: `bash scripts/gate-commit.sh`
5. Commit with a descriptive message (one logical change per commit)
6. Open a PR against `main`

## Requirements

- **Zig 0.16.0** (pinned in `.github/versions.lock` / `flake.nix`).
  On Mac/Linux Nix devshell delivers it via direnv; on Windows run
  `pwsh scripts/windows/install-tools.ps1` to provision it (plus
  wasm-tools / wasmtime / WASI SDK / VC++ Redist).
- Python 3 (spec / e2e / realworld test runners)
- [wasm-tools](https://github.com/bytecodealliance/wasm-tools) — spec test conversion
- [hyperfine](https://github.com/sharkdp/hyperfine) — benchmarks
- [wasmtime](https://github.com/bytecodealliance/wasmtime) — realworld compat oracle
- [WASI SDK](https://github.com/WebAssembly/wasi-sdk) — realworld C/C++ → wasm

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
  component.zig   Component Model decoder
  wit.zig         WIT type system
  canon_abi.zig   Canonical ABI
test/
  spec/           WebAssembly spec tests (62,263 tests)
  e2e/            End-to-end tests (796 assertions)
  realworld/      Real-world compatibility tests (50 programs)
  fuzz/           Fuzz testing infrastructure
bench/
  run_bench.sh    Benchmark runner
  wasm/           Benchmark wasm modules
examples/
  zig/            Zig embedding examples (5 files)
  wat/            Educational WAT examples (33 files)
```

## CI checks

PRs are automatically checked for:

- Unit tests pass (macOS + Ubuntu + Windows)
- Spec tests pass (62,263 tests)
- E2E tests pass (796 assertions)
- Real-world compat (Mac+Ubuntu 50/50; Windows 25/25 C+C++ subset)
- FFI tests pass (Mac+Ubuntu+Windows; 80 cases)
- Minimal build (`-Djit=false -Dcomponent=false -Dwat=false`) compiles and tests pass
- `versions.lock` ↔ `flake.nix` agree (mechanised by `versions-lock-sync` job)
- Binary size: Mac ≤ 1.30 MB, Linux ≤ 1.60 MB, Windows ≤ 1.80 MB (stripped via `-Dstrip=true`; observed ~1.20 MB Mac, ~1.56 MB Linux, ~1.70 MB Windows). Originally 1.50 MB on Zig 0.15; raised to 1.80 MB as a pragmatic compromise during the Zig 0.16 / `link_libc = true` transition; pulled back to per-OS ceilings after W46 (link_libc=false restored) + W48 Phase 1 (panic / segfault / u8-main trim) + D137 (cross-platform stripping + per-OS ceilings). Reaching the original 1.50 MB Linux target is tracked as W48 Phase 2 (see `.dev/checklist.md`) — non-blocking.
- No benchmark regression > 20% (Ubuntu-vs-Ubuntu, soft check via `bench/ci_compare.sh`)
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
