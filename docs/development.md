# Developing zwasm

This is the single entry point for building, testing, and contributing to
zwasm on a fresh machine. If any other document disagrees with this one about
the development environment, this one wins (design/architecture questions are
owned by [`.dev/ROADMAP.md`](../.dev/ROADMAP.md)).

**The short version: you need Zig 0.16.0. Nothing else.** The authoritative
test gate is GitHub CI, which runs the 3-OS matrix on every pull request
(macOS + Linux blocking, Windows advisory) — you do not need multiple
machines, SSH hosts, Nix, or any maintainer-specific setup to contribute.

## Quick start

```sh
git clone https://github.com/clojurewasm/zwasm
cd zwasm
zig build                # compile the CLI + library
zig build test           # unit tests
zig build test-all       # every enabled test layer (what CI runs)
zig fmt src/             # format before committing
```

`zig version` must print `0.16.0` — the project pins it exactly
(`.github/versions.lock`, `flake.nix`). Get it from
[ziglang.org/download](https://ziglang.org/download/) or via the Nix shell
below.

## Tools: required vs optional

| Tool | Status | Used for |
|---|---|---|
| Zig 0.16.0 (exact) | **required** | everything |
| git | **required** | everything |
| [wasmtime](https://wasmtime.dev/) | optional | differential oracle in some suites — absent = those comparisons **skip**, never fail |
| Nix (flakes) | optional | reproducible dev shell (`nix develop`), fixture regeneration shells |
| `yq` (mikefarah v4) | optional | `.dev/debt.yaml` ledger checks in the pre-commit hook — guarded, prints an install pointer if missing |
| hyperfine / wasm-tools / wabt | optional | benchmarks, fixture tooling — all guarded |

The committed test corpus (spec suite, WASI conformance, real-world `.wasm`
fixtures) runs with **no toolchain beyond Zig**. Regenerating fixtures from
source (emcc / TinyGo / Rust) is a maintainer task using the Nix `gen`
shells — contributors never need it; the `.wasm` files are committed.

## Test layers

| Command | What it runs |
|---|---|
| `zig build test` | unit tests (all zones) |
| `zig build test-spec` | Wasm spec testsuite (1.0/2.0/3.0) |
| `zig build test-wasi-p1` | WASI 0.1 fixture suite |
| `zig build test-wasi-p3` | WASI 0.3 (Component-Model async) incl. the official conformance corpus |
| `zig build test-realworld` / `test-realworld-run` | real-world `.wasm` fixtures (parse / run) |
| `zig build test-all` | all of the above (the CI core gate) |
| `zig build lint -- --max-warnings 0` | project linter |

## The merge gate — CI is authoritative

`main` is protected: every change lands via a branch → pull request → the
required **`ci-required`** status check. CI runs
[`scripts/ci_gate.sh`](../scripts/ci_gate.sh) (fmt + `test-all`, plus
extended static/build checks) on **all three supported OSes** — macOS
aarch64, Linux x86_64, Windows x86_64. The macOS and Linux legs are
blocking; the Windows leg currently runs **advisory** (reported on every PR,
not merge-blocking — see the `advisory` flag in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml)). There is no
additional hidden gate beyond CI.

Doc-only PRs (Markdown, `docs/`, `.dev/`, `.claude/`, `LICENSE`) skip the
heavy 3-OS legs automatically and are gated by the fast `doc-truth` job
instead.

To run exactly what CI runs, locally, on your own machine:

```sh
bash scripts/ci_gate.sh                    # core (fmt + test-all)
ZWASM_CI_EXTENDED=1 bash scripts/ci_gate.sh  # + lint/DCE/AOT/zone checks (Unix)
```

## Git hooks (recommended)

The repo ships its hooks in `.githooks/` (fast static checks at commit,
cheap ratchet audits at push). Activate them once per clone:

```sh
git config core.hooksPath .githooks
```

The Nix dev shell does this automatically; on a plain checkout it is this
one command. The hooks are advisory helpers — CI re-checks everything.

## Nix (optional)

```sh
nix develop            # pinned Zig + wabt + wasmtime + wasm-tools + lldb
nix develop .#bench    # + hyperfine, for benchmarks
```

Maintainer-only shells: `.#gen` / `.#gen-wasip3` (fixture regeneration
toolchains — see [`.dev/toolchain_provisioning.md`](../.dev/toolchain_provisioning.md)),
`.#rust-host` (the Rust embedding-consumer test).

## Things you may see referenced but do NOT need

- **SSH gate hosts** (`ubuntunote`, `windowsmini`): the maintainer's private
  pre-PR mirror of the CI matrix
  ([`scripts/gate_merge.sh`](../scripts/gate_merge.sh),
  `scripts/run_remote_*.sh`). Entirely optional — CI is the gate. To run the
  same fan-out against **your own** hosts (matching architectures: x86_64
  Linux + x86_64 Windows), copy
  [`scripts/dev_hosts.env.example`](../scripts/dev_hosts.env.example) to
  `scripts/dev_hosts.env` (gitignored) and edit the three values — every
  remote-gate script sources it. Host provisioning notes:
  `.dev/ubuntunote_setup.md` / `.dev/windows_ssh_setup.md`.
- **`private/`**: a gitignored maintainer scratch directory (spikes, notes,
  debug repros). No build or test path requires it; scripts that look inside
  it skip cleanly when it is absent. Never create it for a contribution.
- **Reference clones** (`~/Documents/OSS/...` paths in `.dev/` docs): the
  maintainer's local layout for reading other runtimes' source
  ([`.dev/reference_clones.md`](../.dev/reference_clones.md)) — not required
  to build, test, or review.
- **`.claude/`**: AI-agent workflow scaffolding (skills, session rules).
  Interesting as documentation of how the project is developed, but nothing
  in it is needed to contribute by hand.

## Project conventions (pointers)

- **Where decisions live**: [`.dev/ROADMAP.md`](../.dev/ROADMAP.md) (mission /
  architecture / phase plan — the design SSOT),
  [`.dev/decisions/`](../.dev/decisions/) (ADRs),
  [`.dev/debt.yaml`](../.dev/debt.yaml) (tech-debt ledger),
  [`.dev/lessons/`](../.dev/lessons/) (observational notes).
- **Language policy**: code, comments, commits, docs — English.
- **Layering**: `src/` is organized in import-ordered zones (support/platform
  → ir/runtime/parse/validate → interp/engine/wasi → cli/api); enforced by
  `scripts/zone_check.sh`. See [`.claude/rules/zone_deps.md`](../.claude/rules/zone_deps.md).
- **Contribution flow, license, review expectations**:
  [`.github/CONTRIBUTING.md`](../.github/CONTRIBUTING.md).
- **Using zwasm (not developing it)**: [`docs/tutorial.md`](tutorial.md).
