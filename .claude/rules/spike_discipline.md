---
description: "Spike discipline — when experimentation needs a spike directory (vs on-branch impl), the observable-behaviour rule for src/ commits, and the Status lifecycle for private/spikes/<slug>/. Absorbs former architectural_spike.md + spike_lifecycle.md + extended_challenge.md Step 4 spike option per ADR-0118 D3."
paths:
  - "src/**/*.zig"
  - "build.zig"
  - ".dev/decisions/**"
  - "private/spikes/**/README.md"
  - ".dev/lessons/**"
---

# Spike discipline

> Lean stub (ADR-0118 D2). Full detail / conditions / examples: [`../references/spike_discipline.md`](../references/spike_discipline.md).

## Invariant

- **§1 Spike** under `private/spikes/<slug>/` (gitignored) when a decision hinges on an unverified assumption. ≤ 1 day. Outcome → ADR or lesson; **never on-branch impl without an ADR**.
- **§2 Observable-behaviour**: every `src/` commit MUST have a same-commit test / fixture / caller exercising the diff. FORBIDDEN commit-message phrases (grep-enforced, verbatim):
  - `preparatory infra`
  - `wire-up next cycle`
  - `helper for <future>` (no same-cycle caller)
  - `lay the groundwork for` (no same-cycle test)
- **§3 Status** in `private/spikes/<slug>/README.md` ∈ `{running (≤14d), merged-into-prod (needs prod SHA), rejected (needs paired .dev/lessons/ rejection), archived}`.

## Enforcement

`scripts/audit_arch_spike_pattern.sh` (forbidden-phrase grep, last 14d) + `scripts/audit_spikes.sh` (README Status walk); both via `audit_scaffolding §G.4/§G.5`.

## Key cases

- §2 does NOT fire for: test infra, `.dev/` schema/ADR diffs, data files paired with a same-cycle consumer, `build.zig` targets exercised by the gate.
- No chosen path yet → can't commit on-branch → spike it.
- `running` > 14d → audit `soon`; `rejected` w/o lesson or `merged-into-prod` w/o SHA → `block`.
- D-153: 12-cycle on-branch spike, unobservable until the flip → 6 regressions.

Full detail: [`../references/spike_discipline.md`](../references/spike_discipline.md).
