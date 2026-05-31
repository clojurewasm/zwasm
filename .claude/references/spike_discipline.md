# Spike discipline — full detail

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → read on demand only). Stub: [`../rules/spike_discipline.md`](../rules/spike_discipline.md).

Unified rule covering three concerns previously split across
`architectural_spike.md`, `spike_lifecycle.md`, and
`extended_challenge.md` Step 4:

1. **When to spike** (vs commit directly on `zwasm-from-scratch`).
2. **Observable-behaviour rule** for `src/` commits — what makes
   a diff NOT a spike.
3. **Status lifecycle** for `private/spikes/<slug>/`.

## §1 — When to spike (Step 4 case)

Reach for a spike under `private/spikes/<slug>/` (gitignored) when:

- An in-flight decision hinges on an unverified assumption (encoder
  output / type-system behaviour / hot-loop timing / runtime
  semantics).
- The cost of 5 min search / 30 min spike is much less than the
  cost of landing wrong-shape design that later needs re-derivation.
- The experiment doesn't yet have a chosen path → can't commit
  on-branch without violating §2.

Bounds: ≤ 1 day per spike; outcome → ADR (Accepted-as-merged-into-prod
OR Rejected) OR observational lesson; **never as on-branch implementation
without an ADR**.

## §2 — Observable-behaviour rule for `src/` commits

A code commit on `zwasm-from-scratch` MUST have an **observable
behaviour point** that exercises the diff. Forbidden:

- Add helper / type / shape / signature change to `src/` and defer
  the call-site wire-up to a later cycle.
- "Preparatory infra" / "lay the groundwork for" / "wire up next
  chunk" commits without same-commit test / fixture / caller exercising
  the new path.

Qualifying observable points (≥ 1 required):

1. New or updated test under `test/` exercises the path (green).
2. Existing spec fixture covers it (cite the fixture).
3. Pure rename / signature unification where caller-side update +
   existing test coverage are in the same commit.
4. Behaviour-neutral refactor where test-all neutrality (green pre+post)
   is the assertion.

If none hold → diff is an on-branch spike → move to
`private/spikes/<slug>/`.

### Forbidden commit-message phrases (grep-enforced)

- `preparatory infra` — use `private/spikes/`
- `wire-up next cycle` — wire-up belongs in the same cycle
- `helper for <future>` without a same-cycle caller
- `lay the groundwork for` without a same-cycle test

### When §2 does NOT fire

- Test infrastructure (fixture loader, spec runner helpers) —
  observed by existing tests passing differently.
- Schema / ADR amendments under `.dev/` — docs-only diffs exempt.
- Pure data files paired with a same-cycle consuming test/runner.
- `build.zig` additions where the build target is exercised by test gate.

## §3 — `private/spikes/<slug>/` Status lifecycle

Each spike dir's `README.md` MUST declare Status from:

| Status | Meaning |
|---|---|
| `running` | In progress. ≤ 14 days (audit flag at threshold) |
| `merged-into-prod` | Folded into production. Production commit SHA required in README |
| `rejected` | Not adopted. Conclusion MUST land in `.dev/lessons/YYYY-MM-DD-<slug>-rejected.md` |
| `archived` | Past rejection; spike dir remains but no activity |

Canonical README shape (matches `scripts/new_spike.sh` output):

```markdown
# Spike: <slug>

**Created**: YYYY-MM-DD (@ <sha>)
**Status**: running
**Outcome**: <TBD>
**Hypothesis**: <question being investigated>
```

`scripts/audit_spikes.sh` accepts `**Started**:` / `**Date**:` as
synonyms (historical compatibility) and the `- **Status**:` bullet form.

### Reject → lesson migration

```text
1. In spike dir: record `Status: rejected` + Outcome
2. Land .dev/lessons/YYYY-MM-DD-<slug>-rejected.md
   covering: what was tried / why rejected / what was learned
3. (optional) Move spike dir to private/spikes/archive/<slug>/
4. State rejection explicitly in commit message
```

## Why this rule exists

- **D-153 (12-cycle on-branch spike)**: B146–B158 landed catalog +
  predicate + validator shape changes onto `zwasm-from-scratch` without
  ever flipping the SKIP-CROSS-MODULE-IMPORTS count. B156 wire-up flip
  → 6 regressions → reverted. The infra was structurally correct but
  unobservable until the flip. **Lesson**: on-branch spike work pays
  green-gate cost (test/lint/file-size) but produces zero behaviour
  delta. Same experimentation in `private/spikes/d153/` would have
  surfaced the validator_globals shape bug at hour 1 instead of cycle 12.
- **D-134 (Rosetta heisenbug, 6-cycle bisect)**: 5 cycles of hypothesis
  rejection. If not recorded as spikes with rejection-lessons, cycle 6
  would have re-walked the rejected paths.

The discipline is not "attempt experiments" but **"record experimental
results"** — including the Status as it transitions.

## Audit hooks

- `scripts/audit_arch_spike_pattern.sh` — greps last 14 days of commits
  for forbidden phrases ("preparatory infra", "wire-up next cycle"
  etc.); flags any commit lacking ADR / spike-dir pairing.
- `scripts/audit_spikes.sh` — walks `private/spikes/*/README.md`:
  - `running` > 14d → `soon` finding
  - `rejected` without paired lesson → `block` (cannot Phase-close)
  - `merged-into-prod` without cited SHA → `block`
- `audit_scaffolding §G.4` + `§G.5` invoke both periodically.

## Cross-references

- [`no_workaround.md`](no_workaround.md) — root-cause discipline.
  Spike pattern + workaround pattern are the same anti-pattern in
  different costumes.
- [`extended_challenge.md`](extended_challenge.md) — the 3-step
  procedure when stuck. Spike (Step 4) is the highest-level fallback
  before declaring blocked.
- [`LOOP.md`](../../skills/continue/LOOP.md) §"Chunk types" — defines
  `architectural`-typed chunks + 3-cycle measurable-progress cap.
  §2 is the commit-time enforcement that supports the cap.

## References

- `.dev/lessons/2026-05-20-refactor-tradeoffs-honest-accounting.md`
  (D-153 retrospective)
- `.dev/lessons/2026-05-17-gamma3d-dispatch-write-segv-bisect.md`
  (D-134 / D-142 root-cause discipline)
- ADR-0071 §Q3 (3 spikes that merged into prod — reference template)
- `.dev/archive/phase9/phase9_structural_debt_close_plan.md` §6 (d) —
  the close-plan step that ordered the original architectural_spike rule
- Master plan §7.5
