# 0129 — Debt ledger migrated from Markdown table to YAML SSOT (debt.md → debt.yaml)

- **Status**: Accepted (2026-06-02; user directive — replicate the ClojureWasmFromScratch debt-YAML migration here)
- **Date**: 2026-06-02
- **Author**: claude (with user directive + ClojureWasmFromScratch reference study)
- **Tags**: scaffolding, debt ledger, YAML SSOT, yq, /continue Step 0.5, audit_scaffolding §F, gate, D-227
- **Amends**: the debt-ledger format referenced by CLAUDE.md, `/continue` RESUME.md Step 0.5, audit_scaffolding §F, and the skip/close gate scripts. (Scaffolding format change, not a §1/§2/§4/§5/§9/§11/§14 deviation — but load-bearing across the loop, so recorded.)

## Context

`.dev/debt.md` was a 7-column Markdown table (`ID | Layer | Status |
Description | First raised | Last reviewed | Refs`) that had drifted into a
heterogeneous mess: full 7-col rows, 6-col rows where Status absorbed the body,
and compact 3–4-col historical resolved-notes. Cells carried UNescaped literal
`|` (technical narrative, code), so every consumer that parsed it (gate scripts,
the loop's Step 0.5 sweep) used fragile `grep`/`awk` over a format that
`md-table-align` padding kept inflating. The sibling project
`ClojureWasmFromScratch` had already migrated its debt ledger to a queryable
YAML SSOT with a `yq` cookbook; the user asked to bring that here.

## Decision

1. **`.dev/debt.yaml` is the debt SSOT.** Schema: a single `entries:` list +
   a `conventions:` block scalar (the ledger's own discipline + how-to-read +
   promotion-to-ADR prose). Per entry: `id`, `layer`, `status`, `description`
   (block scalar — the full body, incl. the `blocked-by` barrier predicate at
   its head), `first_raised`, `last_reviewed`, `refs` (block scalar).
2. **`status` is a derived enum** — `now | blocked-by | resolved | partial |
   note` — NOT the raw Status cell. The original Status prose is preserved
   verbatim at the head of `description`. This sidesteps the literal-`|`-in-
   Status boundary problem and gives clean `yq` queries.
3. **Single list, delete-on-discharge** (this project's existing discipline) —
   NOT ClojureWasmFromScratch's `active:`/`discharged:` split. Resolved debts
   are deleted; git log retains them via the `chore(debt): close D-NNN` commit.
   (Divergence from the reference, to honor this project's convention.)
4. **mikefarah Go `yq` v4** is the query/edit tool. Discipline (single-quote the
   expression, `env(VAR)` for shell vars, `yq -i` preserves block scalars) lives
   in the auto-loaded rule `.claude/rules/yaml_ssot_yq.md`.
5. **Lossless conversion** via `scripts/migrate_debt_to_yaml.py` (kept as the
   historical record): date-anchored parse + per-row reconstruction-verify
   (aborts on any mismatch — no silent loss). Verified: 54 entries round-trip.
6. **Schema gate** `scripts/check_debt_yaml.sh` (wired into `gate_commit.sh` when
   debt.yaml is staged): parse + required fields + status enum + blocked-by ⇒
   last_reviewed + unique IDs + phantom `D-NEW*` scan.

## Rejected alternatives

- **Keep Markdown + tighten the table**: rejected — the literal-`|` + padding
  problems are structural; no consumer could query it cleanly.
- **`active:`/`discharged:` two-list schema (ClojureWasm's)**: rejected — this
  project deletes discharged debts (git is the archive); a growing `discharged:`
  list contradicts that discipline.
- **JSON / TOML**: rejected — YAML block scalars preserve the Markdown-style
  narrative prose, and YAML is the de-facto `.dev` data idiom here (bench
  history, etc.).

## Consequences

- The loop's Step 0.5 debt sweep, audit_scaffolding §F, and the close/skip gate
  scripts query debt.yaml via `yq` (≈20 live files + 4 functional gate scripts
  rewired; immutable ADRs / lessons / archive / phase_log left as historical).
- A malformed block scalar would break every `yq` query → the schema gate is the
  guard.
- `debt.md` is deleted (git retains it). The converter cannot be re-run after
  deletion; it is a one-shot provenance artifact.
- Removal condition: none — this is the going-forward format. Reverting would
  require re-MD-ifying + reverting all consumers.
