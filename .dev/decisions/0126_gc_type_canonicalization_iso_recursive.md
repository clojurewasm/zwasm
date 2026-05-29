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

## Phase-10b RE-SCOPED to THREE pieces (cyc175 empirical root-cause)

cyc175 traced the residual end-to-end (DIRECT binary, `--fail-detail` +
the `.wast` source). The cyc170-172 framing (validator-canonical +
linker-sigSubtype, two pieces) was **incomplete** — it missed the actual
runtime mechanism. The current 5 type-subtyping return-fails are **3
FAILsetup + 2 FAILval** (not 1-validate + 3-link + 2-val), and the
fixtures are the **Runtime-types `ref.test` modules** (`.wast` lines
348-440), NOT the Linking-section cross-module imports (those `module`
directives at 614-700 already pass). So the **linker `sigSubtype` piece
is NOT on the residual path** — drop it from the active plan.

The real residual decomposes into THREE coordinated pieces:

**Piece 1 — Validator `gcCanonicalEqual` (verified-safe, non-observable
alone).** A narrow OR-arm in `gcValTypeSubtype`'s concrete→concrete arm:
`gcConcreteReaches(a,e) or gcCanonicalEqual(a,e,types)`. `gcCanonicalEqual`
= recursive structural equality on `sections.Types` (same kind +
finality + **canonically-equal declared supertypes** + comptype; concrete
refs recurse via a valtype helper; depth-32 coinductive cutoff returning
`true`). Comparing supertypes — not just comptype — keeps `(sub $x)` and
`(sub $y)` distinct when `$x ≢ $y`, avoiding the cyc122 invalid-regression.
**Verified cyc175**: re-applied → gc invalid HELD 57, and the FAIL split
shifted **3 FAILsetup+2 FAILval → 2 FAILsetup+3 FAILval** (one Runtime
module, `.wast` 360 — the `$g2` struct `(sub $s2 ...)` needing
`(ref $f1)<:(ref $f2)` to validate — now COMPILES). But return stayed 345
(the fail moved compile→runtime), so it cannot land alone (spike §2).

**Piece 2 — Funcref→RAW-typeidx resolution in `ref.test`/`ref.cast`
(THE GAP cycles 170-172 MISSED).** `gcRefMatchesNonNull`
(`ref_test_ops.zig`) on a concrete-typeidx target calls
`readObjInfo(rt, v)`, which reads an `ObjectHeader` from the **GC heap**.
But `ref.test (ref $g1) (ref.func $g)` operands are **funcrefs**
(`Value.fromFuncRef` = a `*FuncEntity` pointer, ≥ heap bounds), NOT heap
GC objects → `readObjInfo` returns null → `concreteReaches` never runs →
`ref.test` returns 0. This is why all the residual `ref.test`-on-funcref
asserts fail, and why cyc172's runtime equivalence-class experiment was
falsely "non-observable" — the canonical_ids were never even consulted
for funcrefs. **Fix**: when the concrete target's `gti.entries[ht].kind
== .func`, resolve the operand via `Value.refAsFuncEntity(v)` and
`concreteReaches(fe.<RAW typeidx>, ht)`.
**CAUTION — do NOT use `FuncEntity.typeidx`**: it is the *canonicalized*
index (`canonicalTypeidx` via `funcTypeEql`, raw param/result `eql`), so
for bare `()->()` funcs it collapses `$g2 → $f1` (the first bare func),
**losing the subtype identity** — `concreteReaches($f1, $g1)` then asks
the wrong question. Piece 2 needs the func's **RAW declared type index**
(investigate: `runtime.func_typeidxs[fe.func_idx]` or add a raw field to
`FuncEntity` WITHOUT touching the canonical `.typeidx` that JIT
`call_indirect` depends on — ADR-0068).

**Piece 3 — PRECISE equivalence-class `canonical_ids` (cyc172's piece,
correct now that Piece 2 exists).** cyc168 `canonical_ids` fold the
supertype as **0** (conservative) and hash bare funcs identically
regardless of rec-group context, so they CONFLATE `$g1`/`$g2` even when
the context differs. **Regression boundary = `.wast` module 378**: there
`$f2`'s rec-group struct references `(ref $f1)` (not `(ref $f2)`), so
`$f1 ≢ $f2` ⟹ `$g1 ≢ $g2` ⟹ `ref.test (ref $g1)(ref.func $g:$g2)` must
return **0**. Coarse canonical_ids (or any fix landing Piece 2 alone)
would make 378 return **1** — a silent value-regression that the
aggregate count can mask. Piece 3 = the O(n²) pairwise-`canonicalEqual`
equivalence-class merge (per the Phase-10a "Mechanism note"), computed
once at `materialiseGcTypes`, so `concreteReaches`' canonical compare is
precise. Verify 348/360 → 1 AND 378 → 0 in the SAME run.

**Landing order (cyc176, fresh budget):** Pieces 1+2+3 land TOGETHER
(none is observable alone; 2-without-3 regresses 378). Then re-measure:
the 3 FAILval should flip to pass. The **2 remaining FAILsetup** (modules
that STILL don't compile after Piece 1) are a SEPARATE 4th investigation
— trace which `.wast` module + why (may need a validation path beyond
field-subtype canonical-equal). FULL test-spec ALL proposals +
assert_invalid: gc invalid MUST stay 57, multi-mem ≥396, exit 0, 0 panics.

## cyc176 RESULT — pieces implemented; piece 2 PROVEN; the equality must be REC-GROUP-AWARE

cyc176 implemented all 3 pieces (shared `sections.canonicalEqual` for the
validator OR-arm + the `materialiseGcTypes` equivalence-class
`canonical_ids`; `FuncEntity.raw_typeidx` set in both instantiate paths;
funcref→raw-typeidx resolution in `gcRefMatchesNonNull` when the target
type's kind is `.func`). Built clean, gc invalid HELD 57, no proposal
regression. **Piece 2 (funcref-RTT) is CONFIRMED correct**: the 3 FAILval
flipped **`exp=1 got=0` → `exp=0 got=1`** — i.e. the expect-1 cases
(348/360) now PASS (the funcref resolves to its raw typeidx and
`concreteReaches` matches), and only the expect-**0** cases now fail.

**The sole remaining gap (reverted, re-do cyc177): `canonicalEqual` is
REC-GROUP-BLIND.** It compares a type's own kind+finality+supertypes+
comptype but NOT its rec-group membership. Module 378:
`(rec $f1 (sub func)) (struct (field (ref $f1)))` vs
`(rec $f2 (sub func)) (struct (field (ref $f1)))` — `$f1`'s struct
self-references its OWN group's func; `$f2`'s struct references the
EXTERNAL `$f1`. Iso-recursively these rec groups differ, so `$f1 ≢ $f2`
(ref.test must be 0). But flat structural equality sees both as bare
`()->()` funcs whose struct siblings both hold `(ref $f1)` (same index!)
→ deems them equal → ref.test wrongly 1. **cyc171, cyc172, AND cyc176 all
shared this blind spot** — flat structural/equivalence-class equality
cannot capture iso-recursion. No conservative flat tweak fixes both 348
(needs equal) and 378 (needs distinct).

**cyc177 — the CORRECT fix (rec-group-span-aware iso-recursive equality).**
The plumbing (funcref resolution, `FuncEntity.raw_typeidx`,
equivalence-class `canonical_ids` driver, validator OR-arm) is
verified-correct — only the equality ALGORITHM changes. Required:
1. Retain **rec-group spans** at decode (`sections.decodeTypes` — add a
   per-type `rec_group: [2]u32` start/end OR a `rec_group_id: []u32`;
   decode currently flattens `(rec …)` to consecutive indices, discarding
   membership — the long-standing gap ADR-0126 Context named).
2. `canonicalEqual(a,b)` becomes **rec-group equality**: the two types'
   whole rec groups must be isomorphic, comparing members pairwise with
   **intra-group** concrete refs resolved POSITIONALLY (ref to "member k
   of this group") and **inter-group** refs by the referent's canonical
   id. This is the standard WasmGC iso-recursive canonical form (§3.3).
3. module 378 = the bar: 348/360 → ref.test 1 AND 378 → 0 in one run;
   gc invalid stays 57 (ADR-0124 decode-coupling caution — verify FULL
   corpus). HIGH risk (touches decode); fresh focused cycle.

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
- 2026-05-29 — cyc171/172 verified-but-reverted (no corpus delta;
  spike §2): (a) validator `gcCanonicalEqual` OR-clause → fixture 45
  validates, gc invalid HELD 57 (regression-safe) but non-observable
  alone; (b) runtime equivalence-class `canonical_ids` (pairwise
  canonicalEqual) → gc invalid held 57 (runtime-only can't touch
  validate) but **did NOT flip the 2 type-subtyping FAILval** —
  **FALSIFIES** the hypothesis that the FAILval are cross-rec-group
  canonical-equality cases; their root cause is something else (trace
  the exact `run` ref.test/cast per-assert). **Observable path forward**:
  the 3 cross-module fails (45 exporter validate + 46/48/50 importer
  link) flip only when validator-canonical-equal [verified safe] AND
  Linker `sigSubtype` (exporter<:importer) land TOGETHER. The 2 FAILval
  are a SEPARATE, non-canonical, currently-unexplained runtime cause.
- 2026-05-29 — **Amendment (cyc175): residual RE-SCOPED to three pieces;
  the cyc170-172 framing was wrong about the mechanism.** End-to-end
  trace (DIRECT binary + `.wast`) found the residual is the Runtime-types
  `ref.test`-on-funcref modules (`.wast` 348-440), NOT the Linking-section
  cross-module imports (those `module` directives already pass) — so the
  **Linker `sigSubtype` piece is OFF the residual path** (dropped from the
  active plan). Root cause of the 2 original FAILval (the "unexplained
  runtime cause" above): `gcRefMatchesNonNull` reads the GC heap via
  `readObjInfo`, but `ref.func` operands are `*FuncEntity` pointers, not
  heap objects → null → `ref.test` returns 0. cyc172's equivalence-class
  was non-observable because the canonical_ids were never consulted for
  funcrefs at all. See the new "Phase-10b RE-SCOPED" section: Piece 1
  (validator `gcCanonicalEqual`, re-verified safe — invalid 57, shifts 1
  FAILsetup→FAILval), Piece 2 (funcref→**RAW** typeidx resolution — do NOT
  use the canonicalized `FuncEntity.typeidx`), Piece 3 (precise
  equivalence-class canonical_ids, with `.wast` module 378 — `$f1≢$f2` —
  as the no-regression boundary). All three land together cyc176; the 2
  residual FAILsetup are a separate 4th investigation. cyc175 reverted
  the validator change (non-observable alone, spike §2).
- 2026-05-29 — **Amendment (cyc176): all 3 pieces implemented; piece 2
  (funcref-RTT) PROVEN correct; the equality must be REC-GROUP-AWARE.**
  Built clean (shared `sections.canonicalEqual`, `FuncEntity.raw_typeidx`
  in both instantiate paths, funcref resolution in `gcRefMatchesNonNull`,
  equivalence-class `canonical_ids`). gc invalid HELD 57, no proposal
  regression. The 3 FAILval flipped **`exp=1 got=0` → `exp=0 got=1`**:
  the expect-1 cases (348/360) now PASS (piece 2 confirmed), only the
  expect-0 cases fail. Root cause of the residual: `canonicalEqual` is
  **rec-group-blind** — module 378 (`$f1` struct self-refs its own group;
  `$f2` struct refs external `$f1`) needs `$f1 ≢ $f2`, but flat structural
  equality deems them equal (both bare funcs, both struct fields hold
  `(ref $f1)` by index) → over-match. cyc171/172/176 ALL shared this blind
  spot. Reverted (silent value-regression on 378, unchanged aggregate
  count). cyc177 = rec-group-span-aware iso-recursive equality (retain
  `(rec …)` spans at decode + positional intra-group / canonical-id
  inter-group comparison); the plumbing is verified-correct and re-applies
  with it. See the new "cyc176 RESULT" section.
- 2026-05-29 — **Phase-10b LANDED (cyc177, `5c41c273`, gc 345→348).**
  `sections.canonicalEqual` implements Wasm 3.0 GC §3.3 iso-recursive
  equality: `decodeTypes` records each type's `(rec …)` span (`rec_span`);
  equality compares whole rec groups with concrete refs resolved
  POSITIONALLY intra-group / by canonical equality inter-group (the
  intra-vs-inter distinction the flat cyc171/172/176 versions lacked —
  well-founded via strictly-descending inter-group recursion, no depth
  hack). It drives BOTH the validator concrete→concrete OR-arm AND the
  `materialiseGcTypes` equivalence-class `canonical_ids`. Funcref RTT:
  `FuncEntity.raw_typeidx` (new field, both instantiate paths) resolved in
  `gcRefMatchesNonNull` when the target type's kind is func. Verified:
  ref.test-on-funcref 348/360 → 1, module 378 → 0 (no regression), gc
  invalid HELD 57, all proposals exact, exit 0, 0 panics. D-198 core
  discharged; residual = 2 type-subtyping FAILsetup (within-module
  supertype-declaration conformance — a distinct path, cyc178).
