# Hard-coded test-corpus inclusion list silently bounds coverage

**Date**: 2026-06-16
**Context**: D-457 systemic audit (SIMD float↔int conversions)

## Observation

`scripts/regen_spec_simd_assert.sh` baked only **33 of the 59** upstream
`simd_*.wast` files into the simd_assert corpus via a hand-maintained `NAMES`
bash array. The 26 omitted files were never JIT-executed, so entire op families
shipped with multi-layer dispatch gaps **undetected**: float demote/promote,
f32x4/f64x2 rounding (ceil/floor/trunc/nearest), saturating narrow, and
i64x2.extmul. Each gap was the same D-457 pattern — per-arch emit handlers
complete on both arches, only validate-arity + lower + emit-dispatch wiring
missing. Adding all 59 surfaced 6 failures in one run; fixing them added ~688
passing assertions (24117→24805) and corrected the overstated "100% SIMD spec"
claim.

The convert-op bug (D-457) was the tip: it was found by an *external* corpus
(wasmtime int-to-float-splat, ADR-0192), not by our own SIMD suite, precisely
because `simd_conversions.wast` was not in `NAMES`.

## Rule

A test corpus whose membership is a hand-curated inclusion list (allowlist of
filenames) bounds coverage to whatever someone remembered to add — silently. For
a spec-conformance corpus, default to **including the entire upstream set** and
let the runner record per-fixture skips (unsupported shape / deferred feature)
*transparently*, rather than pre-filtering at the corpus-generation step. The
skip is visible and auditable; an omission is not. When auditing for hidden
gaps, diff the corpus inclusion list against the full upstream directory
(`comm -23 <(ls upstream) <(ls corpus)`) — the omissions are the blind spots.

## See also

- [[validator-exact-eql-where-reftype-subtyping-required]] — synthetic suites
  under-cover; a real/full corpus is the forcing function (same campaign theme).
- D-457 debt row; ADR-0192 (wasmtime differential campaign).
