# windowsmini hardening campaign — findings (ADR-0174 Phase I)

> **Doc-state**: ACTIVE
> Investigation log for the `spec-assert pass=0` anomaly. Correctness-first:
> confirm the mechanism on real windows data before any fix. Updated per cycle.

## Goal

windowsmini `test-all` fully green with **real pass counts matching ubuntu**,
not a realworld-MATCH-only `OK`. Then (ADR-0174 phase 2) `--suspend` gating.

## Baseline — ubuntunote x86_64 @f8bcc040 (the truth windows must match)

| runner | corpus | passed | failed | skipped |
|---|---|---|---|---|
| `spec_assert_runner` | wasm-1.0-assert | 212 | 0 | 20 (skip-adr) |
| `spec_assert_runner_non_simd` | wasm-2.0-assert (84 man.) | 25437 | 0 | 489 (20 rt + 469 adr) |
| `spec_assert_runner_non_simd` | threads-assert (1 man.) | 294 | 0 | 0 |
| `simd_assert_runner` | wasm-2.0-simd (33 man.) | 13420 | 0 | 390 (skip-adr) |
| `wast_runner` (2.0/runtime) | — | 1158 + 72 | 0 | — |

ubuntu SKIP-token histogram (spec-gap only, host-independent by design):
`SKIP-VALIDATOR-GAP ×10`, `SKIP-PARSER-GAP ×10`, `SKIP-EMPTY ×5`, `SKIP-WASI ×1`,
`SKIP-IMPORTS ×1`. **`SKIP-START-TRAP ×0`.**

## Masking-mechanism map (how an OK verdict can hide pass=0)

The `[run_remote_windows] OK` verdict = `zig build test-all` exit 0. So any
spec-assert anomaly that coexists with `OK` must NOT make a runner `exit(1)`:

1. **Missing-corpus silent pass** — `simd`/`non_simd`/`wasm_3_0` runners, on
   `openDir(corpus_root)` failure, print `... 0 manifests` and **`return` (exit
   0)** (non_simd L100-103, simd L78-85, wasm_3_0 L396-399). Only the wasm-1.0
   `spec_assert_runner` `exit(1)`s on missing corpus (L57-60). → latent
   silent-fallback (a runner that can't find its corpus should FAIL).
   **RULED OUT as the cause**: windows checkout @f8bcc040 HAS all corpora
   present (manifest dirs: 1.0=11, 2.0=84, simd=33, 3.0=6, threads=1) — same as
   home. So `openDir` succeeds; runners DO iterate.

2. **Whole-module skip via false-positive trap** (PRIME HYPOTHESIS) — on
   windows the runner routes JIT execution through
   `windows_traphandler.callJitOrTrap` (non_simd L376, L1675, L1929). It arms
   VEH and returns `true` on any hardware fault in the JIT region OR
   `error.Trap`. During start-init a `true` → `SKIP-START-TRAP` →
   `return error.SkipModule` (L403-415) = the WHOLE module is skipped (not
   counted as fail, so no `exit(1)`). If VEH mis-fires on windows (or the JIT
   region bounds are wrong), modules mass-skip → pass count collapses while
   `test-all` stays green. ubuntu's sig-based path skips 0 modules → asymmetry.

3. `fail=194` in the @87635409 lead is logically incompatible with `exit(1)`
   gating + `OK` — likely a SEPARATE manual assert-runner invocation (different
   corpus arg) conflated into the handover/ADR note, OR the count came from a
   pre-exit partial. Treat the empirical test-all output as the only anchor.

## Pending — empirical windows test-all summary (@f8bcc040, in-flight)

Need the actual `spec_assert_runner*` summary lines + any `SKIP-START-TRAP` /
`[d-279-veh]` count from /tmp/win.log to confirm which mechanism fires. Until
then: hypothesis #2, evidence pending.

## Fix candidates (apply only after mechanism confirmed)

- If #1 (missing-corpus mask): make the 3 runners `exit(1)` on openDir failure
  (parity with wasm-1.0 runner) — removes the silent-pass even if not the
  current cause (no_workaround: a runner that finds 0 manifests where the corpus
  is committed must FAIL, not pass).
- If #2 (VEH whole-module skip): root-cause `callJitOrTrap` false-positive on
  windows (JIT-region bounds? VEH ordering? start-init path); make a genuine
  start-trap distinguishable from a VEH artifact, and never `SKIP-START-TRAP` a
  module the linux path runs cleanly.
