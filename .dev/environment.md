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

`scripts/sync-versions.sh` (run by `scripts/gate-merge.sh`) mechanises
the consistency check; the Merge Gate item #9 in `CLAUDE.md` invokes
it automatically.

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
by `scripts/windows/install-tools.ps1` on Windows. Rust / Go / TinyGo
are not yet covered by the Windows installer (W52); the four core
tools — Zig, wasm-tools, wasmtime, WASI SDK — and Microsoft Visual
C++ Redistributable (a WASI SDK dependency) are auto-installed.

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
bash scripts/gate-commit.sh        # Commit Gate (steps 1-5 + 8)
bash scripts/gate-commit.sh --bench # + quick bench
bash scripts/gate-merge.sh         # Merge Gate (Commit + sync + CI check)
bash scripts/run-bench.sh --quick  # Bench wrapper
bash scripts/sync-versions.sh      # Manual versions.lock ↔ flake.nix check
```

Individual commands still work for ad-hoc loops:

```bash
zig build test
python test/spec/run_spec.py --build --summary
python test/e2e/run_e2e.py --convert --summary
python test/realworld/build_all.py && python test/realworld/run_compat.py
bash test/c_api/run_ffi_test.sh --build
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

> **Note**: `setup-orbstack.md` still bootstraps tools manually
> (matching `versions.lock` pins as of 2026-04-29 — Zig 0.16.0,
> wasm-tools 1.246.1, wasmtime 42.0.1, WASI SDK 30). Migrating the
> VM to Nix devshell + direnv is tracked as W50 (Plan B sub-3
> follow-up). After pulling a change that bumps a pin, re-run the
> affected steps in `setup-orbstack.md`, or install Nix inside the
> VM and use the macOS recipe above.

## Windows

Windows uses **native tooling**, not WSL. The whole reason Windows is in
the matrix is to validate native PE/COFF and MSVC behaviour; routing
through WSL would re-test Linux. See **D136** for the rationale.

### One-time bootstrap

Pre-install the three things `install-tools.ps1` cannot bootstrap from
versions.lock alone. Run once in any PowerShell (admin not required for
user-scope installs):

```powershell
winget install --id Git.Git -e
winget install --id Microsoft.PowerShell -e
winget install --id Python.Python.3.14 -e
```

Then run the installer. It reads `.github/versions.lock` and provisions
Zig, wasm-tools, wasmtime, WASI SDK into `%LOCALAPPDATA%\zwasm-tools`,
wires them into the user-scope `PATH`, sets `WASI_SDK_PATH`, and
auto-installs Microsoft Visual C++ Redistributable (a WASI SDK clang
dependency) via winget when missing:

```powershell
pwsh -NoLogo -ExecutionPolicy Bypass -File scripts\windows\install-tools.ps1
```

The script is idempotent — re-running on the same versions skips the
download. Pass `-Force` to re-extract anyway, or `-OnlyTool zig` /
`-OnlyTool wasm-tools` etc. to install one tool. Open a fresh shell
afterwards so the new `PATH` / `WASI_SDK_PATH` take effect.

For Rust, Go, and TinyGo (needed only for the realworld Rust / Go /
TinyGo subset of `build_all.py` — the C and C++ subset works without
them), install separately via `rustup-init.exe`, the official Go
installer, and TinyGo's release page. Adding these to
`install-tools.ps1` is tracked as W52.

### Daily (under Git for Windows bash)

```bash
bash scripts/gate-commit.sh        # Commit Gate (auto-skips ffi to mirror CI)
bash scripts/gate-commit.sh --bench # + quick bench
```

Individual commands also work:

```bash
zig build test
zig build c-test                          # C API tests via Zig harness
python test/spec/run_spec.py --build --summary
python test/e2e/run_e2e.py --convert --summary
python test/realworld/build_all.py
python test/realworld/run_compat.py
```

### Currently-skipped CI items on Windows (Plan C tracker)

These are the steps `ci.yml` still guards with `if: runner.os != 'Windows'`.
They are blockers for "Windows reaches Merge Gate parity" and tracked as
Plan C work (W49 in `checklist.md`; per-item table with risk classification
in `.dev/resume-guide.md`). None reflects a fundamental Windows
incompatibility — every one is a script-side limitation:

| Step                                    | Blocker                                                 | Fix shape                                                  |
|-----------------------------------------|---------------------------------------------------------|------------------------------------------------------------|
| `test/c_api/run_ffi_test.sh`            | `gcc -ldl -pthread`, `dlfcn.h` in `test_ffi.c`          | Branch for `LoadLibraryA` + `GetProcAddress` (~50 lines C) |
| `examples/rust` `cargo run`             | `build.rs` solves dynamic-lib path Linux/Mac only       | Add Windows branch in `build.rs`                           |
| `zig build static-lib` + static link    | Shell script assumes `cc`                               | Branch by `RUNNER_OS`                                      |
| Binary size check                       | Uses GNU `strip`                                        | Expose `-Dstrip=true` in build.zig and measure directly (Mach-O / ELF / PE all handled by Zig) |
| `size-matrix` job                       | `strip` again                                           | Same fix as binary size check; fan out to OS matrix        |
| `benchmark` job                         | `hyperfine` install via DEB; `bench/ci_compare.sh` GNU dependencies | Add Windows install step + audit ci_compare.sh portability |

(Memory check is no longer in this table — PR #64 added a PowerShell
`Process.PeakWorkingSet64` branch for the Windows runner. `zig build
shared-lib` is no longer in this table — the guard was a no-op since
Zig produces `zwasm.dll` + `zwasm.lib` natively from
`addLibrary({.linkage = .dynamic})`.)

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

| Gate                                  | Local                                  | CI (current)                                   |
|---------------------------------------|----------------------------------------|------------------------------------------------|
| Commit Gate (CLAUDE.md items 1-5+8)   | `bash scripts/gate-commit.sh`          | `ci.yml > test` job (3 OS, runs same commands) |
| Merge Gate (Mac + Ubuntu both clean)  | `bash scripts/gate-merge.sh` (Mac + OrbStack Ubuntu) | `ci.yml > test` (3 OS) + `size-matrix` |
| Bench (regression + record)           | `bash scripts/run-bench.sh`            | `ci.yml > benchmark` (Ubuntu only today)       |
| Nightly fuzz                          | `bash test/fuzz/fuzz_overnight.sh`     | `nightly.yml > fuzz`                           |

A future PR will switch CI Linux/macOS jobs to
`DeterminateSystems/nix-installer-action` +
`DeterminateSystems/magic-nix-cache-action`, calling the same gate
scripts under `nix develop --command`. Windows CI will then run
`scripts/windows/install-tools.ps1` (reads `versions.lock`) and then
the gate scripts under Git Bash. This ensures CI and local invoke
the exact same commands.

## References

- `flake.nix` — the SSoT for Linux/macOS pins
- `.github/versions.lock` — the SSoT mirror for Windows / CI YAML
- `.github/workflows/ci.yml` — current CI definition
- `.dev/decisions.md` — D136 captures the SSoT design and Plan B/C scope
- `.dev/references/setup-orbstack.md` — Apple Silicon Ubuntu VM bootstrap (manual; Nix migration tracked as Plan B follow-up)
- `.dev/references/ubuntu-testing-guide.md` — Run-time recipes inside the OrbStack VM
- `CLAUDE.md` — Commit Gate / Merge Gate checklists
