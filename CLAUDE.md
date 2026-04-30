# zwasm v2

A from-scratch WebAssembly runtime in Zig 0.16.0.

> Project memory loaded by Claude Code on every session. Keep it short.
> Detailed plans live in `.dev/ROADMAP.md`. Skills hold runnable procedures.

## Identity / Context (read first)

**Project name (in all docs and the published artifact): `zwasm`.**
Binary name: `zwasm`. Package name: `zwasm`.

Working directory + branch are intentionally named with `from_scratch`
because **this branch is a ground-up redesign of zwasm on top of the
v1 git history (commit 517cc5a, charter)**:

- **Working directory**: `~/Documents/MyProducts/zwasm_from_scratch/`
  — distinct from the existing `~/Documents/MyProducts/zwasm/` v1
  reference clone.
- **Branch**: `zwasm-from-scratch` — long-lived, branched from the v1
  charter commit. All work happens here. **Never push to `main`**;
  push to `zwasm-from-scratch` only with explicit user approval.
- **Compatibility with v1 is explicitly out of scope.** The v0.1.0
  release breaks the v1 ABI; `docs/migration_v1_to_v2.md` ships at
  release time.

### Read-only reference clones (read, do not edit, do not commit from)

| Path                                             | What it is                                                            |
|--------------------------------------------------|-----------------------------------------------------------------------|
| `~/Documents/MyProducts/zwasm/`                  | zwasm v1 (current main, ClojureWasm consumer) — **read, never copy** |
| `~/Documents/MyProducts/ClojureWasmFromScratch/` | CW v2 — procedural template that this project mirrors                |
| `~/Documents/OSS/wasmtime/`                      | wasmtime + cranelift (winch / regalloc2 reference)                    |
| `~/Documents/OSS/zware/`                         | Zig idiomatic interpreter                                             |
| `~/Documents/OSS/wasm3/`                         | wasm3 (M3 IR + tail-call dispatch interpreter)                        |
| `~/Documents/OSS/wasmer/`                        | wasmer (singlepass / multi-backend)                                   |
| `~/Documents/OSS/wazero/`                        | wazero (Go, dual-engine)                                              |
| `~/Documents/OSS/wasm-c-api/`                    | wasm-c-api standard ABI                                               |
| `~/Documents/OSS/regalloc2/`                     | cranelift register allocator                                          |
| `~/Documents/OSS/wasm-tools/`                    | `wasm-tools smith` (fuzz corpus), `validate`, …                      |
| `~/Documents/OSS/sightglass/`                    | Bytecode Alliance bench suite                                         |
| `~/Documents/OSS/wasm-micro-runtime/`            | WAMR (lightweight runtime reference)                                  |
| `~/Documents/OSS/cap-std/`                       | Capability-based std for Rust                                         |
| `~/Documents/OSS/wit-bindgen/`                   | Component Model bindgen (post-v0.1.0 reference)                       |
| `~/Documents/OSS/WasmEdge/`                      | WasmEdge (cloud-native runtime; AOT strategy reference)               |
| `~/Documents/OSS/wasi-rs/`                       | Rust WASI binding (host idiom + C ABI consumer reference)             |
| `~/Documents/OSS/dynasm-rs/`                     | DynASM (Rust port; copy-and-patch reference, post-v0.1.0)             |
| `~/Documents/OSS/poop/`                          | Andrew Kelley's perf-bench tool (Zig)                                 |
| `~/Documents/OSS/hyperfine/`                     | Hyperfine source (bench tool used in `bench/`)                        |
| `~/Documents/OSS/extism/`                        | Extism (multi-language Wasm host SDK reference)                       |
| `~/Documents/OSS/WebAssembly/spec/`              | reference interpreter (OCaml) + spec text                             |
| `~/Documents/OSS/WebAssembly/testsuite/`         | spec testsuite                                                        |
| `~/Documents/OSS/WebAssembly/<proposal>/`        | per-proposal spec + tests (multi-value, simd, gc, eh, etc.)           |
| `~/Documents/OSS/zig/`                           | Zig 0.16 stdlib source                                                |

The full investigation that motivated this project lives at
`~/zwasm/private/v2-investigation/` (CONCLUSION.md + surveys + drafts +
notes). Treat it as the v2 design rationale; ROADMAP.md is the
operational plan that descended from it.

## Language policy

Public project. **English by default** for code, comments, identifiers,
commit messages, README, ROADMAP, ADRs, `.dev/`, `.claude/`, all
configuration. **Japanese** for chat replies only.

zwasm v2 does **not** maintain `docs/ja/learn_zwasm/` chapters. The
ClojureWasm v2 two-cadence learning material discipline is
intentionally dropped (P9). Knowledge compression for v2 lives in
ROADMAP narrative + ADRs (`.dev/decisions/`, written for ROADMAP
deviations only — see ROADMAP §18).

The chat-reply-in-Japanese rule is enforced by the project output
style [`.claude/output_styles/japanese.md`](.claude/output_styles/japanese.md)
plus a SessionStart hook that re-injects the directive on every
session.

## Working agreement

- TDD: red → green → refactor.
- **Step 0 (Survey) before each task**: an Explore subagent surveys
  the reference codebases (zwasm v1, wasmtime, zware, wasm3,
  wasm-c-api, Zig stdlib, regalloc2 when JIT-relevant) and lands a
  200–400 line note in `private/notes/<phase>-<task>-survey.md`.
  See `.claude/rules/textbook_survey.md` for guardrails (cite ROADMAP
  principles before adopting an idiom; always note one DIVERGENCE;
  copy-paste from v1 is forbidden).
- **No copy-paste from v1** — `.claude/rules/no_copy_from_v1.md` is
  load-bearing. Read v1; re-derive in v2.
- **Test gate is three-host native**: `zig build test` (and
  `test-spec` / `test-e2e` / etc. as phases land) must be green on
  Mac aarch64 (host) AND OrbStack Ubuntu x86_64 AND `windowsmini`
  SSH before every commit.
  Linux: `orb run -m my-ubuntu-amd64 bash -c '... zig build ...'`.
  Windows: `ssh windowsmini "cd zwasm_from_scratch && zig build ..."`.
  Setup: [`.dev/orbstack_setup.md`](.dev/orbstack_setup.md) and
  [`.dev/windows_ssh_setup.md`](.dev/windows_ssh_setup.md). Do not
  bypass hooks.
- Commit at the natural granularity of code changes. `private/notes/`
  task notes are optional scratch — write them only if useful for
  resume continuity.
- Subagent fork is the default for: Step 0 surveys, large test logs
  (>200 lines), cross-codebase searches (>5 files), occasional
  audit / simplify / security-review fan-out. Stay in main only for
  small in-context edits.
- Pushing to `zwasm-from-scratch` requires explicit user approval.
- ROADMAP corrections follow the four-step amendment in
  [`ROADMAP §18`](.dev/ROADMAP.md#18-amendment-policy): edit in
  place as if it had always been so, open an ADR, sync `handover.md`,
  reference the ADR in the commit. Quiet edits are forbidden.
- `private/` is gitignored agent scratch. It is **not authoritative**
  — the audit and resume procedures do not read it as load-bearing.
  If a `private/` proposal matters, promote it to ROADMAP / ADR /
  `handover.md` (all tracked in git); otherwise let it stay scratch.

## Skills (the runnable procedures)

These hold the canonical procedures; CLAUDE.md only points to them.

- **`continue`** — resume procedure + per-task TDD loop (Step 0
  Survey, Step 5 three-host test gate, Step 7 handover update + 60 %
  compact gate). Auto-triggers on "続けて" / "/continue" / "resume".
  **Fully autonomous from invocation**. Stops only when the user
  intervenes or a problem genuinely cannot be solved.
- **`audit_scaffolding`** — adaptive-cadence audit for staleness,
  bloat, lies, and false positives across the tracked scaffolding
  (CLAUDE.md, `.dev/`, `.claude/`, `scripts/`). Invoked when
  scaffolding feels off, after large refactors, before release tags,
  or on user request.

## Layout

```
src/         Zig source (frontend / ir / runtime / feature / interp / jit / wasi / c_api / cli / app / util / platform)
include/     Public C headers (wasm.h / wasi.h / zwasm.h)
build.zig    Build script (Zig 0.16 idiom, with -Dwasm / -Dwasi / -Dengine flags)
flake.nix    Nix dev shell pinned to Zig 0.16.0 + hyperfine + yq + wabt
.dev/        ROADMAP + handover + ADRs + proposal_watch + orbstack_setup + windows_ssh_setup
.claude/     settings, skills, rules, output_styles
scripts/     gate, zone_check, file_size_check, bench, run_remote_windows
test/        unified runner via `zig build test-all` + per-layer suites (unit / spec / e2e / realworld / c_api / fuzz)
bench/       benchmark history (append-only)
private/     gitignored agent scratch
```

## Build & test

```sh
zig build               # compile
zig build test          # unit tests (Phase 0+)
zig build test-spec     # spec testsuite (Phase 1+)
zig build test-all      # all enabled test layers (Phase 0+, expands per phase)
zig fmt src/            # format
```

Three-host invocation pattern:

```sh
# Mac native (default)
zig build test-all

# OrbStack Ubuntu x86_64
orb run -m my-ubuntu-amd64 bash -c '
  cd /Users/shota.508/Documents/MyProducts/zwasm_from_scratch &&
  zig build test-all
'

# Windows x86_64 via SSH
ssh windowsmini "cd zwasm_from_scratch && zig build test-all"
```

## References

- [`.dev/ROADMAP.md`](.dev/ROADMAP.md) — authoritative mission,
  principles, phase plan. **Single source of truth**; if anything
  in this file conflicts with the roadmap, the roadmap wins.
- [`.dev/handover.md`](.dev/handover.md) — short, mutable, current
  state.
- [`.dev/decisions/`](.dev/decisions/) — ADRs (load-bearing
  deviations from ROADMAP).
- [`.dev/proposal_watch.md`](.dev/proposal_watch.md) — Wasm proposal
  phase tracking, reviewed quarterly.
- [`.dev/orbstack_setup.md`](.dev/orbstack_setup.md) — OrbStack VM
  for Linux x86_64 testing.
- [`.dev/windows_ssh_setup.md`](.dev/windows_ssh_setup.md) — `windowsmini`
  SSH host for Windows x86_64 testing.

## Mandatory pre-commit checks

All of:
1. `zig build test` — 0 fail / 0 leak (Mac native)
2. `bash scripts/zone_check.sh --gate` — 0 violation
3. `bash scripts/file_size_check.sh --gate` — within ≤ 2000 line
   hard cap
4. As phases add layers, `zig build test-all` runs them too

OrbStack Ubuntu x86_64 must also pass before push:
- `orb run -m my-ubuntu-amd64 bash -c '... zig build test-all'`

`windowsmini` SSH must also pass before push:
- `ssh windowsmini "cd zwasm_from_scratch && zig build test-all"`
