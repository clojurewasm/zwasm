# Edge-runner fixtures were cached → false coverage (cyc216)

**Date**: 2026-05-30 · **Citing**: `0b8d2a0b` · Phase 10 (10.P I3 cross fixtures)

The `test/edge_cases` + `test/realworld` fixture runners are wired in
`build.zig` as `addRunArtifact(edge_runner_exe)` with the corpus dir passed
via `addArg(b.pathFromRoot("…"))` — a plain STRING, NOT a tracked build
input. So zig caches the run-artifact step keyed on the exe hash + args:
**a fixture-only change (new `.wasm`/`.expect`, no src/exe delta) does not
invalidate the run step → it is skipped → the new fixtures never execute.**
The gate serves a stale "N passed" and the fixture is *false coverage* —
it passes when run directly but is silently never re-checked. This bit
cyc215's two cross fixtures (added test-only; the exe was unchanged from
cyc214's D-209 build, so the run step was cached on Mac AND ubuntu).

**Fix**: `run_edge_*.has_side_effects = true` on each fixture-runner step
(forces re-run every invocation; the runner is fast, ~seconds for the whole
corpus). Alternative: `addDirectoryArg(b.path(dir))` to track the dir as an
input (re-runs only on change) — not chosen here (recursive-hash semantics
less certain than "always run"; tests should always run anyway).

**Incompleteness caught cyc223**: the cyc216 fix only patched the `run_edge_*`
steps. The `test/realworld/wasm/` runners — `run_realworld`, `run_realworld_run`,
`run_realworld_run_jit`, `run_realworld_diff` (all in `test-all`) — have the
SAME `addArg(dir-string)` shape and were missed, leaving the 55-fixture realworld
corpus exposed to fixture-only false coverage. Fixed cyc223 (same
`has_side_effects = true`). Lesson: when fixing a class bug, grep ALL
`addRunArtifact` + `addArg(b.pathFromRoot(` sites, not just the one in front of you.

## Debugging gotchas (each cost real time this session)

- **Stale cached exes coexist** in `.zig-cache/o/<hash>/zwasm-edge-runner`.
  `find … | head -1` grabs an arbitrary (often STALE) one that predates a
  feature → spurious `UnsupportedOp` on call_ref/return_call. Pick the
  CURRENT exe: the one that passes a known-good recent fixture.
- **Parallel run steps interleave stdout** → the per-runner `N passed`
  summaries are easy to MISATTRIBUTE. Counts: p7≈68, p9≈40, p10=8 (4 cross +
  4), realworld=2. Count `.wasm`-with-`.expect` on disk to know the expected
  number before trusting a summary line.
- **NEVER `rm -rf .zig-cache/o`** — it deletes zig's own build-runner exe →
  `failed to spawn build runner … FileNotFound`, and zig won't regenerate it
  from the stale manifest. Recovery: `rm -rf .zig-cache` (the WHOLE dir) +
  clean `zig build`.
- **Verify a new fixture via a direct current-exe run**, not just the
  zig-build summary count.

## Related

- `.claude/rules/test_discipline.md` (fixtures-as-coverage). `build.zig`
  run_edge_* steps. cyc215 cross fixtures (`test/edge_cases/p10/cross/`).
