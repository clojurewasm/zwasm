---
description: "debt.yaml (+ any .dev YAML SSOT) query/edit discipline — mikefarah Go yq v4 idioms: single-quote the expression, pass shell vars via env(), `yq -i` preserves block scalars + comments. Migrated from debt.md per D-227 / ADR-0129."
paths:
  - ".dev/debt.yaml"
---

# YAML SSOT + `yq` cookbook

## Invariant

`.dev/debt.yaml` is the technical-debt SSOT (was `debt.md`; D-227 / ADR-0129).
Query + edit it with **mikefarah Go `yq` v4** (NOT python-yq / jq). Schema:

```yaml
entries:
  - id: "D-NNN"
    layer: "code"            # or "" for compact historical notes
    status: "now"            # now | blocked-by | resolved | partial | note
    description: |-          # full body (block scalar; the blocked-by barrier lives here)
      ...
    first_raised: "YYYY-MM-DD"
    last_reviewed: "YYYY-MM-DD"   # "" if never reviewed
    refs: |-                 # file:line / ADR § / skill path  ("" if none)
      ...
conventions: |-              # the ledger's own discipline + how-to-read + promotion-to-ADR
  ...
```

`status` is a **derived classifier** (the original Status prose, incl. the
`blocked-by:` barrier predicate, is preserved verbatim at the head of
`description`). Discipline (delete-on-discharge, blocked-by predicate
mandatory, staleness sweep) is unchanged — it lives in `.conventions`.

## Shell-quoting rule (the whole trick)

1. **Single-quote the entire `yq` expression** — neutralises `| [] * ? . " ==`.
2. **Pass shell variables via `env(VAR)`, never string interpolation.**
3. `yq -i` (in-place) **preserves `|-` block scalars + comments** (v4.53.2 verified).

## Canonical queries

```sh
yq -r '.entries | length' .dev/debt.yaml                          # count
yq -r '.entries[].id' .dev/debt.yaml                              # all IDs
yq -r '.entries[] | select(.status == "now") | .id' .dev/debt.yaml          # discharge candidates
yq -r '.entries[] | select(.status == "blocked-by") | .id + "  " + .last_reviewed' .dev/debt.yaml  # staleness sweep
DROW="D-201" yq -r '.entries[] | select(.id == env(DROW)) | .description' .dev/debt.yaml   # one body
yq -r '.entries[] | select(.status == "resolved" or .status == "note") | .id' .dev/debt.yaml  # deletable (git retains)
grep -oE 'D-[0-9]+' .dev/debt.yaml | sort -t- -k2 -n | tail -1     # highest ID → next is +1
```

## Edit workflow (AI agent)

- **Add**: dedup first (`rg -n '<keyword>' .dev/debt.yaml`); update the existing
  entry if the class overlaps, else append a new `- id:` block under `entries:`
  with the next ID. Use the **Edit/Write tool** for new multi-line `description`
  prose (NOT `yq -i` — block-scalar indent is exactly 4 spaces for the key,
  6 for the content).
- **Scalar flip** (status / last_reviewed): `yq -i` is safe —
  `DROW="D-NNN" yq -i '(.entries[] | select(.id == env(DROW)) | .last_reviewed) = "2026-06-02"' .dev/debt.yaml`
- **Discharge**: delete the entry (git log retains it via the discharge commit
  `chore(debt): close D-NNN <line>`) — `DROW="D-NNN" yq -i 'del(.entries[] | select(.id == env(DROW)))' .dev/debt.yaml`.

## Enforcement

`bash scripts/check_debt_id_refs.sh [--gate]` — every `D-NNN` cited in
`src/` / `.claude/` / `scripts/` / `.dev/` (outside ADRs/lessons/archive) must
resolve to an entry in debt.yaml; flags phantom `D-NEW*` placeholders. Block
scalars + indentation are validated by `yq` parsing (a malformed entry makes
every query error).

## Top traps

- **yq flavor**: must be mikefarah Go v4 (`yq --version` → `v4.x`). jq/python-yq
  syntax differs.
- **Empty cell**: never emit a bare `key: |-` with no content (parses as null) —
  use `key: ""`.
- **Block-scalar indent**: content is exactly 2 spaces deeper than its key; drift
  = parse failure. Use the Edit tool, mirror an existing entry's indent.
