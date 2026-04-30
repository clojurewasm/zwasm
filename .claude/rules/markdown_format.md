---
paths:
  - ".dev/**/*.md"
  - "docs/**/*.md"
  - "README.md"
  - "CLAUDE.md"
---

# Markdown formatting rules

Auto-loaded when editing markdown.

## Tables

- Use `|` borders.
- One space padding around content.
- Header separator `|---|---|` (no alignment markers unless needed).
- Run `md-table-align` (or `scripts/check_md_tables.sh`) before
  committing if a table changed.

## Headings

- `# H1` is the document title (one per file).
- `## §N. ...` for sections (in ROADMAP / surveys).
- `### N.M` for subsections.
- No skipping levels (`##` → `####` is wrong).

## Lists

- `-` for unordered (consistent throughout file).
- `1. 2. 3.` for ordered.
- Indent continuation 2 spaces.

## Code blocks

- Triple backtick + language tag (`` ```zig ``, `` ```bash ``,
  `` ```yaml ``).
- No tabs inside; use spaces.

## Links

- Inline: `[text](path)`. Relative paths preferred for in-repo.
- Reference: `[text][1]` + `[1]: <url>` at file end (only when 3+
  links share a target).

## Front-matter

- Used for skill / rule files, ADR template.
- YAML format, fenced by `---` lines.

## File end

- Single trailing newline.
- No trailing whitespace.

## ROADMAP-specific

- §0 is the table of contents (with anchors).
- Each §N starts with a level-2 heading.
- Tables in §2 (P/A) and §6 (tier system) are critical — if they
  drift, audit_scaffolding flags it.

## ADR-specific

- Use the imperative mood in titles ("Adopt X" not "Adopting X").
- Status line at top after title.
- Sections: Context / Decision / Alternatives / Consequences /
  References (per `.dev/decisions/0000_template.md`).
