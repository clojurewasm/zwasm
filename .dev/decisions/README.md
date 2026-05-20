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

- **Status** (per ADR-0050 lifecycle):
  - `Proposed` — DRAFT or under debate
  - `Accepted` — steering active code
  - `Accepted (partial — see D-NNN)` — landed for one
    arch/host/surface; named debt row carries the remaining
    structural barrier
  - `Accepted (scope downgraded by NNNN)` — design retained;
    exit criterion narrowed by named ADR
  - `Superseded by NNNN` — entire decision replaced; new ADR
    carries the lineage
  - `Closed (Phase X DONE)` — one-shot decision; phase
    complete; ADR is historical record (terminal — flip via
    a new ADR if the problem re-opens)
  - `Demoted to .dev/lessons/<file>` (see lessons-vs-ADR rule)
  - `Rejected` — proposal debated and rejected
  - `Deprecated` — no longer recommended; no replacement
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
- **Scope-downgrade** (per ADR-0050): when a successor ADR narrows
  the original's exit criterion but the design itself stays
  load-bearing, flip the original to
  `Accepted (scope downgraded by NNNN)`. The full reframe lives in
  the successor ADR; the Status line names the relationship so a
  fresh reader hits it before Revision history.
- **Mark partial** (per ADR-0050): when a decision lands for one
  arch/host/surface but a structural barrier blocks completion on
  another, flip to `Accepted (partial — see D-NNN)` and ensure the
  named debt row carries the remaining barrier.
- **Close** (per ADR-0050): when a one-shot Phase-bound decision
  has fully landed and the Phase is `DONE` per ROADMAP §9, flip to
  `Closed (Phase X DONE)`. Terminal — if the problem re-opens,
  write a new ADR (e.g. ADR-0010 → ADR-0011 reopen pattern).
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
| 2026-05-04 | `8a08c9bf` | §3.γ rejected-alternatives expanded.     |
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
`skip_externref_segment.md`, `skip_text_format_parser.md`) for
the required sections (Fixtures covered / What v2 does today /
Why v2 declines / What v2 needs to fix this honestly / Removal
plan / Removal condition / References).

### Effectiveness gate (per ADR-0050)

A skip-ADR is **effective** only when one of these holds:

1. **Runner-side classification** — the runner that consumes the
   fixture's manifest classifies it via `skip-adr-<ADR-id>` per
   ADR-0029 vocabulary, separating `skip-impl` from `skip-adr` in
   its tally.
2. **DEFER mark + runner skip-token** — the manifest carries
   `# DEFER: skip_<slug>` (or `skip-adr-<slug>`) and the runner
   recognises the token, emitting `SKIP-ADR <slug>` instead of
   running the fixture.
3. **Manifest exclusion** — the fixture is removed from the
   active manifest entirely.

If none holds, the skip-ADR is **not effective** and a debt row
must be filed naming the structural barrier (typically: "runner
X has no skip-token machinery"). The example case is
`skip_embenchen_emcc_env_imports.md` and `skip_externref_segment.md`,
both ineffective vs `wast_runtime_runner.zig` as of 2026-05-11
(D-072).

`scripts/check_skip_adrs.sh` currently verifies fixture-path
existence only (D-013 close). The path-only check passes for
ineffective skip-ADRs — its `--gate` mode is being extended per
ADR-0050 D-3 to enforce the three effectiveness paths above.
Until that lands, manual audit (e.g. the 2026-05-11 audit) is
the enforcement path.
