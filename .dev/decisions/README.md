# Architecture Decision Records

> ADRs document **deviations from `.dev/ROADMAP.md` discovered during
> development**, not founding decisions. Founding decisions live in
> the ROADMAP itself (§1–§14). When the ROADMAP is found to be wrong
> or incomplete, follow [ROADMAP §18.2's four-step amendment](../ROADMAP.md#18-amendment-policy):
> (1) edit the ROADMAP in place, (2) open the ADR, (3) sync
> `handover.md`, (4) reference the ADR in the commit message.
>
> Skip ADRs for ephemeral choices ("not worth it right now") or for
> facts that are obvious from the code.
>
> See [`.claude/rules/lessons_vs_adr.md`](../../.claude/rules/lessons_vs_adr.md)
> for the ADR-vs-lesson decision tree. Use lessons (`.dev/lessons/`)
> for re-derivable observational notes that don't carry a load-bearing
> decision.

## Filename convention

`NNNN_<snake_slug>.md`

- `NNNN` — 4-digit sequential index, zero-padded
- `<snake_slug>` — short English identifier in snake_case
- `0000_template.md` — template (do not delete or renumber)
- `_DRAFT_<slug>.md` — placeholder while the ADR number is unconfirmed
  (see "Two-commit authoring" below)

## Required structure

Use [`0000_template.md`](./0000_template.md) as the starting point. Every
ADR has:

- **Status**: Proposed / Accepted / Superseded by NNNN / Deprecated /
  Demoted to `.dev/lessons/<file>` (see lessons-vs-ADR rule)
- **Context**: what motivated the decision (constraints, prior art)
- **Decision**: what was chosen
- **Alternatives considered**: what was rejected and why — keep
  rejected alternatives' rationale even when they don't survive
  amend cycles (this is what the Phase 6 Beta-funcref-encoding
  lesson taught us)
- **Consequences**: positive, negative, neutral
- **References**: ROADMAP §, related ADRs, lessons, external docs
- **Revision history** (footer, optional but recommended for ADRs
  that get amended): table of `Date | Commit | Summary` rows. SHA
  may be backfilled (see "Revision history" below).

## Lifecycle

- **Add**: when a load-bearing decision is made that **diverges from
  the ROADMAP**. Number = max(existing) + 1, or `_DRAFT_<slug>.md`
  if the canonical number isn't confirmed yet.
- **Supersede**: do not edit a historical ADR. Add a new one and mark
  the old one `Status: Superseded by NNNN`.
- **Reject after debate**: also add an ADR with `Status: Proposed →
  Rejected`. Records why the path was not taken.
- **Amend in place**: allowed for **the same decision evolving with
  newer evidence** (per ROADMAP §18). Add a Revision history row
  and keep the original Alternatives section's rationale intact —
  don't rewrite history into "we always meant this".
- **Demote**: if the ADR turns out to be observational, mark
  `Status: Demoted to .dev/lessons/<file>` and copy the content
  there. Don't delete an ADR with external citations.

## When to write an ADR

(See [`.claude/rules/lessons_vs_adr.md`](../../.claude/rules/lessons_vs_adr.md)
for the full decision tree.)

- Layer/contract changes (new register class, new ZIR op family that
  was not in the day-1 catalogue)
- IR shape changes (ZirInstr layout, ZirFunc field add/remove)
- C ABI surface changes (`zwasm.h` additions; `wasm.h` follows
  upstream)
- Phase order changes
- Allowing a benchmark regression (with magnitude + reason)
- Tier promotions (a previously deferred Wasm proposal entering scope)
- Any one-time trade-off that conflicts with a §2 principle but is
  justified

## When NOT to write an ADR

- Bug fixes
- Spelling / typo corrections
- Doc additions
- Refactors with no public API change
- Anything already documented in ROADMAP §1–§14 (founding decisions)
- Re-derivable observational learnings — write a **lesson**
  (`.dev/lessons/<YYYY-MM-DD>-<slug>.md`) instead

## Two-commit authoring (when the ADR number isn't yet known)

Sometimes you need to edit a load-bearing artefact (ROADMAP / handover
/ source) **before** the ADR's canonical number is confirmed — for
example, when the edit is the surfacing of a problem and the ADR
records its resolution. Use the two-commit pattern:

```
commit 1: edit ROADMAP / source / handover; reference _DRAFT_<slug>
commit 2: rename _DRAFT_<slug>.md → NNNN_<slug>.md; replace the
          DRAFT references with the confirmed NNNN
```

Both commits are tracked by `git log`. The DRAFT file lives in
`.dev/decisions/` next to its eventual home; renaming preserves
file identity for blame purposes.

This avoids the "edit → must commit → must produce SHA → edit
ADR with SHA → commit again" loop that produces churn and
forces premature numbering.

## Revision history

When an ADR is amended in place (per ROADMAP §18), add a footer:

```markdown
## Revision history

| Date       | Commit       | Summary                                  |
|------------|--------------|------------------------------------------|
| 2026-05-04 | `ffc0cf0`    | Initial Decision (Alpha funcref).        |
| 2026-05-04 | `<backfill>` | §3.γ rejected-alternatives expanded.     |
```

Rules:

- Add a row **for every amend that changes load-bearing content**
  (Decision, Alternatives, Consequences, removal conditions).
  Trivial edits (typo fixes, cross-ref refresh, code-style only)
  are not tracked.
- The Commit column may be `<backfill>` at write time; the
  `audit_scaffolding` skill checks for un-backfilled SHAs at
  phase boundaries and prints findings.
- The audit's job is enforcement — you don't need to "stop and
  re-commit just to fill the SHA" mid-amend; backfilling within
  the same phase cycle is fine.

## Citing lessons from ADRs

When an ADR's Decision was informed by a lesson (`.dev/lessons/
<file>`), cite it in the References section:

```markdown
## References

- ROADMAP §9.6 / 6.K
- Lesson: `.dev/lessons/2026-05-04-beta-funcref-encoding-rejected.md`
- Wasmtime: `crates/runtime/src/instance.rs` ...
```

If the lesson **promotes** to this ADR (per `lessons_vs_adr.md`),
the lesson file is deleted in the same commit. The ADR's
References preserves the lesson's slug as historical lineage.

## Trivial edits not tracked

ADRs are not test fixtures — small follow-up edits are expected:

- Fix a typo in any section.
- Refresh cross-references when a target is renumbered or
  renamed.
- Update code-style examples in the prose.
- Re-format tables (md-table-align).

These DO NOT require a Revision history row. The threshold is
"does this change what someone re-reading this ADR concludes?"
If yes → Revision history; if no → just commit.

## Skip ADRs

Per-fixture skip-ADRs (`skip_<fixture>.md`) document a specific
test fixture v2 declines to fix in the current phase. They are
ADRs in the same lifecycle but use a non-numeric filename. See
existing examples (`skip_embenchen_emcc_env_imports.md`,
`skip_externref_segment.md`) for the required sections (Fixtures
covered / What v2 does today / Why v2 declines / What v2 needs
to fix this honestly / Removal plan / Removal condition /
References).

`scripts/check_skip_adrs.sh` (see debt entry D-013) automates
the Removal condition check. When that lands, every skip-ADR's
Removal condition becomes machine-verifiable.
