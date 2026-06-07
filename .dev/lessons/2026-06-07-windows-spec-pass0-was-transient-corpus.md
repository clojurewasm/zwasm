# windows spec-assert `pass=0` was a transient corpus state, masked by a silent skip

**Date**: 2026-06-07 · **Tags**: ADR-0174, windowsmini, spec-assert runner,
pass=0 anomaly, silent skip, missing corpus exit-0, OK-verdict masking,
corpus-presence guard, transient checkout, no-naive-skip, v1 lesson

## What

The ADR-0174 lead — windowsmini `test-all` `[run_remote_windows] OK` but
spec-assert `pass=0` across categories @87635409 — did **NOT reproduce** on a
fresh `test-all` @f8bcc040: windows showed **real pass counts identical to
ubuntu** (simd 13420, non_simd 25437+294, wasm-1.0 212, wast 1158+72), identical
SKIP histogram, zero `SKIP-START-TRAP`. @87635409→@f8bcc040 is **doc-only**, so
the `pass=0` was a **transient windowsmini corpus state** (an incomplete /
unreadable committed corpus at that moment), restored by the job's
`git fetch + reset --hard`. The `assert_invalid pass=0/fail=194` in the lead
could NOT have come from the OK run (a runner `exit(1)`s on `failed>0`, which
would break `OK`) — it was a separate/partial observation.

## Why it was invisible (the real defect)

`simd` / `non_simd` / `wasm_3_0` runners, on `openDir(corpus_root)` failure,
printed `... 0 manifests` and **`return` (exit 0)** — a silent skip. So a
missing/unreadable corpus → `pass=0` while `test-all` stayed GREEN. Only the
wasm-1.0 runner already `exit(1)`'d. The silent path is exactly the v1 "windows
naively skips" anti-pattern: a green verdict that hid a non-run phase.

## Fix

The 3 runners now `exit(1)` on a missing corpus root (parity with wasm-1.0).
build.zig `test-corpus-presence` (3 negative runs, `expectExitCode(1)`) is wired
into `test-all`, so a runner that silently skips its committed corpus turns the
build RED on **every** host incl. windowsmini.

## Rules

1. A "pass=0 while OK" signature ⇒ suspect a **skipped/non-run phase masked by a
   verdict keyed off a DIFFERENT phase** (here: realworld MATCH), not a code
   miscompile. Cf. `fixture-self-verify-false-lead` (OK hides a FAIL line).
2. A runner that can't find a **committed** corpus MUST fail loud, never
   exit-0 with "0 manifests" — the bootstrap-era "exits clean" rationale dies
   once the corpus is committed.
3. Cross-host count parity (windows == ubuntu, exact) is the real green; a
   MATCH-only `OK` is not. Verify real pass counts, not the wrapper verdict.
4. An anomaly that vanishes across a doc-only diff ⇒ environmental/transient,
   not code — but still close the masking hole so it can't hide next time.
