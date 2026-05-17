# Before filing a new debt row, grep `.dev/debt.md` for the same bug class

- **Date**: 2026-05-18
- **Keywords**: debt ledger, dedup, D-143, D-126, dual-view table storage, hypothesis enumeration, Step 0.5 barrier-dissolution
- **Citing**: `c75343dc` (D-143 absorbed into D-126), `1753fc63` (cycle-1 hypothesis enumeration that should have caught the dup)

## Observation

During γ-4 probe investigation (2026-05-18), the autonomous loop
filed **D-143** to track "cross-module routing gaps — 113
functional FAILs surfaced when `hasUnbindableImports` is
relaxed". Cycle-1 hypothesis enumeration named "importer-side
elem segment funcref-encoding gap" as LEADING. Cycle-2 bisect
against `table_copy/table_copy.2.wasm` rejected H1 and
identified the **dual-view table-0 storage gap** as the actual
root cause.

After committing D-143's cycle-2 deposit (`c0cdcb34`), a routine
`grep` of `.dev/debt.md` for "table.copy" / "post-mutation"
surfaced **D-126** — filed 2026-05-16 — documenting the
**exact same bug class** with the **exact same root cause
description** ("the legacy table-0 fast-path
`JitRuntime.funcptr_base` / `typeidx_base` stay stale after
`table.copy`/`table.init`"). D-143 was a duplicate of D-126
the whole time; cycle-1 + cycle-2 investigation re-derived
information already on the ledger.

D-143 was closed `c75343dc` as an absorption into D-126; the
γ-4-exposed evidence (113 FAIL breakdown + minimal repro
`table_copy.2.wasm`) was merged into D-126's row body.

## Why the dup happened

The cycle-1 framing ("cross-module routing gaps") didn't
overlap textually with D-126's framing ("`bulk.wast`
call_indirect post-`table.copy` returns stale entries").
Different fixture families (table_copy/ref_func/imports vs
bulk.wast) + different exposure mechanism (γ-4 relax vs
d-50 trial-enable) hid the shared root cause. The
`/continue` Step 0.5 barrier-dissolution check walks
`Status: blocked-by:` rows but doesn't currently sweep
`Status: now` rows for class-overlap with newly-discovered
bugs.

## Discipline to internalise

**Before filing any new `D-NNN` row in `.dev/debt.md`**:

1. Grep `.dev/debt.md` for the affected source file / function
   names. E.g. for D-143: `grep "op_table.zig\|emitTableCopy\|
   funcptr_base\|tables_ptr"` would have hit D-126.
2. Grep for the symptom keyword (e.g. "stale" / "post-mutation"
   / "call_indirect"). For D-143 / D-126, "post-mutation"
   would match D-126's body verbatim.
3. If a candidate row exists, **update it with the new
   evidence** instead of opening a fresh row. The candidate
   row may have a stale `Last reviewed` date and a
   too-narrow framing — refresh both. The shared root cause
   is the consolidating signal.
4. Only after the grep returns no overlap should a new
   `D-NNN` row open.

This complements (does not replace) the existing
`/continue` Step 0.5 barrier-dissolution check, which sweeps
`blocked-by:` rows for unblocked barriers. The dedup grep is
for `now`-status rows that might overlap with a newly-
discovered bug.

## What this case taught about hypothesis enumeration

The cycle-1 hypothesis list per
`.claude/rules/hypothesis_enumeration.md` was disciplined —
each H had a predicted signature + distinguishing probe.
Cycle-2 correctly rejected H1 + H2 + H3 and identified the
real cause as H4 (dual-view storage).

But the enumeration started from cycle-1's framing
("routing gap"), which was an inherited framing from the
γ-4 probe narrative. The framing carried over from the
chunk-defining handover without being challenged. A "framing
challenge" step before hypothesis enumeration ("is this bug
already known by a different name?") would have surfaced
D-126 immediately, saving cycle-1 + cycle-2's effort.

Suggested rule amendment (to
`.claude/rules/hypothesis_enumeration.md`): add a
"framing challenge" line as step 0 of the enumeration —
"grep existing debt + lessons for the bug class before
enumerating hypotheses". Future heisenbug-class
investigations follow that 4-step shape (challenge / probe /
reject / converge).

## Related

- `2026-05-04-narrative-claim-vs-landed-state.md` — a
  related discipline gap (narrative claims drift from git
  state); the dedup grep is the prevention pattern for the
  debt-ledger flavour of the same failure mode.
- `2026-05-17-gamma3d-dispatch-write-segv-bisect.md` —
  D-142 cycle-6 investigation; the cycle-1 hypothesis
  enumeration for D-143 paralleled it but didn't dedup
  against D-126 the way D-142 was dedup-ed against the
  prior 5 hypotheses (which were correctly captured in
  D-142's row body).
