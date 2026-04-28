# Development Environment

How to set up zwasm for local development and how the same toolchain is
exercised in CI. zwasm officially supports three host environments:
**macOS (Apple Silicon and Intel)**, **Linux x86_64 / aarch64**, and
**Windows x86_64**. All three are part of the GitHub Actions matrix and
all three are expected to satisfy the Commit Gate locally.

## Source of Truth for Tool Versions

Two files together define every pinned tool zwasm depends on:

| File                     | Audience           | Authoritative for                                   |
|--------------------------|--------------------|-----------------------------------------------------|
| `flake.nix`              | Linux / macOS      | Everything Nix manages (Zig, WASI SDK, plus all of `buildInputs`) |
| `.github/versions.lock`  | Windows + CI YAML  | The same pins, mirrored as bash-sourceable `KEY=value` |

`flake.nix` is the originator. `versions.lock` is the mirror used wherever
Nix cannot reach: Windows native installs, GitHub Actions steps that need
a version string before Nix is available (e.g. `actions/setup-zig`,
`cargo install --version`), and any consumer that reads it as plain text.
Bumping a pin requires editing both. See **D136** in `.dev/decisions.md`
for the rationale.

A future `scripts/sync-versions.sh` (Plan B) plus a Merge Gate consistency
check will mechanise the synchronisation. Until then it is a code-review
concern.

## Required Manually (per host OS)

These tools are not delivered by Nix or by the project; the developer has
to install them once:

| OS               | Required by hand                                                                                        |
|------------------|---------------------------------------------------------------------------------------------------------|
| macOS            | `git`, [Nix](https://nixos.org/download/) (Determinate installer recommended), [direnv](https://direnv.net/) + `nix-direnv` |
| Linux x86_64     | `git`, Nix, direnv + nix-direnv                                                                         |
| Linux (OrbStack) | Same as Linux. VM bootstrap covered in `setup-orbstack.md`.                                             |
| Windows x86_64   | `git` (Git for Windows — supplies bash + curl + tar + unzip), Python 3.x, PowerShell 7, winget          |

Everything else (Zig, wasm-tools, wasmtime, WASI SDK, hyperfine, jq, yq,
Go, TinyGo, Node.js, Bun) is delivered by `flake.nix` on Linux/macOS, and
will be delivered by `scripts/windows/install-tools.ps1` on Windows once
Plan B lands (manual install steps below for now).

## macOS

### One-time bootstrap

```bash
# 1. Nix (Determinate installer)
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install

# 2. direnv + nix-direnv
brew install direnv nix-direnv
echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc   # or bash equivalent
mkdir -p ~/.config/nix && echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

# 3. Allow this repo's flake
cd /path/to/zwasm
direnv allow
```

After `direnv allow`, every shell entering the repo has Zig 0.16.0,
Python 3.13, wasm-tools, wasmtime, WASI SDK, hyperfine, jq, yq-go,
TinyGo, Go, Node.js, Bun, and GNU coreutils on `PATH` automatically.
There is no `nix develop --command` wrapper to remember.

### Daily

```bash
zig build test                                       # Unit tests
python test/spec/run_spec.py --build --summary       # Spec
python test/e2e/run_e2e.py --convert --summary       # E2E
python test/realworld/build_all.py                   # Build real-world wasm
python test/realworld/run_compat.py                  # Compat vs wasmtime
bash test/c_api/run_ffi_test.sh --build              # FFI dynamic
bash bench/run_bench.sh --quick                      # Quick bench
```

The full Commit Gate / Merge Gate checklist lives in `CLAUDE.md`.

## Linux (Ubuntu x86_64)

### Native Linux (host or full VM)

Same procedure as macOS, swapping the package manager for Nix
installation:

```bash
sh <(curl -L https://nixos.org/nix/install) --daemon
# direnv + nix-direnv via apt or your package manager
sudo apt install direnv
nix profile install nixpkgs#nix-direnv
direnv allow
```

### OrbStack VM on Apple Silicon

Used for x86_64 verification of code changes that need to land on Linux
amd64 before merging (Merge Gate requirement).

- VM creation and tool installation: `setup-orbstack.md`
- Run-time commands: `ubuntu-testing-guide.md`

> **Note**: `setup-orbstack.md` predates the Nix-as-SSoT decision
> (D136) and currently bootstraps tools manually with versions that
> drift from `flake.nix`. Migrating the VM to Nix devshell + direnv
> is tracked as a Plan B follow-up. Until then, after pulling a
> change that bumps a pin, re-run the affected steps in
> `setup-orbstack.md` (or just install Nix inside the VM and use the
> macOS recipe above).

## Windows

Windows uses **native tooling**, not WSL. The whole reason Windows is in
the matrix is to validate native PE/COFF and MSVC behaviour; routing
through WSL would re-test Linux. See **D136** for the rationale.

### One-time bootstrap (manual until Plan B's installer ships)

Pre-install via winget (run in admin PowerShell once):

```powershell
winget install --id Git.Git -e
winget install --id Microsoft.PowerShell -e
winget install --id Python.Python.3.14 -e
```

Then install the version-pinned tools by reading `.github/versions.lock`
and downloading each release. The pins to use today (Plan A baseline):

| Tool           | Pin     | Source                                                                                          |
|----------------|---------|-------------------------------------------------------------------------------------------------|
| Zig            | 0.16.0  | `https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip`                              |
| WASI SDK       | 30      | `https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-30/wasi-sdk-30.0-x86_64-windows.tar.gz` |
| wasm-tools     | 1.246.1 | `https://github.com/bytecodealliance/wasm-tools/releases/...`                                  |
| wasmtime       | 42.0.1  | `https://github.com/bytecodealliance/wasmtime/releases/...`                                    |
| Rust           | stable  | `rustup-init.exe` (cargo, target `wasm32-wasip1` for realworld/Rust)                           |

After install, set `WASI_SDK_PATH` to the extracted SDK root and ensure
`zig`, `wasm-tools`, `wasmtime` are on `PATH`.

### Daily (under Git for Windows bash)

```bash
zig build test
zig build c-test                          # C API tests via Zig harness
python test/spec/run_spec.py --build --summary
python test/e2e/run_e2e.py --convert --summary
python test/realworld/build_all.py
python test/realworld/run_compat.py
```

### Currently-skipped CI items on Windows (Plan C tracker)

These are the steps `ci.yml` guards with `if: runner.os != 'Windows'`.
They are blockers for "Windows reaches Merge Gate parity" and tracked as
Plan C work. None reflects a fundamental Windows incompatibility — every
one is a script-side limitation:

| Step                                    | Blocker                                                 | Fix shape                                                  |
|-----------------------------------------|---------------------------------------------------------|------------------------------------------------------------|
| `zig build shared-lib`                  | None known; just gated                                  | Drop `if:`                                                 |
| `test/c_api/run_ffi_test.sh`            | `gcc -ldl -pthread`, `dlfcn.h` in `test_ffi.c`          | Branch for `LoadLibraryA` + `GetProcAddress` (~50 lines C) |
| `examples/rust` `cargo run`             | `build.rs` solves dynamic-lib path Linux/Mac only       | Add Windows branch in `build.rs`                           |
| `zig build static-lib` + static link    | Shell script assumes `cc`                               | Branch by `RUNNER_OS`                                      |
| Binary size check                       | Uses GNU `strip`                                        | Replace with `zig objcopy --strip-all` (cross-platform)    |
| Memory check                            | Uses `/usr/bin/time -l` / `-v`                          | PowerShell `Measure-Command` + `Get-Process.PeakWorkingSet`|
| `size-matrix` job                       | `strip` again                                           | Same `zig objcopy` fix; fan out matrix to all 3 OS         |
| `benchmark` job                         | `hyperfine` install via DEB                             | Add Windows install step (winget or release ZIP); record-only on Windows |

## Nix devshell contents (current)

`flake.nix` provides the following on Linux/macOS via `buildInputs`:

| Package            | Used by                                                        |
|--------------------|----------------------------------------------------------------|
| `zigBin` (0.16.0)  | All builds and tests                                           |
| `wasmtime`         | Realworld compat comparison runtime                            |
| `bun`, `nodejs`    | `bench/run_wasm.mjs`, `bench/run_wasm_wasi.mjs`                |
| `yq-go`, `jq`      | Bench result transformation, history.yaml editing              |
| `hyperfine`        | All bench scripts                                              |
| `tinygo`           | `bench/wasm/tgo_*.wasm` and `realworld/tinygo/`                |
| `wasm-tools`       | `json-from-wast` for spec test conversion, component inspection|
| `go`               | `realworld/go/` (`GOOS=wasip1 GOARCH=wasm`)                    |
| `gnused`, `coreutils` | Stable shell env for bench / test scripts                   |
| `python3`          | All `test/**/*.py` runners                                     |
| `wasiSdkBin` (30)  | `WASI_SDK_PATH` for realworld C / C++                          |

Rust toolchain is **not** in `flake.nix` — `realworld/build_all.py`
expects `rustup` from `~/.cargo/bin`. CI installs it via `rustup`. The
nix devshell user is expected to install Rust outside Nix. (This is
called out in `flake.nix` as a comment.)

## CI ↔ Local Gate Mapping

Today, CI installs each tool individually rather than entering a Nix
devshell, so local and CI run "the same gates" only by convention. Plan B
collapses this onto a shared `scripts/gate-*.sh` family of entry points
that both contexts invoke identically.

| Gate                                  | Local (today)                          | CI (today)                                   | Future (Plan B)                              |
|---------------------------------------|----------------------------------------|----------------------------------------------|----------------------------------------------|
| Commit Gate (CLAUDE.md items 0-8)     | Hand-run individual commands           | `ci.yml > test` job                          | `bash scripts/gate-commit.sh` everywhere     |
| Merge Gate (Mac + Ubuntu both clean)  | Manual checklist + OrbStack            | `ci.yml > test` (3 OS) + `size-matrix`       | `bash scripts/gate-merge.sh` + versions.lock check |
| Bench (regression + record)           | `bash bench/run_bench.sh`              | `ci.yml > benchmark` (Ubuntu only)           | `bash scripts/run-bench.sh` (Linux reference + Windows record-only) |
| Nightly fuzz                          | `bash test/fuzz/fuzz_overnight.sh`     | `nightly.yml > fuzz`                         | Same scripts; Linux/Mac under `nix develop`  |

In Plan B, CI on Linux/macOS will use
`DeterminateSystems/nix-installer-action` +
`DeterminateSystems/magic-nix-cache-action`, then call the gate scripts
under `nix develop --command`. Windows CI will run
`scripts/windows/install-tools.ps1` (which reads `versions.lock`) and
then call the same gate scripts under Git Bash.

## References

- `flake.nix` — the SSoT for Linux/macOS pins
- `.github/versions.lock` — the SSoT mirror for Windows / CI YAML
- `.github/workflows/ci.yml` — current CI definition
- `.dev/decisions.md` — D136 captures the SSoT design and Plan B/C scope
- `.dev/references/setup-orbstack.md` — Apple Silicon Ubuntu VM bootstrap (manual; Nix migration tracked as Plan B follow-up)
- `.dev/references/ubuntu-testing-guide.md` — Run-time recipes inside the OrbStack VM
- `CLAUDE.md` — Commit Gate / Merge Gate checklists
