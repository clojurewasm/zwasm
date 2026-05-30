# 0127 — Cross-module func import type-identity (finality + supertype + canonical)

- **Status**: Accepted (2026-05-31 via ADR-0128 — user "100%" directive; D-202 PHASE C implements next)
- **Date**: 2026-05-30
- **Author**: claude (autonomous loop)
- **Tags**: cross-module, linker, gc, type-identity, finality, canonical, subtyping, D-202, Phase 10 / 10.M
- **Paired debt**: D-202 (cross-module func import); supersedes the "needs an ADR" note there.

## Context

The C-API Linker (`src/zwasm/linker.zig`) resolves a Wasm func import
against an exported func of another instance. The import is valid iff
the exporter's actual func type `$E` is a **subtype of** the importer's
declared import type `$I` (Wasm 3.0 §3.3.5.3 — the import type is the
upper bound). zwasm has landed two of the three facets:

- **PHASE A** (cyc236, `38bb0e0e`): structural subtyping —
  `validator.funcTypeImportCompatible` (params contravariant / results
  covariant). Accepts `gc/type-subtyping.30/.48/.50` (a func imported
  under a subtype-compatible sig). Replaced the exact `sigEqual`.
- **PHASE B-finality** (cyc239, `a4bd9bbb`): if `$I` is FINAL, the
  exporter must also be final. Threaded `ExportFuncType.final` →
  `CrossModuleFuncEntry.source_final`. Fixed `.35` (assert_unlinkable
  5→4).

**The gap (PHASE C)**: structural subtyping + the finality bool is still
insufficient. `gc/type-subtyping.36/.42/.52/.54` (4 assert_unlinkable)
WRONGLY LINK. `.36` (cyc240 inspection) is the *opposite* direction of
`.35`: the importer imports as an **open** `(sub (func))` (type 0) but
the exporter provides a structurally-identical-yet-**distinct**
type-definition. `funcTypeImportCompatible` passes (the `()->()`
param/result structure matches), and the finality check does not fire
(the importer is not final), so the import wrongly links.

For a `()->()` func the param/result structure is trivially equal, so
the import's validity reduces ENTIRELY to **type-definition identity**:
finality + declared supertype + canonical structure. The current check
inspects none of that for the func type-definition itself.

### The no-regression constraint (load-bearing)

PHASE C NARROWS acceptance (rejects more imports), so it risks
regressing imports that currently link:

- **Green exact-equal imports** — the 407 multi-mem + 34 EH cross-module
  func imports (per D-198 cyc191) match by `eql`. Their importer/exporter
  type-defs are equal ⇒ canonically equal ⇒ MUST still accept.
- **PHASE A subtype-compatible accepts** — `.30/.48/.50` import the same
  name under subtype-related sigs (concrete-ref params/results). Their
  type-defs are subtype-related (declared-super or canonical) ⇒ MUST
  still accept.
- A **naive type-index compare** (require `exporter_typeidx ==
  importer_typeidx`) would reject all of these (cross-module type indices
  do not align) — explicitly rejected (it regresses the green imports).

## Decision

The cross-module func import is valid iff BOTH hold:

1. **Structural subtyping** — `funcTypeImportCompatible($I, $E,
   importer_types)` (PHASE A; unchanged). Contravariant params /
   covariant results over the flattened val-types.

2. **Type-definition compatibility** — `$E`'s func type-definition is a
   subtype of `$I`'s, by:
   - **canonical equality** of the two type-defs (rec-group-span-aware
     structural equality INCLUDING finality), OR
   - `$E` declares `$I`'s type-def in its supertype chain.

   Computed across the two modules' `Types` (importer's `module_types`
   at the link site; exporter's via the threaded type-def info). Reuse
   the validator's existing `sections.canonicalEqual` (rec-group-span
   aware, cyc177 `5c41c273`) extended to compare across two `Types`.

Threading: widen the exporter's exposed func type-def info on
`CrossModuleFuncEntry` from `{ source_signature, source_final }` to also
carry the exporter func's **typeidx + declared supertypes** (captured in
`buildExportTypes`, where the parse-time `Types` is alive — same pattern
as PHASE B-finality's `ExportFuncType.final`). At the resolve check, run
the type-def compatibility (#2) using the threaded exporter type-def +
the importer's `module_types`.

The finality bool (PHASE B) becomes a special case of #2 (canonical
equality already compares `finals`); PHASE B can stay as-is or fold into
#2.

## Alternatives considered

- **A. Naive type-index equality** (`exporter_typeidx ==
  importer_typeidx`). Rejected: cross-module type indices never align;
  regresses the 407 + 34 green imports + `.30/.48/.50`.
- **B. Structural-only (current PHASE A)**. Rejected: insufficient — it
  accepts type-def-mismatched `()->()` imports (`.36/etc.`).
- **C. Finality bool only (PHASE B-finality)**. Insufficient by
  construction (fires only when the importer is final); `.36` (importer
  open) escapes it.
- **D. Re-run the full validator subtype lattice cross-module**. Heavier
  than needed; the import check only needs `$E <: $I` for the single
  func type-def, which `canonicalEqual` + supertype-reach already
  express.

## Consequences

**Positive**: `assert_unlinkable .36/.42/.52/.54` correctly reject
(5→0 with PHASE B). The cross-module import check matches the Wasm 3.0
subtype semantics for the func type-definition, not just the flattened
structure. Reuses the landed `sections.canonicalEqual`.

**Negative / risk**: the cross-`Types` canonical compare is the
regression-risky part — the no-regression set (407 + 34 + `.30/.48/.50`)
MUST stay green. Mitigation: the gate's full spec corpus exercises all
of them; implement #2 as `canonicalEqual OR supertype-reach` (a
WIDENING of acceptance beyond exact-equal, so exact-equal + subtype
imports are accepted by construction) — the NARROWING only happens for
type-def-mismatched `()->()` imports the structural check can't tell
apart. The exporter type-def threading adds a field to
`ExportFuncType` / `CrossModuleFuncEntry` (small, mirrors PHASE B).

## Removal condition

Retires when D-202 PHASE C ships with `assert_unlinkable` for
`gc/type-subtyping` at 5→0 (all of `.35/.36/.42/.52/.54` reject), the
no-regression set (multi-mem 407 + EH 34 + `.30/.48/.50`) stays green on
the 3-host gate, and the impl matches decision #1 + #2. Status →
`Closed (Implemented)` with the SHA.

## References

- D-202 (cross-module func import; PHASE A/B landed, PHASE C scope).
- D-198 cyc191 (the no-regression `eql` set: 407 multi-mem + 34 EH).
- `src/zwasm/linker.zig` (cross_module_func resolve arm; PHASE A/B).
- `src/runtime/instance/instance.zig::ExportFuncType` (PHASE B-finality
  threading pattern to extend).
- `src/parse/sections.zig::canonicalEqual` (rec-group-span aware, cyc177
  `5c41c273`) — extend cross-`Types`.
- `validator.funcTypeImportCompatible` (PHASE A structural subtyping).
- Wasm 3.0 §3.3.5.3 (func subtyping), §3.3.13 (type-definition subtyping).

## Revision history

- 2026-05-30 — Initial draft via `/continue` autonomous prep path
  (D-202 PHASE C de-risking). Status: Proposed pending user review (the
  cross-module canonical-equality semantics + the no-regression argument
  are the load-bearing review points).
- 2026-05-30 (cyc242) — Impl-survey CONFIRMED the cross-`Types`
  `canonicalEqual` is genuinely required; the tempting "cross-module
  index / supertype-reach" shortcut is exactly the rejected Alternative
  A and REGRESSES. Evidence: `sections.canonicalEqual(types, a, b)`
  (`sections.zig:179`) takes a SINGLE `Types` and compares rec-group
  position + finality + declared-supertypes + struct/array fields — so
  the importer index `typeidx` and the exporter index `source_typeidx`
  live in DIFFERENT `Types`; a predicate like `source_typeidx == typeidx`
  or `typeidx ∈ exporter_supertypes` rejects the green exact-equal
  imports (407 multi-mem + 34 EH), whose importer/exporter indices do
  not align. So decision #2 requires a NEW `canonicalEqualCross(types_a,
  idx_a, types_b, idx_b)` threading both `Types` through the recursion
  (intricate: the intra-group-positional vs inter-group-canonical
  distinction must track per-type which `Types` it belongs to). The
  exporter's full `Types` (not just `final` + a supertype list) must be
  reachable at the linker. Impl is genuinely intricate → fresh-context /
  post-Accept cycle, NOT a quick threading extension.
