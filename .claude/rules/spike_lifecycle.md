---
description: "Spike lifecycle discipline — Status management for private/spikes/<slug>/ + mandatory lesson when rejected/archived + audit flag when running >14d. Extracted and reinforced from `extended_challenge.md` Step 4."
paths:
  - "private/spikes/**/README.md"
  - ".dev/lessons/**"
---

# Spike lifecycle

> **Status**: landed at §9.12-A (2026-05-19). Enforced by
> `scripts/audit_spikes.sh` (existing) + `audit_scaffolding §G.4`
> (existing; reject-lesson landing check).

## The rule

A `private/spikes/<slug>/` directory **MUST have a lifecycle Status**:

| Status | Meaning |
|---|---|
| `running` | In progress. Maximum 14 days (audit flag) |
| `merged-into-prod` | Folded into the production implementation. Production commit SHA required |
| `rejected` | Not adopted. Conclusion MUST be recorded in `.dev/lessons/YYYY-MM-DD-<slug>-rejected.md` |
| `archived` | Past rejection; spike dir remains but no activity |

Each spike's README.md MUST declare its Status explicitly in the frontmatter or at the top. Canonical shape (matches `scripts/new_spike.sh` output — use it for new spikes):

```markdown
# Spike: q3-zig-inline-switch

**Created**: 2026-05-19 (@ <sha>)
**Status**: running
**Outcome**: <TBD>
**Hypothesis**: Does a 581-tag `inline switch` hit a Zig 0.16 compile-time wall?
```

`scripts/audit_spikes.sh` accepts `**Started**:` / `**Date**:` as
synonyms for the creation-date field and the `- **Status**:`
bullet-list form, for backward compatibility with historical
spike READMEs (q3-* cohort used the bullet form + `Date`). New
spikes should use `scripts/new_spike.sh` and take the canonical
shape above.

## Why

In the D-134 (Rosetta heisenbug) investigation, if the 5 cycles of hypothesis
rejection had not been recorded, root-cause identification at cycle 6 would
not have been possible. If a spike is discarded without a record, future-you
or the next session pays the same trial cost again.

The "spare no effort" discipline is not about "attempting experiments" but
about "recording experimental results".

## Enforcement

- `scripts/audit_spikes.sh` runs as part of the periodic audit cadence
  and per `audit_scaffolding §G.4`.
- Findings:
  - `running` > 14d → `soon` audit finding.
  - `rejected` without a paired `lessons/<YYYY-MM-DD>-<slug>-rejected.md`
    → `block` audit finding (= cannot Phase-close until resolved).
  - `merged-into-prod` without a cited production SHA → `block`.
- The 3 spikes landed in §9.12-pre (`q3-zig-inline-switch`,
  `q3-interp-dispatch-bench`, `q3-build-option-dce-poc`) all have
  `merged-into-prod` Status with their measurements absorbed into
  ADR-0073. They serve as the reference template for future spikes.

## Reviewer checklist

When reviewing a `private/spikes/<slug>/` addition or change:

- [ ] Does `README.md` declare a Status from {running, merged-into-prod,
      rejected, archived}?
- [ ] If `running`, is the Started date present and < 14d ago?
- [ ] If `merged-into-prod`, does the README cite the production SHA?
- [ ] If `rejected`, does the paired lesson exist at
      `.dev/lessons/<YYYY-MM-DD>-<slug>-rejected.md`?

## Migration to lesson on reject

```
1. In the spike dir, record `Status: rejected` + Outcome
2. Land `.dev/lessons/YYYY-MM-DD-<spike-slug>-rejected.md`
   - Carefully cover: what was tried / why it was rejected / what was learned
3. Move the spike dir to `private/spikes/archive/<slug>/` (optional)
4. State the rejection explicitly in the commit message
```

## Related

- ADR-0071 §Q3 (3 spikes adopted: q3-zig-inline-switch / q3-interp-dispatch-bench /
  q3-build-option-dce-poc)
- Master plan §7.5
- `.claude/rules/extended_challenge.md` Step 4 (spike-driven alternative exploration)
- `.claude/rules/lessons_vs_adr.md`
