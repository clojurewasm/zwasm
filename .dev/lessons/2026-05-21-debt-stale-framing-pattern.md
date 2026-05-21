# Debt rows can outlive their framing without dissolving

**Date**: 2026-05-21
**Keywords**: D-018, D-081, D-090, D-141, D-055, ADR-0034, debt sweep, stale framing, barrier dissolution, /continue Step 0.5
**Citing**: `<backfill>` (lesson commit), §9.12-F discharges (`02397144` D-018, `871c78e1` D-055, `2f54f753` D-090, `5081d053` D-141, `f79104bb` D-081, `9457a4b6` ADR-0034 flip)

## The pattern

In a single §9.12-F discharge session, 5 debt rows + 1 annotated
ADR were closed. For each, the discovery shape was the same:
**the row's barrier text was stale relative to current reality**.
The actual structural state had moved past the framing without
anyone noticing.

Concrete cases this session:

- **D-018** "long-running cross-module call allocator pressure":
  framed as "verify via §9.12-H bench". §9.12-H ran; the bench
  fixture set didn't exercise the cross-module long-running
  pattern, but no anomalous arena bloat surfaced. Per the row's
  own discharge criterion ("no measurable pressure"), close.
- **D-081** "rename emit_test_int/float to strict
  `<source>_test.zig`": ADR-0081 (`emit_setup.zig` extraction)
  landed but didn't match the test names. Per ADR-0074 per-op-
  file pattern, the int/float emit content was absorbed across
  many per-op files; no single source file matches. Close via
  ADR-0054 amendment (grandfather clause).
- **D-090** "lower.zig needs parallel type-stack walker for
  untyped 0x1B select on non-i32": investigation showed the
  validator (`opSelect` line 1221-1227) already emits the
  resolved valtype byte to `out_select_types`; lower.zig
  (line 257-262) reads it and threads via `ins.extra` to emit
  dispatch. Production handles non-i32 untyped select correctly;
  fixtures (`select_f32_negzero` / `select_f64_negzero`) exist
  and pass.
- **D-141** "file_size_check WARN proliferation": ADR-0099 (D1)
  reframed the soft cap as a smell detector, but
  `scripts/file_size_check.sh` wasn't updated to honor the
  FILE-SIZE-EXEMPT marker in [SOFT, HARD] range. Script update
  + 14 EXEMPT markers drained WARN count 18 → 0.
- **ADR-0034** "JIT-execution sentinel; x86_64 deferred": D-055
  close at `871c78e1` landed the x86_64 inject. The "partial"
  annotation was stale.

## Why staleness happens

Three reinforcing factors:

1. **Barriers cite past state**, not present. When a row says
   "blocked-by §9.12-H bench" and §9.12-H runs, the row author
   may not re-read the row to reflect the outcome.
2. **Adjacent work dissolves barriers silently**. D-090's
   discharge trigger ("non-i32 select fixtures") fired when
   `test/edge_cases/p9/select_fp/` landed for an unrelated
   reason; the D-090 row author wasn't notified.
3. **Framing is initial-state**. D-081 framed "rename target
   needs successor ADR-0081" without anticipating that ADR-0074
   per-op-file pattern would absorb the int/float emit content
   in a way that made naming-correspondence moot.

## How `/continue` Step 0.5 caught it

The "barrier-dissolution check (unconditional, every resume)"
step in `/continue` worked as designed for all 5 cases. For
each row, the check walked: "is the named barrier still
testable + still failing?" When the answer was no (D-018 bench
ran; D-090 fixtures exist; D-081 ADR landed but doesn't
satisfy; D-141 script update sufficient), the row discharged.

The check was cheap (`grep | head` per row) but only fires when
the resume actually walks every row. The §9.12-F discharge
sweep was triggered by handover.md's "Next pickup" pointer to
this specific cohort; without that targeted re-read, the
staleness would have lingered.

## What to do differently

When framing a `blocked-by` barrier:

1. **Name the discharge condition in present-tense testable
   terms** — not "verify via §X.Y bench" but "the bench's RSS
   profile shows no anomalous arena bloat".
2. **Add a re-evaluation trigger** — "barrier dissolves when
   `<concrete event>` happens". If the row author already
   knows the future event, name it; future-self can grep.
3. **Re-walk the barrier text after every adjacent landing**.
   The Step 0.5 cycle catches this, but rows benefit from
   author-side updates too.

## Where this lesson applies next

The remaining 19 active rows include several that may share
this pattern:
- D-094 (multi-result indirect-result-buffer trigger not fired)
  — explicit trigger ("real workload demanding >2 same-class
  results"). Watch list.
- D-062 (arm64 v128 9th+ arg) — explicit trigger ("spec
  testsuite demand for ≥ 9 v128 params"). Watch list.
- D-079 (c_api Instance path v128 cross-module) — sub-gap (i)
  already discharged; sub-gap (ii) blocked on v0.1.0 RC scope.

For each of these, the right Step 0.5 action is: grep for the
trigger condition (fixture presence, workload existence) at
every resume. The fixture trigger may fire silently like the
D-090 case did.

## Related

- `.claude/skills/continue/SKILL.md` Step 0.5 (barrier-dissolution
  check) — the mechanism that caught all 5 cases this session.
- ADR-0050 (ADR / debt lifecycle) — debt-row hygiene framework.
- `.dev/lessons/2026-05-16-narrative-claim-vs-landed-state.md` —
  the sibling lesson about narrative drift in handover.
