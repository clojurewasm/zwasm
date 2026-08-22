# 0214 — The lint step gets its own build file, so the package has no dependencies

- **Status**: Accepted (2026-08-22)
- **Date**: 2026-08-22
- **Author**: chaploud
- **Tags**: build, dependencies, packaging, lint
- **Supersedes**: the D-274 rationale recorded at `build.zig:7-14`

## Context

`build.zig` opened with a top-level `const zlinter = @import("zlinter");`.
Zig resolves that import while compiling the build file, before any step
runs, so **every** step needed the lint tool present — `static-lib`
included, which is the step C and Rust consumers build.

The cost lands on redistribution, which D-274 did not have in view.
`zwasm-rust-sdk` vendors this repository as a submodule and publishes it
inside the `zwasm-sys` crate, whose build script runs `zig build static-lib
-Dcompiler-rt=true -Doptimize=ReleaseSafe`. Measured on a clean clone
(2026-08-22, zig 0.16.0, empty package store, no network):

```
build.zig.zon:8:20: error: unable to discover remote git server capabilities: NameServerFailure
    .url = "git+https://github.com/kurtwagner/zlinter?ref=0.16.x#9b4d…",
```

With network it instead succeeds by fetching five packages — zlinter, zls,
diffz, known_folders, lsp_kit — to build a WebAssembly runtime. Offline CI,
sandboxed builders and `cargo vendor --offline` all fail on it, and the
fetch is a supply-chain surface the consumer did not opt into. Reported as
issue #235.

D-274 rejected the obvious fix and was right about both of its mechanisms.
Re-measured on zig 0.16.0 and the pinned zlinter, 2026-08-22:

- `.lazy = true` alone does not help. With the dependency unfetched, the
  comptime import fails outright: `build.zig:15:25: error: no module named
  'zlinter' available within module 'root.@build'`. `zig build --fetch=needed`
  fetches nothing, so the flag converts a slow build into a broken one.
- `builder()` is still unreachable without the import. `std.Build.Dependency`
  exposes `artifact`, `module`, `namedWriteFiles`, `namedLazyPath` and
  `path` — no way to call a dependency's build.zig functions. zlinter needs
  the import to reach itself, too: its `builder().build()` calls
  `b.dependencyFromBuildZig(@This(), .{})`.

What D-274 missed is that the import does not have to be in *this* build
file. Zig resolves a build file's manifest by the fixed name
`build.zig.zon` next to it — verified: `zig build --build-file lint.zig`
reads `build.zig.zon`, not `lint.zig.zon` — so a second dependency set needs
a second directory, and that is the whole of the change.

Dropping zlinter outright is not available: `@deprecated` is still an
invalid builtin on 0.16.0 (`error: invalid builtin function: '@deprecated'`),
and four of the five rules in the chain were never about deprecation anyway.

## Decision

**D1 — The rule chain moves to `tools/lint/`.** `tools/lint/build.zig` plus
`tools/lint/build.zig.zon` hold the zlinter dependency and the five-rule
chain. `build.zig.zon` at the root declares `.dependencies = .{}`: the
package a consumer builds now depends on nothing.

**D2 — `zig build lint` stays the entry point.** The root `lint` step is a
Run step that spawns `zig build --build-file tools/lint/build.zig lint` with
`stdio = .inherit`, so a non-zero exit fails the step and `ci_gate.sh`'s
extended leg still fails on a lint error. `b.args` is forwarded, keeping the
documented `zig build lint -- --max-warnings 0` form working.

Two mechanical constraints, both measured rather than assumed:

- The sub-build's cwd must be its own build root. zlinter spawns the linter
  binary by a path relative to the invoking cwd but sets the child's cwd to
  the build root; when those differ the spawn fails with
  `Unable to spawn zlinter: FileNotFound`.
- The tree to lint must be named explicitly. zlinter's include set defaults
  to the build root, which is now `tools/lint`, so the step passes the
  repository root as an absolute path. Lint diagnostics therefore print
  absolute file paths; that is the only user-visible difference.

**D3 — The CI dep cache follows the dependency.** `ci.yml` caches
`tools/lint/zig-pkg`, keyed on `tools/lint/build.zig.zon`. The cache steps in
`release.yml` and `bench_watch.yml` are deleted: those workflows resolve no
packages at all now, so the steps cached an empty directory. `ci_gate.sh`
gains `zig fmt --check tools/`, for the same reason `bench/latency/` is
already there — the new build file is otherwise compiled only by the
extended leg and its formatting would drift unchecked.

## Consequences

- `zig build static-lib -Dcompiler-rt=true -Doptimize=ReleaseSafe` succeeds
  with no network and an empty package store, fetching nothing. So does every
  other step except `lint`. Verified on a clean clone offline in a network
  namespace.
- The published `zwasm-sys` crate, `cargo vendor --offline`, sandboxed
  builders and offline CI stop depending on GitHub reachability, and the
  four transitive packages leave the consumer's supply chain.
- `zig build lint` covers exactly what it covered before, plus the new build
  file: the linter's own denominator went 1617 → 1618, matching the count of
  lintable `.zig` files on disk in each tree. A probe violation injected into
  `src/`, `test/` and `bench/` is reported identically by both, exit 1.
- `zig build lint` now needs the network on a cold package store, where
  before any `zig build` did. That is the intended trade.
- The zlinter sunset (ADR-0009, ziglang/zig#22822) is unaffected: the TODO
  moves to `tools/lint/build.zig`. When it fires, the directory is deleted
  and the root `lint` step goes with it.

## Revision history

| Date | SHA | Change |
|---|---|---|
| 2026-08-22 | `<backfill>` | Initial — split the lint build file (#235). |
