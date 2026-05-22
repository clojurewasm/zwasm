# 0102 — Reframe §9.12-F exit from "active rows < 15" to "phase-9-eligible cohort substantially addressed"

- **Status**: Accepted
- **Date**: 2026-05-22
- **Author**: Shota Kudo (via `/continue` autonomous loop, WA track of `.dev/phase9_13_0_close_plan.md`)
- **Tags**: phase-9, debt, exit-criterion, scope

## Context

ROADMAP §9.12-F currently reads:

> **Phase-9-eligible debt cohort** per [`phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) §5.3. D-094 (x86_64 multi-result indirect-result-buffer; verify dissolution via D-140/D-148 chain or discharge); D-090 (lower.zig type-stack walker); D-062 (arm64 v128 9th+ stack overflow); D-141 (file_size_check WARN; mostly dissolved by Q3 C adoption, individual ADRs for the remainder); D-081 (emit.zig source split; verify dissolution by Q3 C); D-055 (emit_test_*.zig migration). **Exit: debt active rows < 15.**

The numeric `< 15` exit criterion has become a poor proxy for the
phase's actual completion semantics. Current state at HEAD
`1b4a5b5a`:

- `.dev/debt.md` has 19 active rows.
- Of those 19:
  - **4 are §9.13-0 Cat IV** (D-022 / D-028 / D-084 / D-136). These
    are tracked as their own row in §9 (§9.13-0) and have a
    distinct execution plan (`.dev/phase9_13_0_close_plan.md`).
    Counting them against §9.12-F double-counts: closing them is
    §9.13-0's exit, not §9.12-F's.
  - **2 are trigger-not-fired** (D-094 x86_64 multi-result
    MEMORY-class indirect-result-buffer; D-062 arm64 9th+ v128
    stack-arg overflow). Both rows have `Status: blocked-by:`
    naming a concrete external event (= a real workload demanding
    the unimplemented surface) per `.dev/debt.md` discipline. No
    Phase-9-scope workload exercises them; forcing discharge in
    Phase 9 would require speculative impl without spec / bench
    pressure — the exact failure mode `extended_challenge.md` Step
    1 (= "is it actually needed?") rejects.
  - **13 are deferred to Phase 10+** under named structural
    barriers (Phase 10 Track-D link-time checks; Phase 11
    embenchen full-perf-suite; Phase 14 concurrency; v0.1.0 RC
    Zig facade; upstream Zig 0.16 backend bug for D-148; etc.).
    Each row's `blocked-by:` is testable in concrete terms per
    [`no_handover_predictions.md`](../../.claude/rules/no_handover_predictions.md).

The numeric bar `< 15` either (a) forces premature Phase 10+
work into Phase 9 (rejected: §9.12 was scoped specifically to
substrate cleanup, not Phase 10+ surface), or (b) is silently
soft-passed by interpreting "active rows" exclusive of the
§9.13-0 cohort (= the same reframe this ADR codifies, but
unwritten and therefore drift-prone). Either path is honest
only when the exit criterion names what it actually checks.

The original `< 15` bar was set in
`phase9_completion_master_plan.md` §5.3 as a coarse signal that
Phase-9-eligible cleanup had landed. Two events since dissolve
it as a measurement:

1. **ADR-0049 + ADR-0056 + ADR-0065 (2026-05-18 amends)** moved
   Cat IV from §9.9-IV to §9.13-0, creating a separate row for
   the 4 windowsmini-specific debts. The original count assumed
   they'd close inside §9.12.
2. **Phase 9's actual cleanup trajectory** — D-018 / D-081 /
   D-141 / D-090 / D-055 all closed via mechanical work (recent
   audits, sub-chunks under §9.12) without the count crossing
   `< 15`, because the parallel Phase 10+ deferral queue grew
   simultaneously as new Cat I+II+III work surfaced previously-
   invisible cross-module / link-time gaps.

## Decision

Amend ROADMAP §9.12-F's exit criterion to:

> **Exit**: phase-9-eligible debt cohort substantially addressed,
> defined as:
>
> - (a) §9.13-0 Cat IV debts (D-022 / D-028 / D-084 / D-136)
>   tracked separately under §9.13-0 (do not count against
>   §9.12-F);
> - (b) trigger-not-fired debts (D-094, D-062) carry
>   `Status: blocked-by: <named external event>` per `.dev/
>   debt.md` discipline — the named barrier is the testable
>   condition for flip to `now`;
> - (c) deferred-to-Phase-N debts carry an explicit Phase target
>   row in `.dev/debt.md`'s `blocked-by:` (Phase 10 / Phase 11 /
>   v0.1.0 RC / upstream-fix-pending);
> - (d) all rows enumerated in §9.12-F's body (D-094, D-090,
>   D-062, D-141, D-081, D-055) either closed or carry one of
>   (a)/(b)/(c).

The body-list in §9.12-F stays as the **scope marker** (= which
rows the §9.12 cohort was originally chartered to address). The
exit becomes a **per-row predicate** rather than an aggregate
count.

## Alternatives considered

### Alternative A — Hold the numeric bar (`< 15`)

- **Sketch**: keep `Exit: debt active rows < 15` and force
  closure of additional rows until the count drops below 15.
- **Why rejected**: forces premature Phase 10+ work into Phase
  9. The 13 Phase-10+ rows have named structural barriers that
  Phase 9 scope cannot dissolve (Phase 10 = Track-D link-time
  checks; Phase 11 = embenchen full-perf-suite + WASI envv;
  Phase 14 = concurrency; v0.1.0 RC = Zig facade; upstream Zig
  fix = D-148). Closing them in Phase 9 means either (i)
  speculative impl without workload pressure (rejected by
  `extended_challenge.md` Step 1), or (ii) artificially
  reclassifying as "non-debt" (rejected: dishonest and
  re-surfaces at Phase 10 boundary).

### Alternative B — Drop the criterion entirely

- **Sketch**: remove §9.12-F's exit line; rely on per-row body
  prose to indicate when §9.12 cleanup is done.
- **Why rejected**: loses Phase-close hygiene. §9.12 needs SOME
  testable exit to mark `[x]`; dropping it means the row never
  closes mechanically and accumulates indefinite scope creep.
  The per-row predicate (this ADR's Decision) preserves the
  hygiene without the false-precision of `< 15`.

### Alternative C — Re-baseline to `< N` where N reflects current Phase 10+ queue

- **Sketch**: pick N = (current active count) − (rows still
  expected to close in §9.12 cleanup) and use the new number
  as the bar.
- **Why rejected**: re-introduces the same drift failure mode at
  a new offset. Phase 10's Track-D inevitably surfaces more
  cross-module / link-time gaps (e.g. D-157 was filed at the
  ADR-0078 audit cycle 2026-05-21); each new structural
  observation grows the queue. A numeric bar must be re-tuned
  on every such event; a per-row predicate is stable across
  them.

### Alternative D — Migrate `Status` axis to encode Phase-eligibility

- **Sketch**: extend `.dev/debt.md`'s Status column with a
  `phase-target: N` field; §9.12-F's exit becomes "all
  phase-target ≤ 9 rows closed".
- **Why rejected**: orthogonal upgrade; not in §9.12 scope. The
  current `blocked-by: <Phase N> <barrier>` shape already
  encodes the same information. A schema migration would be its
  own ADR; this ADR can land independently.

## Consequences

### Positive

- §9.12-F exit becomes **testable per-row** rather than
  aggregate. A reviewer walking the §9.12-F body list +
  `.dev/debt.md` can mechanically verify each predicate.
- Removes the artificial pressure to either (i) force Phase 10+
  work into Phase 9 or (ii) silently reclassify rows. Both
  failure modes were observed in the §9.12 cleanup trajectory.
- Aligns §9.12-F's exit shape with §9.13-0 (which already uses
  a per-row close criterion: D-022 / D-028 / D-084 / D-136
  closed). The two phase-9 cleanup rows now share an exit
  shape.
- Codifies what was already happening informally — the
  §9.12-F → §9.13-0 split (ADR-0049 + ADR-0056 + ADR-0065
  2026-05-18 amends) implicitly reframed the Cat IV cohort
  out of §9.12-F; this ADR makes that consistent.

### Negative

- The exit criterion becomes prose-shaped, not number-shaped.
  Phase-close hygiene depends on `audit_scaffolding §F`'s
  debt-coherence walk (`now` rows discharged; `blocked-by:`
  barriers re-evaluated; `Last reviewed` dates fresh) rather
  than a `wc -l` count. This is already how Phase-close audits
  run in practice; the ADR doesn't add cost, but does make the
  audit's load-bearing role explicit.
- A future reviewer might prefer the simplicity of a numeric
  bar. The Alternative C analysis shows why numeric bars drift;
  reverting requires another ADR.

### Neutral / follow-ups

- §9.12-F body-list (D-094, D-090, D-062, D-141, D-081, D-055)
  stays as the scope marker. Some of those rows have already
  closed (D-090, D-141, D-081, D-055 per `.dev/debt.md`
  Discharged § at `02397144` / `5081d053` / `2f54f753` /
  `871c78e1` / `f79104bb`). After this ADR lands, the body-list
  should be refreshed to match current `.dev/debt.md` state
  (=  D-094, D-062 remaining, both `blocked-by:`).
- The same exit-shape ("per-row predicate over a named cohort")
  may apply to future Phase-close cleanup rows. Not codified
  here; if the pattern recurs, lift to ROADMAP §18's amendment
  policy or a new top-level rule.

## References

- ROADMAP §9.12-F (line ~1312) — the row being amended.
- ROADMAP §9.13-0 (line ~1316) — the sibling phase-9 cleanup
  row whose per-row close criterion this ADR aligns §9.12-F to.
- `.dev/phase9_completion_master_plan.md` §5.3 — original `< 15`
  source.
- `.dev/phase9_13_0_close_plan.md` §1 + §5/WA — execution plan
  for this ADR's drafting (WA track) and the Cat IV closure
  (§9.13-0 closure).
- `.dev/decisions/0049_*.md` — ADR-0049 (windowsmini gate
  deferral; created the §9.13-0 separation).
- `.dev/decisions/0056_*.md` — ADR-0056 (Phase 9 close-readiness
  4-category predicate; named Cat IV).
- `.dev/decisions/0065_*.md` — ADR-0065 (4-category boundary
  clarification; codified the §9.13-0 row move).
- `.dev/debt.md` (HEAD `1b4a5b5a`) — current active rows
  (19 total: 4 Cat IV, 2 trigger-not-fired, 13 Phase 10+).
- `.claude/rules/no_handover_predictions.md` — discipline
  this ADR honours (no numeric prediction about post-amend
  count).
- `.claude/rules/extended_challenge.md` Step 1 — rejection
  rationale for Alternative A.

## Revision history

| Date       | SHA         | Change                          |
|------------|-------------|----------------------------------|
| 2026-05-22 | `a6e3eb4f`| Status: Proposed → Accepted     |
