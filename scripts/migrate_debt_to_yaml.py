#!/usr/bin/env python3
"""One-shot lossless converter: .dev/debt.md (Markdown table) -> .dev/debt.yaml.

Kept as the historical record of the migration (ADR-0129 / D-227). The Markdown
ledger was a 7-column table:

    | ID | Layer | Status | Description | First raised | Last reviewed | Refs |

Cells carry UNescaped literal `|` (technical narrative, code, "a | b"), so a
fixed 7-way split over-splits. Strategy: ID/Layer are the first two clean cells;
First raised / Last reviewed are date-shaped clean cells third/second from the
right; Refs is the last cell; Status is the single cell after Layer; everything
between Status and First raised is Description (rejoined on " | "). Each parsed
row is RECONSTRUCTED and checked against the original stripped cells — any
mismatch aborts (no silent loss), exactly as the ClojureWasmFromScratch
migration did.

Run: `python3 scripts/migrate_debt_to_yaml.py` (reads .dev/debt.md, writes
.dev/debt.yaml, prints `OK lossless: entries=N` or aborts).
"""

import re
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MD = ROOT / ".dev" / "debt.md"
YAML = ROOT / ".dev" / "debt.yaml"

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def split_cells(line: str):
    """Split a `| a | b | ... |` row into its inner cells (stripped)."""
    inner = line.strip()
    assert inner.startswith("|") and inner.endswith("|"), inner[:40]
    return [c.strip() for c in inner[1:-1].split("|")]


def _verify(id_, cells, rebuilt):
    if rebuilt != cells:
        sys.exit(f"ABORT: {id_} reconstruction mismatch\n  orig={cells}\n  got ={rebuilt}")


def classify(text: str) -> str:
    """Derive a terse, queryable status tag from the description head. Robust
    against literal `|` inside the original Status cell (the boundary problem):
    status is a CLASSIFIER, the full text lives in `description`."""
    t = text.lstrip("*").strip().lower()
    if re.match(r"(resolved|discharged|done)\b", t):
        return "resolved"
    if t.startswith("blocked-by"):
        return "blocked-by"
    if t.startswith("partial"):
        return "partial"
    if t.startswith("now"):
        return "now"
    return "open"


def parse_row(line: str):
    cells = split_cells(line)
    id_ = cells[0]
    if not re.match(r"^D-\d+", id_):
        sys.exit(f"ABORT: bad id cell {id_!r}")

    # Compact resolved-note format: `| ID | <date> | <desc> | [refs] |`.
    if DATE_RE.match(cells[1]):
        first_raised = cells[1]
        if len(cells) >= 4:
            refs = cells[-1]
            description = " | ".join(cells[2:-1])
            rebuilt = [id_, first_raised] + description.split(" | ") + [refs]
        else:
            refs = ""
            description = " | ".join(cells[2:])
            rebuilt = [id_, first_raised] + description.split(" | ")
        _verify(id_, cells, rebuilt)
        # Compact rows are landed-fact records (e.g. "X done, commit Y").
        return {"id": id_, "layer": "", "status": "note", "description": description,
                "first_raised": first_raised, "last_reviewed": "", "refs": refs}

    # Full format: `| ID | Layer | <body…> | First | Last | Refs |`. The Status
    # cell may itself contain `|`, so do NOT split it out positionally — keep
    # the whole body in `description` (lossless) and derive `status` by class.
    layer = cells[1]
    refs = cells[-1]
    idx = len(cells) - 2
    dates = []
    while idx >= 3 and DATE_RE.match(cells[idx]):
        dates.insert(0, cells[idx])
        idx -= 1
    head = cells[2:idx + 1]            # the full body (status + description), ≥1 cell
    description = " | ".join(head)
    status = classify(description)
    first_raised = dates[0] if len(dates) >= 1 else ""
    last_reviewed = dates[1] if len(dates) >= 2 else ""

    rebuilt = [id_, layer] + head + dates + [refs]
    _verify(id_, cells, rebuilt)
    return {"id": id_, "layer": layer, "status": status, "description": description,
            "first_raised": first_raised, "last_reviewed": last_reviewed, "refs": refs}


def yaml_quote(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def yaml_block(key: str, content: str, indent: int) -> str:
    pad = " " * indent
    cpad = " " * (indent + 2)
    # Single-line cells become a one-line literal block scalar (chomped).
    body = "\n".join(cpad + ln for ln in content.split("\n"))
    return f"{pad}{key}: |-\n{body}\n"


def yaml_field(key: str, content: str, indent: int) -> str:
    """Block scalar for prose; quoted empty-string when the cell is blank
    (an empty `|-` block scalar parses as null, so never emit one)."""
    if content == "":
        return " " * indent + f'{key}: ""'
    return yaml_block(key, content, indent).rstrip("\n")


def main():
    text = MD.read_text()
    lines = text.splitlines()

    # Conventions = everything outside the table (intro blockquote + the
    # trailing `## How to read this file` / `## Promotion to ADR` sections).
    convention_lines = []
    rows = []
    in_table = False
    for ln in lines:
        if ln.startswith("| D-"):
            rows.append(parse_row(ln))
            in_table = True
            continue
        if ln.startswith("|") and ("---" in ln or " ID " in ln):
            in_table = True  # header / separator rows: drop
            continue
        if ln.startswith("# Debt ledger"):
            continue
        if ln.strip() == "## Active":
            continue
        convention_lines.append(ln)

    # Trim leading/trailing blank lines from conventions.
    while convention_lines and not convention_lines[0].strip():
        convention_lines.pop(0)
    while convention_lines and not convention_lines[-1].strip():
        convention_lines.pop()
    conventions = "\n".join(convention_lines)

    out = []
    out.append("# Debt ledger (YAML SSOT — D-227 / ADR-0129).")
    out.append("# Query/edit discipline: .claude/rules/yaml_ssot_yq.md. yq = mikefarah Go v4.")
    out.append("# Refresh on every /continue resume — .claude/skills/continue/RESUME.md Step 0.5.")
    out.append("")
    out.append("entries:")
    for e in rows:
        out.append(f'  - id: {yaml_quote(e["id"])}')
        out.append(f'    layer: {yaml_quote(e["layer"])}')
        out.append(f'    status: {yaml_quote(e["status"])}')
        out.append(yaml_field("description", e["description"], 4))
        out.append(f'    first_raised: {yaml_quote(e["first_raised"])}')
        out.append(f'    last_reviewed: {yaml_quote(e["last_reviewed"])}')
        out.append(yaml_field("refs", e["refs"], 4))
    out.append("")
    out.append(yaml_block("conventions", conventions, 0).rstrip("\n"))
    out.append("")

    YAML.write_text("\n".join(out))
    print(f"OK lossless: entries={len(rows)}")


if __name__ == "__main__":
    main()
