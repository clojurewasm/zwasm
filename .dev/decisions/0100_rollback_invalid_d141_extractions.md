# 0100 — Rollback ADR-0097 + supersede ADR-0095/0096 per ADR-0099 §D2

- **Status**: Accepted
- **Date**: 2026-05-21
- **Author**: post-D-141 retrospective
- **Tags**: rollback, file-size-discipline, retrospective, ADR-0099-application
- **Pairs-with**: ADR-0099 (the framework), ADR-0101 (init_expr redesign)

## Context

Post-D-141 retrospective (see ADR-0099 §D5) applied the new 4+4
conditions to all 15 D-141 sweep ADRs. Three were identified as
not satisfying ADR-0099 §D2:

- **ADR-0097** (regalloc_verify): triggers N3 (shallow module —
  ~34 LOC of substantive code). 0 positive conditions fire
  cleanly; the split is below the deep-utility bar.
- **ADR-0095** (sections_element): triggers N1 + N2 (helper-
  circular import on `sections.scanInitExpr` + pub-leak of the
  helper). The boundary forced a private helper to become public
  for the wrong reason.
- **ADR-0096** (sections_codes/data): triggers N1 + N2 (helper-
  circular on `sections.scanInitExpr` / `sections.readValType`
  + pub-leak). Same structural defect as ADR-0095.

`bash scripts/check_split_smell.sh` (landed at ADR-0099 Cycle 1)
confirms these findings mechanically:

- `[N1-helper-circular] src/parse/sections_codes.zig — child
  imports sections.zig and calls helpers: sections.readValType(`
- `[N1-helper-circular] src/parse/sections_element.zig — child
  imports sections.zig and calls helpers: sections.scanInitExpr(`
- `[N1-helper-circular] src/parse/sections_data.zig — child
  imports sections.zig and calls helpers: sections.scanInitExpr(`
- `[N3-shallow] src/engine/codegen/shared/regalloc_verify.zig —
  substantive=58 LOC < 100 — likely shallow module`
- `[N3-shallow] src/parse/sections_data.zig — substantive=76 LOC
  < 100 (also N1)`
- `[N3-shallow] src/parse/sections_codes.zig — substantive=57
  LOC < 100 (also N1)`

## Decision

### D1 — ADR-0097: straight rollback

Re-incorporate the `verify` family (`VerifyError`, `verify()`,
`verifyWith()`, and the paired tests) into
`src/engine/codegen/shared/regalloc.zig`. Delete
`src/engine/codegen/shared/regalloc_verify.zig`. Resulting
`regalloc.zig` is ~675 LOC — well under the soft cap.

Rollback execution: Cycle 4 of the file-size reform plan
(`private/file-size-reform/07-execution-plan.md`).

### D2 — ADR-0095 + ADR-0096: supersede by ADR-0101

The siblings (`sections_element.zig`, `sections_data.zig`,
`sections_codes.zig`) are not removed — the per-section split is
a legitimate spec-axis grouping (Wasm §5.5.x sections). What's
wrong is that they reach back into `sections.zig` for shared
helpers (`scanInitExpr`, `readValType`, `skipLeb128`).

ADR-0101 extracts those helpers to `src/parse/init_expr.zig`
as a proper P3 **deep utility** (consumed by `sections.zig` +
the 3 siblings + future Wasm 3.0 GC decoders). After ADR-0101
lands, the siblings depend on `init_expr` (cleanly typed, no
helper-circular) and `sections.zig` no longer needs to pub-
leak those helpers.

Supersede execution: Cycle 5 of the file-size reform plan.

## Conditions check (per ADR-0099 §D3)

This ADR is the **retrospective application** of ADR-0099 §D2
to three already-shipped ADRs; it does not propose a new
extraction itself. No P/N check required.

The conditions check for the **superseding** ADR-0101 lives in
that ADR.

## Status updates (applied this commit)

- ADR-0095: `Status: Superseded by ADR-0101 (see ADR-0100)`
- ADR-0096: `Status: Superseded by ADR-0101 (see ADR-0100)`
- ADR-0097: `Status: Rolled back (see ADR-0100 + Cycle 4 commit)`

## Alternatives

1. **Leave the invalid extractions in place** — Rejected. They
   are observable smells (helper-circular, shallow module) that
   `check_split_smell.sh` flags on every commit. The script is
   informational, so the project would continue to build, but
   the discipline would be eroded immediately.

2. **Roll back all three identically (straight rollback)** —
   Rejected for ADR-0095/0096. The per-section sibling
   organisation is legitimate; the boundary just needs the
   right utility module beneath it. ADR-0101's `init_expr.zig`
   is the structurally correct fix.

3. **Tweak ADR-0099 §D2 to admit the existing shape** —
   Rejected. The 4+4 conditions are derived from industry
   sources (Ousterhout deep-module, Page-Jones connascence).
   Loosening them to fit the failing cases defeats the reform.

## Consequences

### Positive

- Restores ADR-0099 §D2 discipline in concrete code.
- `regalloc.zig` returns to its proper deep-module shape
  (verify + compute + setup + state, all cohesive under one
  algorithm family).
- `init_expr.zig` (ADR-0101) becomes the right substrate for
  future Wasm 3.0 GC reference-type decoders.

### Negative

- Three already-shipped ADRs change Status. Citations from
  other docs (lessons, handover, ROADMAP §9.12-F count)
  require pointers updated. Done in this commit + Cycle 6c
  archive.
- One additional ADR (0101) authored.

### Neutral

- `git log` history preserves the original extraction commits.
  Rollback is a forward-only operation; we do not rewrite
  history.

## References

- ADR-0099 (the framework — file-size discipline reframe)
- ADR-0101 (init_expr.zig extraction — the proper architecture
  for ADR-0095/0096's intent)
- `private/file-size-reform/` (working files, archived at Cycle 6c)
- `scripts/check_split_smell.sh` (mechanical confirmation of N1/N3
  findings)

## Revision history

- 2026-05-21 — Initial draft, Cycle 3 of file-size discipline reform.
