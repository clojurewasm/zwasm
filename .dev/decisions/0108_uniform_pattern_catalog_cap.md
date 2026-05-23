# 0108 — Uniform-pattern catalog file-size tier (CATALOG-EXEMPT marker)

- **Status**: Proposed
- **Date**: 2026-05-23
- **Author**: claude (autonomous loop, cycle 30)
- **Tags**: scaffolding, file_size_check, entry.zig, D-167, D-168
- **Amends**: ADR-0099 §D1 (file-size tier table); reinforces ADR-0099 §D2 (P1 / catalog rationale)
- **Reverts-portion-of**: none

## Context

`src/engine/codegen/shared/entry.zig` (cycle 29 HEAD) is exactly at
the EXEMPT-CAP=2500 set by ADR-0099 §D1. The file contains 114
`pub fn callXxx` entry helpers + paired `FuncRet_xxx` extern
structs — a closed catalog of per-shape JIT-entry adaptors keyed
by Wasm function signature shape (param types × result types).
Each helper is ~10-15 LOC of mechanical:

```zig
pub fn callI32i32_i32(module, func_idx, rt, a0) Error!FuncRet_i32i32 {
    const Fn = *const fn (*const JitRuntime, u32) callconv(.c) FuncRet_i32i32;
    return invokeAndCheck(rt, FuncRet_i32i32, module.entry(func_idx, Fn), .{a0});
}
```

The catalog grows monotonically with each new Wasm signature shape
that surfaces in the spec corpus. Cycle 29's D-167 wire-up
attempt would have added 21 lines (3 Win64 if-arms × 7 lines)
→ 2521 lines → `EXEMPT-CAP EXCEEDED` block. Reverted; filed
D-168 with 4 split strategy options.

Option-by-option assessment against ADR-0099 §D2:

- **(a) Per-shape sibling extraction** (e.g. `entry_i32i32.zig`,
  `entry_i32i64.zig`) — each sibling ~50-80 LOC → triggers
  ADR-0099 N3 (shallow module). REJECT.
- **(b) Extract `callLargesig` + `FuncRet_largesig`** (~85 LOC) —
  borderline N3-shallow (< 100 LOC substantive); fixes
  immediate cap pressure but doesn't address the catalog's
  monotonic growth. Token discharge, not structural fix.
- **(c) Extract `invokeAndCheck` / ABI marshalling helpers** —
  the helpers are private to entry.zig's catalog (each
  caller is one of the 114 helpers); extracting creates an
  N1 helper-circular-import. REJECT.
- **(d) Amend ADR-0099 to define a catalog-cap tier above
  2500 with declared rationale** — what this ADR proposes.

Per `.claude/rules/file_size_smell.md` "Decision tree": when
no valid extraction exists, add EXEMPT marker — that IS the
default ADR-0099 outcome. The current EXEMPT marker is in
place at entry.zig:1 but caps at 2500; no higher tier exists.

ADR-0099 §D2 explicitly names "uniform-pattern catalog" as a
legitimate exempt rationale category (cited in the
`file_size_smell.md` rule body: "Uniform-pattern catalog
(e.g., entry.zig: 84 callXX_yy helpers)"). That rationale
already informally covers entry.zig — but no cap tier is
defined for the case where the catalog naturally grows past
2500.

## Decision

Define a new file-size tier **CATALOG-EXEMPT (4000)** in the
hard-cap ladder:

| Cap | Lines | Behavior | Marker |
|---|---|---|---|
| Soft | 1000 | WARN | (none) |
| Hard | 2000 | BLOCK | (none) — investigate per ADR-0099 |
| Exempt | 2500 | BLOCK with marker raise | `// FILE-SIZE-EXEMPT: <rationale> (per ADR-0099)` |
| Catalog-Exempt | 4000 | BLOCK with stricter marker raise | `// FILE-SIZE-CATALOG-EXEMPT: <catalog-name> (per ADR-0108)` |

The new marker `FILE-SIZE-CATALOG-EXEMPT` accepts only one
rationale category: **uniform-pattern catalog** — a file
whose substantive code is dominated (≥ 60% of LOC) by N+
declarations of the same mechanical shape, each ≤ 20 LOC,
where the count grows monotonically with an enumerable
external axis (Wasm signature shapes, ISA opcodes, etc.).

`scripts/file_size_check.sh` extension:
- Detect `// FILE-SIZE-CATALOG-EXEMPT: <rationale>` marker.
- Validate the rationale string matches `^[A-Za-z][A-Za-z0-9_ -]*$`
  (named catalog, ≥ 1 chars, no special chars). Vague text
  ("legacy", "later") rejected.
- Raise hard cap from 2000 (or 2500 with regular EXEMPT) to
  4000 for the marked file.
- Continue WARN at soft cap (1000) — smell-detection signal
  persists.

Initial CATALOG-EXEMPT site: `src/engine/codegen/shared/entry.zig`
(rationale: "wasm-signature-shape-catalog").

## Alternatives

- **Per-shape sibling extraction** — see option (a) above. Rejected
  per ADR-0099 N3 (shallow module).
- **Largesig extraction only** — token fix; doesn't address
  monotonic growth.
- **Raise EXEMPT-CAP globally to 3000+ without catalog marker** —
  weakens the smell-detection discipline for non-catalog files
  whose drift over 2500 IS a smell. The split marker preserves
  the discipline.
- **Generate the catalog from a comptime metaprogramming pass**
  (e.g., emit per-shape helpers from a `signature_shapes.zig`
  table). Plausible long-term direction (Phase 12+) but defers
  D-167 wire-up beyond Phase 9 close. Removal condition for
  this ADR.

## Consequences

**Positive**:
- D-167 wire-up unblocks: cycle 30+ can land the 3 Win64 if-arms
  + helper without code churn.
- entry.zig can absorb the next 1500 LOC of new signature
  shapes without scaffolding churn.
- The CATALOG-EXEMPT marker's stricter rationale validation
  (vs regular EXEMPT) prevents drift: only genuine catalogs
  qualify.

**Negative**:
- Two markers to maintain (regular EXEMPT and CATALOG-EXEMPT).
- The 4000 hard cap is judgment-set, not principled. If
  entry.zig pushes past 4000, the ADR needs re-amendment.
  (Mitigation: at 4000, the catalog is genuinely large enough
  to warrant the comptime-metaprogramming path mentioned in
  Removal condition.)

**Neutral**:
- Other current-catalog candidates (`op_simd_int_cmp_lane.zig`
  at 2121, others) remain at regular EXEMPT (2500) — they're
  within the regular tier and don't need the new marker.

## Removal condition

This ADR retires when:
1. entry.zig is migrated to a comptime-metaprogramming catalog
   (per-shape helpers generated from a `signature_shapes.zig`
   declarative table), OR
2. The catalog count plateaus (Wasm spec stops adding new
   call/result-multi shapes — Phase 12+ post-Wasm-3.0).

When retired: remove the CATALOG-EXEMPT marker from entry.zig,
remove the cap tier from `scripts/file_size_check.sh`, mark
this ADR `Status: Closed`.

## References

- ADR-0099 — file-size discipline reframe (the parent ADR
  this amends).
- ADR-0023 §A2 — original cap rationale (smell detector).
- ADR-0063 — EXEMPT marker mechanism (the precedent this
  extends).
- `.claude/rules/file_size_smell.md` — the rule that codifies
  ADR-0099 D2 + this ADR's tier (update needed at Accept).
- `.dev/debt.md` D-167 (Win64 multi-arg wrapper wire-up) +
  D-168 (entry.zig structural debt; this ADR is its
  resolution path option (d)).
- `src/engine/codegen/shared/entry.zig` — 114 entry-helper
  catalog at HEAD=c15090d5.

## Revision history

- 2026-05-23 — Initial draft at cycle 30 (private/notes/ —
  none; ADR is the artifact). Filed Status: Proposed for
  user collab review.
