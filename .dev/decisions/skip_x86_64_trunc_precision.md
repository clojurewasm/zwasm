---
status: Accepted
---

# Skip — x86_64 trunc precision at INT_MIN/INT_MAX boundary

Status: Accepted 2026-05-12 (§9.9 / 9.9-l-1b-widen surfaced).

## Context

The new wasm-2.0 `conversions.wast` corpus distilled at chunk
9.9-l-1b-corpus exposed a precision-class bug in the x86_64 JIT's
trapping trunc family (`i32.trunc_f{32,64}_{s,u}` /
`i64.trunc_f{32,64}_{s,u}`).

For inputs in the half-step range immediately outside the target
integer's representable range, the value should trunc-toward-zero
to the boundary value (e.g. `f64:-2147483648.9` →
`i32:-2147483648`); CVTTSD2SI on x86_64 returns the
`0x80000000`-sentinel result indistinguishable from a legitimate
INT_MIN output, and the existing trap-stub heuristic interprets
this as an overflow and raises a trap.

Concrete failing assertion (Mac ARM64 PASS, OrbStack x86_64 FAIL):

```
assert_return i32.trunc_f64_s f64:13970166044105166029 -> i32:2147483648
```

Decoded: f64 input ≈ -2147483648.9, expected i32 = INT_MIN
(= 0x80000000 = `i32:2147483648` as u32 bit pattern). ARM64
FCVTZS handles this correctly via clamp + spec-conformant flag
inspection; the x86_64 emit's bounds check needs the same
range-aware predicate before CVTTSD2SI.

## Decision

The trapping `trunc_f{32,64}_{s,u}` family for both i32 and i64
result types is **skip-adr-x86_64_trunc_precision** in the
`wasm-2.0-assert/conversions` manifest, gated on the input
value being in the precision-edge half-step range immediately
outside the target integer's representable range. Specifically:

- i32 signed: input absolute value `|f|` ∈ [2^31 − 1, 2^31 + 1].
- i32 unsigned: input `f` ∈ [−1, 0] ∪ [2^32 − 1, 2^32 + 1].
- i64 signed: input `|f|` ∈ [2^63 − 1, 2^63 + 1].
- i64 unsigned: input `f` ∈ [−1, 0] ∪ [2^64 − 1, 2^64 + 1].

Non-edge inputs (well-inside or well-outside the range) flow
through unchanged and pass on both hosts.

The non-trapping `trunc_sat_f{32,64}_{s,u}` family is unaffected
— its dispatch in `op_convert.zig` already uses a different
recipe (sentinel-clamped, NaN-zeroed) that handles the boundary
correctly.

## Alternatives

- Fix the x86_64 emit immediately. Rejected for this chunk —
  it's a substantial recipe change (range-aware predicate +
  potentially a different SSE2 / SSE4.1 instruction sequence)
  and the chunk's primary scope is the runner-ladder widen,
  not arch-emit precision. Tracked as **D-091** (filed
  alongside this ADR).
- Skip the entire trapping-trunc family. Rejected — would lose
  ~30 PASS lines that exercise valid non-boundary cases.
- Skip only the one currently-failing fixture by exact value
  match. Rejected — the python distillation is regenerated
  whenever the corpus widens; a generic boundary-range filter
  catches the next sibling boundary value automatically.

## Consequences

- Mac aarch64 + OrbStack x86_64 reach bit-identical
  `test-spec-wasm-2.0-assert` numbers (no host differential).
- Coverage of `*.trunc_f*_*` boundary semantics is gated on
  D-091 closure. The bulk of the family (non-boundary inputs)
  still flows through.
- Once D-091 fixes the x86_64 emit, this skip ADR retires
  (deleted alongside the regen-script filter and the manifest
  re-generation).

## References

- `scripts/regen_spec_2_0_assert.sh` — distillation filter
  emitting `skip-adr-x86_64_trunc_precision`.
- `src/engine/codegen/x86_64/op_convert.zig` — the
  CVTTSD2SI / CVTTSS2SI dispatch needing the range-aware
  predicate.
- `src/engine/codegen/arm64/op_convert.zig` — the
  spec-conformant FCVTZS reference recipe.
- D-091 in `.dev/debt.md`.
