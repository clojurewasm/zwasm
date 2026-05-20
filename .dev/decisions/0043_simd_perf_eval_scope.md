# ADR-0043: §9.10 + Phase 15 SIMD perf evaluation scope

> Status: Accepted
> Date: 2026-05-09
> Citing: this session's user-facing v1/v2 SIMD-perf comparison;
> lesson `2026-05-09-v1-monolith-file-survey-miss.md`.

## Context

§9.10's text reads simply: "SIMD smoke benches against wasmtime
+ wazero + wasmer; recorded to `bench/results/history.yaml`".
Phase 15's text reads: "Performance parity with v1 + ClojureWasm
migration", with the W43/W44/W45 v1 SIMD optimisations enumerated
as port targets.

A user-driven discussion on 2026-05-09 surfaced two gaps in this
framing:

1. **§9.10 produces numbers but no analysis discipline.** The
   row says "smoke benches recorded" — it doesn't require the
   data to be analysed per-op against the reference runtimes.
   Without per-op gap profiling, the bench output is noise that
   informs nothing.
2. **Phase 15's SIMD optimisation scope is closed at "v1
   ports".** It enumerates W43/W44/W45 explicitly. It does NOT
   account for optimisation candidates surfaced by §9.10's
   actual gap data — e.g. AVX path adoption (the SSE4.1 baseline
   per ADR-0041 §5 means we emit `MOVAPS dst, lhs` before every
   binop because the 2-operand form is destructive; AVX's
   3-operand VPADD* form would elide this entirely on hosts that
   support it).

v1 reached "adequate for embedded" but explicitly accepted a
~43× gap to wasmtime (per `~/Documents/MyProducts/zwasm/.dev/
decisions.md: D122`). v2 inherits this gap as the starting
point. Without §9.10 producing actionable per-op data and Phase
15 having an open enough scope to absorb it, v2 risks shipping
with the same "adequate but slow" stance — the structural
improvements over v1 (no parallel cache, day-1 JIT) wouldn't
translate into measured wins because the optimisation phase
isn't looking for them.

## Decision

Refine the Phase 11 SIMD-perf-evaluation task and the Phase 15
SIMD-perf scope as follows.

**Phase 11 amendment** (this ADR; per 2026-05-12 Track A Option
(3) migration — see Amendment log row):

> SIMD smoke benches against wasmtime + wazero + wasmer;
> recorded to `bench/results/history.yaml` per ADR-0012.
> **Per-op gap analysis required**: identify ops where v2 lags
> by > 3× the median of (wasmtime, wazero, wasmer) and file
> Phase 15 debt entries naming the candidate optimisation (AVX
> path adoption gated on CPUID, MOVAPS preamble peephole at
> op_simd binop sites, SIMD-specific coalescing). v1 reached
> "adequate for embedded" but explicitly accepted ~43× gap to
> wasmtime (D122); v2 inherits this gap as starting point and
> Phase 11's gap-analysis run produces the profile that drives
> Phase 15 SIMD-specific work scope beyond v1 W43/W44/W45
> porting.

> **Migration history** — this clause originally lived in §9.10
> (Phase 9 row). Track A Phase 10 prep (see
> `.dev/phase10_prep/track_a_9.10_scope.md` §3.3 Option (3)
> + §7) folded it into Phase 11's existing bench-infra cohort
> (D-074 alignment: D-074's barrier names "Phase 11 (WASI 0.1
> full + bench infra)" as the natural carrier for
> `-Dwith-bench-compare` + wazero/wasmer in `flake.nix` etc.,
> which are the prerequisites of the per-op gap analysis).
> §9.10's row stays in place with `[~] moved to Phase 11`
> marker (no §9 renumber per ADR-0014). The 3× threshold, the
> v1 D122 reference, and the AVX / MOVAPS / coalescing
> candidate list are unchanged — only the carrier phase
> moved.

**Phase 15 amendment** (this ADR):

Add a sentence to Phase 15's Goal+Exit:

> Phase 15 SIMD work absorbs (a) v1 W43/W44/W45 ports onto the
> v2 substrate as documented and (b) bench-driven SIMD-specific
> optimisations surfaced by Phase 11's gap analysis. The "v1
> parity" target is the floor, not the ceiling — exceeding v1's
> 43× gap to wasmtime is in scope where Phase 11 surfaces a
> candidate with a feasibility-supported debt entry.

The 3× threshold is conservative (one full octave of
performance gap) — strictly larger than the "adequate" bar v1
implicitly set, but not so tight that every minor encoding
difference triggers debt.

## Alternatives

### A — Leave §9.10 + Phase 15 as-is

**Rejected**. Without explicit gap-analysis discipline, §9.10's
output is unactionable. The risk is shipping with a 43×-class
gap and only discovering it post-release; cheaper to surface
candidates via the §9.10 row and triage in Phase 15.

### B — Set a tight numeric target ("v2 within 2× wasmtime")

**Rejected**. ADR-0041 §5 mandates SSE4.1 baseline; without
AVX, certain ops (e.g. 3-operand VPADD* avoiding the MOVAPS
preamble) are structurally not at parity. Setting a numeric
target without first knowing the gap distribution would either
force premature CPU-feature scope decisions or be unrealistic.

### C — Bump baseline to AVX/AVX2 in ADR-0041 now

**Rejected** (in this ADR). AVX-class baseline shift is a
separate decision that needs its own hardware-support survey.
ADR-0041's SSE4.1 baseline stays; this ADR only mandates that
**§9.10's gap analysis is the input that decides whether the
AVX upgrade is worth filing as a Phase 15 amendment**.

## Consequences

- §9.10 row text grows; Phase 15 row text grows. Both gain a
  concrete data-feedback loop.
- Phase 15's task surface becomes bench-driven (consumes §9.10's
  output) instead of just "port W43/W44/W45". This matches the
  general bench-driven-optimisation discipline ADR-0032 already
  established for §9.8b.
- ADR-0041 is unchanged — SSE4.1 baseline stays. AVX path is a
  Phase 15 candidate, not a Phase 9 baseline shift.
- 3× threshold is a knob; can be tightened in a Phase 15-prep
  ADR if §9.10 data shows the median gap is much smaller than
  the v1 D122 baseline (43×) suggests.

## References

- ADR-0041 §5 "SSE4.1 minimum baseline" — perf trade-off this
  ADR's amendment surfaces.
- ADR-0012 — bench harness ADR (`bench/results/history.yaml`
  format).
- ADR-0032 — bench-driven optimisation sequencing for §9.8b
  (precedent for §9.10 + Phase 15 feedback loop).
- v1 `~/Documents/MyProducts/zwasm/.dev/decisions.md: D122` —
  "43× geo mean gap vs wasmtime; adequate for embedded use case".
- Lesson `.dev/lessons/2026-05-09-v1-monolith-file-survey-miss.md`
  — the survey-shallowness retrospective that surfaced the
  user-facing comparison; same root cause for both this ADR and
  the textbook_survey.md amendment.

## Revision history

| Date       | Commit       | Note                                                                                                                                                                                                                                                                                                                                                                                |
|------------|--------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-05-09 | `221acd4d` | Initial draft (Accepted). Refines §9.10 + Phase 15.                                                                                                                                                                                                                                                                                                                                 |
| 2026-05-12 | `c27f74da` | Per Phase 10 prep Track A Option (3) decision (`.dev/phase10_prep/track_a_9.10_scope.md` §3.3 + §7), §9.10's gap-analysis clause migrates to Phase 11's bench-infra cohort (D-074 alignment). §9.10 row keeps `[~] moved to Phase 11` marker (no §9 renumber per ADR-0014). 3× threshold, D122 reference, AVX/MOVAPS/coalescing candidate list unchanged. Discharges D-076 in same chunk. |
