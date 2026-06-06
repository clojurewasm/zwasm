# ADR-0169 — relaxed-SIMD determinism: per-arch hardware semantics, not forced cross-arch uniformity

**Status**: Accepted (loop, autonomous per ADR-0168 §17.4)
**Deciders**: loop
**Touches**: ROADMAP §9.12-E exit (the SIMD `bit-identical Mac+ubuntu` clause — scopes
it to STRICT ops), `.dev/proposal_watch.md` (relaxed-SIMD impl note). Filed before the
relaxed_min/max JIT chunk (the first relaxed op whose hardware result genuinely diverges
cross-arch). 17.4 chunks 1-3 (front-end / swizzle / trunc) needed no carve-out — their
deterministic choices (OOB→0, NaN/OOB→sat-clamp) are bit-identical on both arches.

## Context

The relaxed-SIMD proposal (Phase-5 / W3C-Rec, folded into Wasm 3.0) defines a set of ops
whose results on certain inputs are **implementation-defined** — each runtime picks the
fast hardware instruction and accepts the per-ISA result. The spec testsuite encodes this
with `(either A B)` assertions (a lane may legally be A *or* B).

zwasm's strict-op gate (§9.12-E) requires the SIMD spec runner to be **bit-identical
between Mac aarch64 and ubuntu x86_64**. For relaxed-SIMD this collides head-on with the
proposal's intent on the impl-defined inputs:

- **relaxed_min/max**: arm64 NEON FMIN/FMAX propagate NaN and give -0<+0; x86 MINPS/MAXPS
  return the *second* operand on NaN/equal (incl. ±0). They differ on NaN and ±0.
- **relaxed_madd/nmadd**: FMA (1 rounding) vs unfused (2 roundings) differ on the
  round-trip edge (FLT_MAX×2−FLT_MAX).
- **relaxed_laneselect / dot / q15mulr**: similar per-ISA latitude.

Forcing cross-arch bit-identity would require emulating one ISA on the other (e.g. the
strict-min multi-instr NaN/±0 fixup recipe for relaxed_min) — which makes the relaxed op
*identical to its strict sibling* and discards the entire speed rationale of the proposal.

## Decision

1. **relaxed-SIMD ops emit the fast native hardware instruction per arch.** zwasm pins a
   *named deterministic choice per op* (see proposal_watch / 17.4 bundle): madd=**always
   FMA**, swizzle OOB→**0**, trunc NaN/OOB→**saturating clamp**, laneselect=**full
   bitselect**, min/max=**raw hardware FMIN/FMAX // MINPS/MAXPS**, q15mulr overflow→
   **INT16_MAX**, dot b=**signed i8**. Where the hardware already agrees cross-arch (swizzle,
   trunc, laneselect, q15mulr, dot), the choice is bit-identical. Where it does not
   (min/max NaN&±0, madd is FMA-uniform so it *does* agree), the per-arch hardware result
   stands.

2. **Determinism guarantee = per-host reproducibility, NOT cross-arch bit-identity, for
   relaxed ops.** Same module + inputs on the same host always yield the same bytes (no UB,
   no nondeterminism). This is the determinism zwasm actually promises; cross-arch
   bit-identity is a *strict-op* property (§9.12-E) and does not extend to relaxed ops'
   impl-defined inputs — exactly as the proposal's `(either)` assertions codify.

3. **§9.12-E bit-identical clause is scoped to strict SIMD-128.** The relaxed-SIMD spec
   corpus (when wired) is asserted with `(either)`-aware comparison, per-host, NOT
   bit-compared across hosts.

4. **Edge fixtures (`test/edge_cases/p17/relaxed_simd/`) use inputs in the agreeing
   region** (distinct finite non-±0 operands) so a single committed `.expect` is valid on
   all three hosts. The impl-defined inputs (NaN, ±0, FMA round-trip) are exercised by the
   `(either)` spec corpus, not by single-value `.expect` fixtures.

## Rejected alternatives

- **Force cross-arch uniformity** via strict-style fixups on the lagging ISA — rejected:
  collapses relaxed→strict, defeats the proposal, adds 5-9 instrs/op for zero spec benefit.
- **Software-emulate one canonical semantics in a shared helper** — same defect as above,
  plus a Zone-0 SIMD softfloat path that no other op needs.

## Consequences

- relaxed_min/max etc. are single-instruction (or near) on both arches — the speed win the
  proposal exists for.
- A future reader seeing `relaxed_min` x86 ≠ arm64 on a NaN input finds the rationale here.
- The spec-corpus wiring (later 17.4 chunk) must teach the SIMD runner `(either)` handling
  rather than extend the bit-identical compare.
