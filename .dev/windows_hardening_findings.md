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

## RESULT — windows test-all @f8bcc040 (the anchor): anomaly does NOT reproduce

Fresh windowsmini `test-all` @f8bcc040 (45147 log lines) shows **real pass
counts IDENTICAL to ubuntu**, `OK`:

| runner | windows | ubuntu |
|---|---|---|
| `simd_assert_runner` | 13420 / 0 / 390 | 13420 / 0 / 390 ✓ |
| `non_simd` (wasm-2.0) | 25437 / 0 / 489 | 25437 / 0 / 489 ✓ |
| `non_simd` (threads) | 294 / 0 / 0 | 294 / 0 / 0 ✓ |
| `spec_assert_runner` (1.0) | 212 / 0 / 20 | 212 / 0 / 20 ✓ |
| `wast_runner` | 1158 + 72 | 1158 + 72 ✓ |

windows SKIP histogram == ubuntu (validator-gap ×10, parser-gap ×10, empty ×5,
wasi ×1, imports ×1); **`SKIP-START-TRAP` ×0**. Hypothesis #2 (VEH
whole-module skip) **RULED OUT** — windows executes every module cleanly.

## Root cause (confirmed by elimination)

`@87635409 → @f8bcc040` is **doc-only** (no code change), yet windows is now
fully green with real counts. So the @87635409 `pass=0` was a **transient
windowsmini corpus state** (an incomplete / unreadable spec corpus at that
moment — interrupted checkout, Defender quarantine mid-run, or a partial sync),
not a code defect. This run's start-of-job `git fetch + reset --hard` restored
the full committed corpus → real counts. The `pass=0`-while-`OK` SIGNATURE is
exactly what the **silent "0 manifests" exit-0** masking path produces (the
`assert_invalid pass=0/fail=194` in the lead was a SEPARATE/partial observation
— `fail>0` would `exit(1)` and break `OK`, so it cannot have come from the same
OK run). The durable defense is to **delete that masking path** so any future
missing-corpus state is RED, not green-masked.

## Fix LANDED — corpus-presence guard (no silent skip)

`simd` / `non_simd` / `wasm_3_0` runners now `exit(1)` on a missing corpus root
(parity with the wasm-1.0 runner), replacing the silent `return` (0 manifests,
exit 0). build.zig `test-corpus-presence` step (3 negative runs, `expectExitCode(1)`)
wired into `test-all` pins this on EVERY host incl. windowsmini — a runner that
silently skips its committed corpus now turns the build RED. This is the
v1-lesson "windows must not naively skip" made enforceable.

## Campaign status — COMPLETE @9d832f1d

- Investigation (Phase I): **DONE** — anomaly = transient corpus state, masking
  path identified + removed.
- Guard **green 3-host @9d832f1d**: Mac (test-all) + ubuntu (`OK HEAD=9d832f1d`,
  real counts) + windows (`OK`, real counts == ubuntu: simd 13420, non_simd
  25437+294, 1.0 212). The 3 `expectExitCode(1)` neg-runs are test-all deps and
  test-all is `OK` on all hosts ⇒ a missing committed corpus now turns the build
  RED everywhere (proven on windows, the target host).
- ADR-0174 phase 2 **DONE**: `should_gate_windows.sh --suspend` →
  `.dev/windows_gate_suspended` = `9d832f1d`; inner loop is 2-host (Mac+ubuntu).
  `--resume` before any `main` merge / Win64-risk diff. Bundle win-harden-I
  CLOSED.
