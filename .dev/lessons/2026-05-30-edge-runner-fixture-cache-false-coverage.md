# Run-step fixture caching → false coverage (cyc216; diagnosis corrected 2026-08-15)

**Date**: 2026-05-30 · **Citing**: `0b8d2a0b` · Phase 10 (10.P I3 cross fixtures)

The false coverage cyc215 hit was real, but **the mechanism recorded here was
wrong and the fix it prescribed a no-op**. Original claim kept struck:

~~Passing the corpus dir as `addArg(b.pathFromRoot("…"))` — a plain STRING,
not a tracked input — is enough to make zig cache the run step, so a
fixture-only change is skipped. Fix: `has_side_effects = true`.~~

An untracked arg is **necessary but not sufficient**. False coverage needs
BOTH (1) an untracked input and (2) something making `Run.hasSideEffects()`
false — an output arg, or an `addCheck` caller (`expectExitCode`,
`expectStdOutEqual`) flipping `stdio` to `.check`. Without (2) the default
`.infer_from_args` is already side-effecting. D-592 has the line references.

`run_edge_*` and `run_realworld*` met (1) but not (2), so cyc216's and cyc223's
`has_side_effects = true` changed nothing — as do the other 19 such sites.
`main@057a3f7ea` ran **the same zig 0.16.0** with one `expectExitCode` in the
whole file, none on those steps: zig did not change, the diagnosis was wrong
when written. cyc215's real cause is unidentified — the stale-exe gotcha below
is the likeliest candidate and was seen the same session.

**Where both conditions did hold**: `run_oob_trap`, ADR-0202 D4/D5's only
behavioural test, in `test-all`. Swapping its 47-byte trapping module for an
8-byte empty one left it `cached` and green. Fixed there (D-592).
**Check, don't guess**: `zig build <step> --summary all` prints `cached` per
step; confirm a fix by breaking the fixture and watching the step fail.

## Debugging gotchas (each cost real time this session)

- **Stale cached exes coexist** in `.zig-cache/o/<hash>/zwasm-edge-runner`.
  `find … | head -1` grabs an arbitrary (often STALE) one that predates a
  feature → spurious `UnsupportedOp` on call_ref/return_call. Pick the
  CURRENT exe: the one that passes a known-good recent fixture.
- **Parallel run steps interleave stdout** → the per-runner `N passed`
  summaries are easy to MISATTRIBUTE. Count `.wasm`-with-`.expect` on disk
  instead. (The per-corpus counts once recorded here had all rotted by
  2026-08-15; don't re-add them.)
- **NEVER `rm -rf .zig-cache/o`** — it deletes zig's own build-runner exe →
  `failed to spawn build runner … FileNotFound`, and zig won't regenerate it
  from the stale manifest. Recovery: whole-dir `rm -rf .zig-cache` + rebuild.
- **Verify a new fixture via a direct current-exe run**, not the summary count.

## Related

- `.claude/rules/test_discipline.md`; `build.zig` `run_oob_trap`; cyc215 cross
  fixtures (`test/edge_cases/p10/cross/`); D-592 (retraction + the 19 no-ops).
