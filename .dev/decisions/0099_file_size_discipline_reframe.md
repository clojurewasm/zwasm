# 0099 — File-size discipline reframe: smell-detector, not metric

- **Status**: Accepted
- **Date**: 2026-05-21
- **Author**: post-D-141 retrospective
- **Tags**: scaffolding, file_size_check, ROADMAP-§A2, discipline, reframe
- **Supersedes-portion-of**: ADR-0023 §A2 narrative (cap rationale); reinforces ADR-0063 (EXEMPT marker)
- **Amends**: ROADMAP §A2; `.claude/skills/audit_scaffolding/CHECKS.md` §J
- **Backs-out**: ADR-0095, ADR-0096, ADR-0097 (see paired retrospective ADR-0100)

## Context

`scripts/file_size_check.sh` enforces a 1000-line **soft cap** (WARN) and 2000-line **hard cap** (gate-fail). The cap was installed at ADR-0023 (2026-05-04) as a **smell detector** — "a file > N lines usually means 2+ concerns". ADR-0063 (2026-05-17) reinforced this for the hard cap: "the heuristic is a false positive for uniform-pattern catalogs; the EXEMPT marker explicitly surfaces the design choice."

In the §9.12-F D-141 sweep (2026-05-21), 15 ADRs landed extractions over a single day. Retrospective review (private/file-size-reform/02-adr-grading.md) identified:

- **11 of 15 extractions: defensible** — pure-data dominance (P2), spec-defined sub-language (P1), or independent change cadence with deep interface (P3)
- **3 of 15 extractions: defensible but borderline** (ADR-0083, 0089, 0098) — tie-breaker: spec axis + SIBLING-PUB managed
- **3 of 15 extractions: not defensible** (ADR-0095, 0096, 0097) — split was forced at a boundary that required private-helper pub-leak (N2) AND created cross-file circular dependency on helpers (N1) OR produced a shallow module (N3)

Root cause of the drift:
1. The soft cap WARN was treated as a forcing function (same as hard cap), but its original purpose was *signal*, not *gate*
2. The discipline had no formal "valid extraction" criterion; the lesson `2026-05-21-pure-data-extraction-via-reexport.md` covered only the Pure-data case
3. No script checked split quality (circular helper imports, pub-leaks, hub emptiness, test dup)
4. The autonomous loop, given a list of "files over soft cap," interpreted the task as "make this list empty"

## Decision

### D1 — Reframe the soft cap

**Soft cap (1000 LOC) is a smell detector, not a metric to drive to zero.**

When `file_size_check.sh` emits `WARN: <file> (<N> lines)`:
- Investigate whether the file exhibits one or more design smells (mixed concerns, complex internal coupling, multiple change axes)
- If yes: extract per ADR-grade design (per D2 below)
- If no: declare `// FILE-SIZE-EXEMPT: <smell-absence rationale> (per ADR-0099)` on lines 1-5 of the file, citing this ADR

The EXEMPT marker remains the existing mechanism (ADR-0063) but its applicability extends:
- Before ADR-0099: EXEMPT was for "uniform-pattern catalogs > 2000 LOC"
- After ADR-0099: EXEMPT applies to any soft-cap-WARN file when no design smell is present

### D2 — Formal "valid extraction" criterion

A file-size-driven extraction MUST satisfy ≥ 1 positive condition AND trigger 0 negative conditions (with tie-breaker for managed cases).

#### Positive conditions (justify extraction)

**P1 — Spec-defined closed sub-language**
- Extracted module corresponds to a spec section (Wasm proposal, ABI class, ISA family)
- AND substantive code ≥ 300 LOC (not counting tests/imports/comments)
- Examples: validator_simd (Wasm SIMD), inst_fp (AAPCS FP class)

**P2 — Pure-data dominance**
- Single declaration block ≥ 40% of file LOC
- Block has no methods, no internal state, no helpers used by the rest of the file
- Examples: zir_ops.zig, dispatch_collector_ops.zig

**P3 — Independent change cadence + deep interface**
- Git log shows the part changes in commits disjoint from rest of parent
  (advisory — if extraction is recent and history is < 6 months, substitute
  with structural evidence: clean narrow interface + visible independent
  purpose)
- AND extracted module has ≥ 3 public symbols OR 1 deep operation (compute/dispatch/lower)
- AND consumed by ≥ 2 external callers OR 1 caller with ≥ 10 use-sites
  (substantial single-caller permitted, e.g., ADR-0093 op_control_merge_mov)
- Examples: regalloc_compute (LSRA algorithm), compile_init (post-instantiate helpers)

**P4 — Test surface isolation (corroborating, not sufficient alone)**
- Child's tests do not import parent's fixtures/helpers
- Useful as confirming signal

#### Negative conditions (reject extraction)

**N1 — Helper-circular import**
- Child uses `parent.<helper_fn>` (NOT just `parent.<Type>` — types are cheap)
- Helper was private in parent before extraction
- → split at wrong boundary
- **Test-context carve-out**: calls inside `test "..." { ... }` blocks are
  informational only. Round-trip property tests (e.g., child's tests call
  parent.verify() to validate child's output) are intentional and not
  rejection-grounds. The script flags them but reviewers accept.

**N2 — Forced pub-leak of helper function**
- Extraction required `pub` on a previously-private function
- Function is non-test code
- Acceptable only when paired with SIBLING-PUB marker (ADR-0094) AND P1 trigger

**N3 — Shallow module**
- Substantive code < 100 LOC
- No P1 (spec-axis) qualification
- → Ousterhout-class anti-pattern

**N4 — Test dup or fixture pub-leak**
- Test helper duplicated across child/parent (body > 5 LOC) OR test fixture pub-ified
- Indicates test surfaces aren't actually independent

#### Tie-breaker

Both ≥ 1 positive AND ≥ 1 negative:
1. P1 + N2 (managed by SIBLING-PUB) → **ACCEPT**
2. P3 + N1-type-only → **ACCEPT**
3. Otherwise → **REJECT** or **redesign** (e.g., extract shared helpers to a separate utility module FIRST, then re-evaluate)

### D3 — Process: ADR template requirement

Every file-size-driven extraction ADR must:
1. Include a "Conditions check" section listing which P/N conditions fire
2. If any N fires, document the tie-breaker rationale OR redesign
3. If proposing extraction without ≥ 1 P, the ADR is rejected at review

### D4 — Enforcement

`scripts/check_split_smell.sh` (new) runs as informational gate (NOT --gate):
- N1 detection: grep child files for `parent.<lowercaseId>(` patterns where `<lowercaseId>` matches a function name
- N2 detection: cross-reference recent `pub fn` additions with extraction commits
- N3 detection: wc on substantive code per file
- N4 detection: grep for duplicated `fn test*` names across siblings

Output: informational findings — surfaces split-smells without gating commits. This preserves ADR-0063's "smell detector, not metric" intent at the *split-quality* level too.

### D5 — Retrospective application

For each shipped ADR 0079-0098, apply D2 conditions. ADRs that REJECT under D2 are rollback candidates. Rollback decision is per ADR (see ADR-0100).

## Alternatives

1. **Drop the soft cap entirely** — Rejected. Loses the smell-detection value. ADR-0063 already preserves the discipline correctly; we just need to apply it consistently.

2. **Raise the soft cap to 1500 or 2000** — Rejected. Arbitrary number-tuning; doesn't address root cause (no "valid extraction" criterion).

3. **Forbid all extractions for D-141** — Rejected. Throws out the 11+3 legitimate extractions.

4. **Pure-data lesson alone as discipline** — Rejected. Doesn't cover cross-file struct method (validator_simd shape) or deep-module extraction (regalloc_compute).

## Consequences

### Positive
- Restores ADR-0063's original intent: smell detection > metric satisfaction
- 4+4 mechanical conditions reduce judgment burden on future cycles
- `check_split_smell.sh` catches drift early (informational only)
- D-141 sweep work that passed D2 stays; the 3 invalid extractions get rolled back

### Negative
- Three already-shipped ADRs (0095, 0096, 0097) need rollback (paired ADR-0100)
- ADR template gains "Conditions check" section — modest authoring overhead
- "P1 spec axis" still requires human judgment ("is this a real spec axis?") — but explicit

### Neutral
- Existing EXEMPT marker (ADR-0063) mechanism unchanged; just broader applicability
- Existing audit_scaffolding §J unchanged for hard-cap; soft-cap section §J.1 amended to reflect smell-detector intent

## References

- ADR-0023 §A2 (cap installation, 2026-05-04)
- ADR-0063 (EXEMPT marker for hard-cap false positives, 2026-05-17)
- ADR-0094 (SIBLING-PUB marker for cross-file struct method, 2026-05-21)
- Lesson `.dev/lessons/2026-05-21-pure-data-extraction-via-reexport.md` (covered case; amended same commit to clarify scope)
- Lesson `.dev/lessons/2026-05-21-file-size-cap-as-smell-detector-not-metric.md` (Cycle 6 retrospective)
- John Ousterhout, *A Philosophy of Software Design*: "Length by itself is rarely a good reason for splitting up a method." Deep modules > shallow modules.
- Connascence taxonomy (Page-Jones): connascence-of-name (types) < connascence-of-meaning (helpers)

## Revision history

- 2026-05-21 — Initial draft landed at Cycle 1 of file-size discipline reform (private/file-size-reform/04-adr-0099-draft.md)
- 2026-05-24 — **Amendment**: per-file cap override via `(cap=N)` suffix in `FILE-SIZE-EXEMPT` marker. User-decided 2026-05-24 in lieu of ADR-0108's CATALOG-EXEMPT new tier (ADR-0108 Withdrawn). Rationale: of the 21 EXEMPT files, only entry.zig (2500 LOC, monotonic growth with Wasm signature shapes) presses the exempt-cap; all others have ≥ 400 LOC headroom. A narrow per-file mechanism is structurally simpler than a new global tier and preserves smell-detection discipline for non-catalog files. Mechanism: optional `(cap=N)` token anywhere in the marker comment; N must be > `EXEMPT_CAP` (2500); script (`scripts/file_size_check.sh`) parses + raises effective hard cap to N for that file only. Today's only site: `src/engine/codegen/shared/entry.zig` at cap=3000 (D-168 close). Removal condition: when entry.zig migrates to comptime metaprogramming catalog (Phase 12+ post-Wasm-3.0), drop the (cap=3000) suffix.
- 2026-05-29 — **Amendment**: extend the `(cap=N)` mechanism to two more sites that share entry.zig's monotonic-growth-with-an-external-axis shape, and raise `src/validate/validator.zig` from cap=3000 to **cap=3200** (now 3004 LOC at 10.G cycle 158). Rationale: the validator is a P1 spec-defined single-pass walker whose own marker already declares it "intrinsically singular (splitting would create artificial seams across an unsplittable algorithm)" — the GC/EH/funcref proposal handlers (`opStruct*`/`opArray*`/`opRefTest`/`opRefCast`/`opRefEq`/`opBrOnCast`, ~470 contiguous LOC at 1469–2061) all consume the shared type-stack + control-stack machinery (`popExpect`/`pushType`/`subtypeCtx`/`popArrayRef` + the value/control stacks). Extracting them to a sibling would force ~15-20 private fields/helpers `pub` (N2 forced-pub-leak), proving the seam is artificial. The external axis here is **Wasm proposal coverage**: validator.zig grows monotonically as each proposal's static type rules land, exactly like entry.zig grows with signature shapes. `src/api/instance.zig` (2992) is the third such site (C-ABI surface growing with the public API). 3200 gives ~200 LOC headroom; if a future proposal pushes past 3200 the marker forces a re-examination (the cap is the forcing function, not a blank cheque). Removal condition: when Wasm proposal intake stabilises (post-Wasm-3.0 GC/EH complete) AND a non-pub-leaking extraction is demonstrated, drop back toward 2500.
- 2026-05-29 — **Amendment**: raise `src/api/instance.zig` from cap=3000 to **cap=3200** (now 3043 LOC at 10.G cycle 174). The prior amendment (above) already flagged this file as the third monotonic-growth-with-an-external-axis site; cyc174 added Wasm start-section execution (`findStartFuncIdx` + the post-data-init invoke + a factored `failBuiltInstance` teardown helper, ~51 LOC net) inside `instantiateInternal`. This is a **runtime-feature add** (the §4.5.4 start step that was validated-but-never-executed), NOT C-ABI accessor bloat, so the file's own marker note about a D-171 "tighten/restructure if growth continues past 3000" path does not apply — the growth is not the accessor surface. The file's marker P3 evaluation (`api_instance_audit.md` §9.12-G (c)) already concluded no separable subsystem exists, so per §D2 the sanctioned outcome is a cap raise, mirroring the validator.zig cyc158 raise. 3200 keeps ~157 LOC headroom; the D-171 restructure path remains the response to a *genuine* separable subsystem, not to feature growth. Removal condition: same as the validator.zig site (proposal/feature intake stabilises AND a non-pub-leaking extraction is demonstrated).
- 2026-06-13 — **Amendment**: raise `src/api/instance.zig` from cap=3300 to **cap=3400** (3324 LOC at ADR-0184 step 1+2). The add is the engine-owned `std.Io.Threaded` plumbing (ADR-0184: `wasm_engine_new` Threaded ownership + `engineIo` + `zwasm_store_set_wasi` Host.io wiring + the `instantiateInternal` pending-preopen materialization hook) plus its tests — a **runtime-feature add** of the cyc174 class (start-section execution), NOT accessor bloat, so the same §D2 P3 "no separable subsystem" evaluation applies. 3400 keeps ~76 LOC headroom (deliberately tight). Removal condition unchanged (D-171-class separable subsystem appears, or feature intake stabilises AND a non-pub-leaking extraction is demonstrated).
- 2026-05-30 — **Amendment**: raise `src/validate/validator.zig` from cap=3200 to **cap=3300** (3204 LOC at 10.Y cyc195). This session added three module-level validation features to the file's *file-scope* (non-method) helper region: `validateGlobalInits`+`constExprResultType` (cyc190 global-init type-check), `funcTypeImportCompatible` (cyc192 cross-module import subtyping), non-null-local definite-assignment (cyc195). UNLIKE the cyc158 raise (which justified "intrinsically singular" for the GC opcode *handlers* consuming the shared type-stack), these are file-scope module-level validators that do NOT touch the Validator instance's private stacks — a genuinely separable "module-level + GC validation" sub-language (P1, now ≳500 LOC: `validateTypeSection`/`validateGlobalInits`/`constExprResultType`/`funcTypeImportCompatible`/`gcValTypeSubtype` family). So "intrinsically singular" no longer covers the whole file. Sanctioned outcome = a *stopgap* raise (3300, ~96 LOC headroom — deliberately tight as a forcing function) PAIRED with **D-204**: next time the file presses the cap, EXTRACT the file-scope module-validation helpers to a `validate/` sibling instead of raising again. Removal condition: D-204 extraction lands (drop back toward 2500–3000).
- 2026-07-03 — **Amendment (posture reframe → ADVISORY; user-ratified, scaffolding-necessity audit §B.1)**: post-v2.0.0 maintenance, the hard cap (2000) is DEMOTED from a commit-BLOCK to an advisory WARN. `scripts/file_size_check.sh --gate` no longer exits 1 on any size — it only prints WARN/EXEMPT lines (always exit 0). Rationale: (1) the smell-detector premise — catching AI over-generation during the rapid from-scratch build — ended when the campaign completed; the pressure files are all irreducible catalogs / spec-walkers already investigated (`instance.zig` 4078 UNCAPPED, `validator.zig` 3392, `entry.zig` 3161, …). (2) the check was ALREADY local-only: CI's `ci_gate.sh` never ran `file_size_check`, so the hard-BLOCK only ever bit local pre-commit — this codifies reality rather than changing merge safety. The FILE-SIZE-EXEMPT marker mechanism is RETAINED purely as a WARN-suppressor (a marked file = "known-large, investigated" → no WARN noise; an unmarked over-cap file = flagged for a look). The `(cap=N)` / `(cap=UNCAPPED)` overrides remain valid but are no longer load-bearing (nothing blocks). EXEMPT-marker changelog prose may be trimmed to one line + this ADR ref (the per-file raise-log duplicates this Revision history). Soft cap (1000) WARN unchanged.
