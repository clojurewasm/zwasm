# An invariant's failure path needs its own tests — or the tests certify the defect

**Date**: 2026-07-09
**Keywords**: ADR-0203 D5, cache silent-miss discipline, failure-path testing, unit test asserts defective behavior, DA critique reproduced corrupt-entry brick, happy-path bias, EXEMPT-FALLBACK comment contradicted module doc, self-heal, degrade-not-fail
**Citing**: 4a17ceda7

## What happened

Stage-5 shipped the `--cache` happy path complete (atomic store, hit==miss
byte-identity, 2.2x measured) with the ADR-0203 D5 invariant "the cache can
never make `run` fail" stated in the module doc. The independent DA critique
then reproduced FOUR ways a cache defect failed the run (three corrupt-entry
shapes, `ZWASM_DEBUG` produce-refusal) plus an `--engine interp` override —
and found the unit test ASSERTING the defective behavior (corrupt entry
returned as a hit, expected to fail downstream) as if it were the contract.

## Root cause

D5's silent-miss discipline was implemented only where an error VISIBLY
crossed the cache layer (read failure → `catch` → miss). The invariant's
other half — an entry that reads fine but is garbage, a compile refusal
inside the cache path — had no failing test, so the implementation drifted
into "content is opaque to the cache layer" and a same-file comment that
directly contradicted the module doc. Tests written by the implementer
mirrored the implementation, not the invariant.

## Fix (or path forward)

Enumerate an invariant's failure modes and write one test per mode BEFORE
implementing (the TDD red step applies to failure paths too). Fixed in
4a17ceda7: header-gate + self-heal at lookup, compile-refusal = bypass,
interp bypass — each with a unit/E2E test that would have been red.

## Why this didn't surface earlier

`zig build test` green measured only the asserted behavior; the assertion
itself encoded the bug. Only an adversarial reviewer re-reading the ADR
clause-by-clause against E2E probes caught it.

## Re-derivability

Not re-derivable from code alone — post-fix code looks like the invariant
was always implemented; the drift mechanism (tests mirroring implementation)
is the observational content.

## Related

- ADR-0203 D5; `.devils-advocate/logs/check-9-critique-2026-07-09.md`
