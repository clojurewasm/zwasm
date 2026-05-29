---
ADR: 0126
Title: WasmGC structural type canonicalization + iso-recursive rec-group subtyping
Status: Accepted
Date: 2026-05-29
Related: ADR-0124 (structural subtype validation lattice), ADR-0121 (struct/array typedef parse + RTT layout), ADR-0116 (GC roots + RTT + i31), ADR-0123 (typed-ref ValType)
---

## Context

The 10.G-wasmgc bundle reached **gc return 343/407** (cyc166). The
remaining gc return-fails are no longer per-op gaps — they are the deep
**type-system tail**, all rooted in one divergence: zwasm tracks defined
types **nominally** (by flattened type-section index), but Wasm 3.0 GC
treats them **structurally / canonically**.

Two intertwined gaps (D-198), confirmed by the cyc167 survey:

1. **Structural canonicalization gap.** Two structurally-identical
   typedefs at different indices are distinct to us but EQUAL to the
   spec. `ValType.eql` compares concrete refs by index
   (`a_idx == b_idx`); `gcConcreteReaches` walks the declared
   supertype chain by index. So:
   - `ref_test` **test-canon**: `$t1` and `$t1'` are both
     `(sub $t0 (struct (field i32)))` at distinct indices →
     `ref.test (ref $t1') <value of type $t1>` wrongly returns false.
   - Cross-module func imports (`type-subtyping.45/46/48/50`):
     the Linker's `sigEqual` uses `ValType.eql` (index identity), so a
     structurally-identical param/result type at a different index in
     the importer vs the exporter → `SignatureMismatch` / `UnknownImport`.

2. **Iso-recursive subtyping gap.** `(rec ...)` group identity is
   discarded at decode (types flatten to consecutive indices;
   `supertypes[i]` survives, rec-group membership does not). The
   validator's `gcConcreteReaches` / `gcFieldSubtype` have no
   **coinductive** rule: a recursive typedef whose field references
   itself (`(rec (type $t (sub (struct (field (ref $t)))))`) — or a
   cross-rec-group subtype with self-references — is not handled per
   Wasm 3.0 GC §4.3.4. The remaining `type-subtyping` `run exp=1 got=0`
   value-fails need this.

These are spec-defined (Wasm 3.0 GC §4.2.8 subtyping / §4.3.4
defined-type subtyping), so this ADR records HOW we implement them and
rejects the under-validating alternatives — not a free design choice.
ADR-0124 already established the parse-vs-validate coupling caution
(cyc122: a parse-only change regressed `gc invalid` 55→40), so any
type-model change MUST be verified against the FULL corpus
(all proposals + the assert_invalid set), not just the target fixtures.

## Decision

Implement **canonical structural type equivalence** + **iso-recursive
(coinductive) rec-group subtyping** per the spec, in two phases:

**Phase-10a — Structural canonicalization (lands first).**
Compute a **canonical type id** for every defined type from its
*comptype structure* (kind + fields/elements/params/results, their
storage/mutability, and — recursively — the canonical ids of any
concrete refs they contain, with rec-group self-references resolved
positionally). Two types with the same canonical id are
interchangeable. Consult canonical ids (not raw indices) in:
- `ValType.eql` for concrete refs (or an equivalent canonical compare
  at the call sites: subtype checks, `ref.test`/`ref.cast` runtime
  match, cross-module `sigEqual`).
- The runtime RTT check (`concreteReaches` / `gcRefMatchesNonNull`) so
  `ref.test (ref $b) <obj of canonically-equal type $a>` → true.

Fixes test-canon + the 4 cross-module import signature fails.

**Phase-10b — Iso-recursive coinductive subtyping (lands second).**
Add a `visiting` set to the type-section conformance check so a field
reftype pointing at a type still under validation is **provisionally
assumed** to satisfy the coinductive hypothesis (Wasm 3.0 GC §4.3.4),
while finality / forward-ref / multi-supertype invariants still apply.
Extends `gcFieldSubtype` / `gcConcreteReaches` to thread the visiting
set. Fixes the remaining `type-subtyping` validator fails.

**Mechanism note (not load-bearing; finalized in impl):** the canonical
id is preferentially computed at type-section decode / `materialiseGcTypes`
(closed-world, once per module) and stored alongside `supertypes` /
`TypeInfo`, so per-check cost stays O(1)–O(chain). Whether it is an
index-remap or a parallel `canonical_id[]` slice is an implementation
choice resolved at Phase-10a landing; both preserve `ObjectHeader`/Value
layout (no Value-representation change).

## Alternatives (rejected)

- **Nominal-only (status quo).** Under-validates: structurally-equal
  types stay distinct → test-canon + cross-module imports fail; spec
  non-conformant.
- **Per-check structural deep-compare (no canonical id).** Recompute
  structural equivalence on every subtype check. Correct but O(type
  size) per check on the validator hot path; the canonical-id memo is
  strictly better.
- **Land iso-recursive before canonicalization.** Rejected: iso-
  recursive alone doesn't fix the cross-module / test-canon canonical
  equality; canonicalization is the prerequisite (cross-rec-group
  equivalence needs canonical ids first).
- **One mega-commit.** Rejected: the parse-coupling regression risk
  (ADR-0124 / cyc122) demands the canonicalization land + be full-corpus-
  verified before the coinductive validator change stacks on top.

## Consequences

- Cross-module GC type imports + `ref.test`/`ref.cast`/`br_on_cast`
  over structurally-equal types become spec-correct.
- Recursive + mutually-recursive rec-group typedefs validate per spec.
- No Value / `ObjectHeader` layout change; validator hot path stays
  O(1)–O(chain) (canonical id is a memo, not a per-check walk).
- Regression surface = the WHOLE type-section decode + subtype lattice
  (load-bearing). Each phase MUST verify FULL test-spec (all proposals
  + assert_invalid) exit 0 + no `gc invalid` regression, per ADR-0124.
- D-198 discharges across Phase-10a + Phase-10b.

## Phase-10b implementation notes (cyc170 design spike)

Post-Phase-10a, the last 5 gc fails are all `type-subtyping` (everything
else clean, gc 345). Verified fixture breakdown:

- **45** (M7 exporter): within-module **ValidateFailed** — `$h sub $g2`
  across rec-group boundaries; the type-section conformance check's
  recursive field-ref comparison doesn't terminate/match for rec-group-
  local recursive refs.
- **46 / 48 / 50** (importers of M7/M8/M9): cross-module func-import
  **SignatureMismatch** — the spec rule is exporter's actual type **<:**
  importer's *declared* type (contravariant params / covariant results),
  but Linker `sigEqual` (linker.zig ~527) is EXACT `ValType.eql` only.

**Decision: bisimulation, NOT positional canonicalization.** A visited-
pair `(sub_idx, sup_idx)` set handles rec-group cycles WITHOUT threading
rec-group spans through decode/validate/linker (which decode currently
discards). Lower-risk, isolated to the subtype-check helpers.

**CORRECTNESS CAUTION (load-bearing — verify in-cycle before coding).**
Iso-recursive subtyping is the **declared** relationship checked with
**coinductive structural conformance**, NOT pure structural equality.
The fix is a NARROW coinductive visiting-pair guard added to the
**field-ref / concrete-ref comparison** inside `gcFieldSubtype` /
`gcValTypeSubtype` (so mutually-recursive refs assume-equal on revisit
+ terminate) — it must NOT replace the declared-supertype-chain walk
(`gcConcreteReaches`) with blanket structural equivalence (that would
make unrelated same-shape types subtypes → **invalid-regression**, the
cyc122 failure mode). The cyc170 design-spec subagent's
"replace gcConcreteReaches with structural bisim" framing is REJECTED
on this ground; the next implementer must first re-derive the exact
failing comparison per fixture (the within-module 45 vs the cross-module
linker 46/48/50 are distinct mechanisms).

**Landing order + verification.** (1) Validator coinductive field-ref
(fixture 45), then (2) Linker `sigSubtype` (46/48/50). Each MUST verify
FULL test-spec ALL proposals + assert_invalid (`gc invalid` MUST stay
57) + exit 0 + 0 panics. HIGH blast radius → fresh-context cycle, not a
tail-of-session cram.

**cyc171 verified finding (the precise fix).** Decoded fixture 45: the
failure is `gcValTypeSubtype((ref $f1),(ref $f2))` in struct-field
conformance, where `$f1`/`$f2` are structurally-identical bare `(func)`
at distinct rec-group indices → it's **canonical EQUALITY**, not
coinductive subtyping. Prototyped `gcCanonicalEqual` (recursive
structural equality: finality + canonical supertypes + comptype, refs
recurse, depth-32 coinductive cutoff) as an OR in gcValTypeSubtype's
concrete→concrete arm. Result: **fixture 45 validates + `gc invalid`
HELD at 57 (regression-safe)** — BUT gc return stayed 345 (the fail just
shifted instantiate→runtime: the module's `run`-assert still fails
because the RUNTIME `concreteReaches` canonical match uses cyc168's
raw-index `canonical_ids` (insufficient cross-rec-group)). So the
validator change alone is **non-observable** → reverted (spike_discipline
§2). **The combined fix that flips an assert**: a SHARED canonical-
equivalence module (operating on the decoded types) feeding BOTH (a) the
validator (gcValTypeSubtype OR canonical-equal) AND (b) the runtime —
upgrade cyc168 `materialiseGcTypes` to compute **equivalence-class**
canonical_ids (pairwise `canonicalEqual`, O(n²), n small) instead of the
raw-index hash, so `concreteReaches` matches cross-rec-group. Land both
together for the observable +N. `gcCanonicalEqual` was verified safe — re-
apply it from this note.

## References

- Wasm 3.0 GC §4.2.8 (subtyping), §4.3.4 (defined-type / iso-recursive
  subtyping), §3.3 (rec-groups).
- ADR-0124 (structural subtype validation lattice; parse-vs-validate
  coupling caution).
- D-198 (`.dev/debt.md`).
- cyc167 survey (this ADR's Context + phased plan).

## Revision history

- 2026-05-29 — Initial draft + Accept (cyc167). Autonomous per the
  session's standing mandate to investigate + apply deep GC work; the
  conformance rules are spec-pinned, so this records the
  implementation strategy + the phased landing, not a free choice.
- 2026-05-29 — Amendment (cyc170): Phase-10a landed (canonical ids +
  RTT match c168; ref.test eq-precise c169 → gc 343→345). Added the
  Phase-10b implementation notes (verified 5-fixture breakdown,
  bisimulation decision, the declared-vs-structural correctness caution
  rejecting the spike's wholesale-replacement framing). Phase-10b queued
  as a fresh-context implementation (HIGH blast radius).
