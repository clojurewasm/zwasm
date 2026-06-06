# Fixture self-verify `FAIL` ≠ runtime bug — check ground truth first

**Date**: 2026-06-06 · **Tags**: realworld fixture, self-verify, golden-match,
false lead, sha256, c_sha256_hash, D-279, heisenbug misattribution, ground-truth
check, interp==jit, golden blesses output

## What happened

The D-279 Win64 heisenbug investigation carried a "non-deterministic sha256 wrong
hash" lead for multiple sessions: `c_sha256_hash.wasm` printed
`verify: FAIL (expected 3d61375c…, got d0e8b8f…)` in the windows test-all log,
read as a JIT miscompute (and "PASSED in one runner, FAILED in another" → a
heisenbug hallmark).

A 5-minute Mac experiment disproved it:
`printf 'Hello, SHA-256!' | shasum -a 256` = `d0e8b8f1…` — **the value zwasm
computes is CORRECT**, identically on interp AND jit, all 3 hosts. The fixture's
hardcoded *expected* constant `3d61375c…` is simply WRONG (matches no variant of
the input). zwasm was never buggy here.

## Why it fooled the investigation

- The fixture **self-verifies** against its own bad constant and prints
  `verify: FAIL`, but **exits 0** → exit-code-only runners pass it.
- `realworld_runner` is **golden-match**, and the golden was captured FROM zwasm's
  (deterministic, correct) output — which includes the `verify: FAIL` line. So it
  passes 55/55 *while displaying a FAIL string*. The golden blessed the fixture's
  own complaint.
- "PASSED one runner / FAILED another" was **interp-correct vs the fixture's
  self-verify**, not one engine varying.

## Rules

1. A fixture printing `FAIL`/`verify:`/`mismatch` is the FIXTURE's claim, not the
   runner's verdict. Before blaming the runtime, **compute the expected value
   independently** (`shasum`, a reference impl) and compare to what the runtime
   produced — don't compare runtime-output to the fixture's baked-in constant.
2. `interp == jit` on a "wrong" result is a strong signal the FIXTURE/expectation
   is wrong, not the runtime (two independent impls rarely share an arithmetic bug
   that also happens to equal the reference value).
3. A golden-match runner reporting PASS while the output contains `FAIL` means the
   golden encodes the output, not correctness — never read a `FAIL` *inside* a
   passing fixture as a gating signal.
4. Heisenbug streak hygiene: a gate-green run with scary log lines is `silent`
   unless a GATING runner actually went RED. Don't record `fail` off log-grep
   alone (this mis-recorded ba111ee5 fail→silent; corrected to streak 3).
