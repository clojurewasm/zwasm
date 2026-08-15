# Run-step fixture caching → false coverage (cyc216; diagnosis corrected 2026-08-15)

**Date**: 2026-05-30 · **Citing**: `0b8d2a0b` · Phase 10 (10.P I3 cross fixtures)

The false coverage cyc215 hit was real. **The mechanism recorded here was
wrong, and the fix it prescribed was a no-op.** Corrected below; the original
claim is kept struck so nobody re-derives it.

~~Passing the corpus dir as `addArg(b.pathFromRoot("…"))` — a plain STRING,
not a tracked input — is enough to make zig cache the run step, so a
fixture-only change is skipped. Fix: `has_side_effects = true`.~~

An untracked arg is **necessary but not sufficient**. Caching is gated on
`Run.hasSideEffects()`, which for the default `stdio = .infer_from_args`
returns `!hasAnyOutputArgs()` — **true**, i.e. always re-run, unless the step
captures stdout/stderr or produces an output file. A plain `addRunArtifact` +
`addArg` step has none of those, so it was never cacheable to begin with.
Fixture-only false coverage needs BOTH:

1. an input the build graph does not track (a corpus path as a plain string), **and**
2. something making `hasSideEffects()` false — an output arg, or any `addCheck`
   caller (`expectExitCode`, `expectStdOutEqual`), which flips `stdio` to
   `.check`

`run_edge_*` and `run_realworld*` met (1) but not (2), so the cyc216 and cyc223
`has_side_effects = true` lines changed nothing — as do the other 20 such sites
in build.zig. Measured 2026-08-15 against `main@057a3f7ea` (**the same zig
0.16.0 as today**): that build.zig had one `expectExitCode` in the whole file
and none on those steps. Zig did not change; the diagnosis was wrong when
written. cyc215's real cause is unidentified — the stale-exe gotcha below is
the likeliest candidate and was seen the same session.

**Where both conditions did hold**: `run_oob_trap` — the only behavioural test
of the production guard-page elision path (ADR-0202 D4/D5 / D-507), in
`test-all`, taking its `.wasm` as a plain string AND calling `expectExitCode(1)`.
Proven 2026-08-15: swapping the 47-byte trapping module for an 8-byte empty one
left the step `cached` and green. Fixed there, where it is not a no-op (D-592).

**Check, don't guess**: `zig build <step> --summary all` prints `cached` per
step. Confirm a fix by breaking the fixture and watching the step fail.

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
  `run_oob_trap` (the one real instance). cyc215 cross fixtures
  (`test/edge_cases/p10/cross/`). D-592 (the retraction + the 20 no-op sites).
