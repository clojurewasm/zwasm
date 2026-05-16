# 0063 — Adopt per-file hard-cap exemption marker for uniform-pattern catalog files

- **Status**: Accepted
- **Date**: 2026-05-17
- **Author**: Shota Kudo (chaploud)
- **Tags**: scaffolding, file_size_check, ROADMAP-§A2, debug-infrastructure

## Context

ROADMAP §A2 hard-caps every `src/**/*.zig` at 2000 lines via
`scripts/file_size_check.sh --gate`, with the rationale that a
file > 2000 LOC is usually doing 2+ things and benefits from
splitting. The 2026-05-11 chunks 9.9-h-20 + `c89ec713` codified
this and re-enabled enforcement via the `.githooks/pre-commit`
hook after D-057 closed.

The d-74 → d-85 chunk run (cumulative +217 PASS) added many
entry-helper shapes to `src/engine/codegen/shared/entry.zig` and
extensive module-level validation passes to `src/engine/runner.zig`,
pushing both files past the hard cap:

- `entry.zig` 2108 LOC — 84 `pub fn callXX_yy` helpers, **all
  uniform shape** (12-20 LOC each: function-pointer cast +
  trap_flag manipulation + invoke). The pattern is mechanical
  duplication, not multi-concern bloat. Splitting fragments a
  cohesive catalog without semantic value; the natural split
  axes (by result type / by arg count) produce 5-10 files of
  ~400 LOC each that cross-reference each other from the runner
  dispatch ladder — adds friction, removes navigation
  convenience.
- `runner.zig` 2178 LOC — legitimate multi-concern (compileWasm
  orchestration + ~600 LOC of module validation + runtime
  helpers + setupRuntime + host-trap dispatch). This file IS a
  split candidate (see ADR-0064 follow-up).

The naïve response — split entry.zig anyway to satisfy the cap —
optimises for the metric, not the design intent. The hard cap's
purpose is **smell detection**: "a file > 2000 LOC usually means
2+ concerns". For uniform-pattern catalogs, that heuristic is a
false positive.

Per-file exemption surfaces the design choice explicitly via a
marker comment that cites this ADR, preserving the smell-
detection value (no silent drift) while accommodating the
legitimate catalog case.

## Decision

Add a per-file hard-cap exemption mechanism to
`scripts/file_size_check.sh`:

1. **Marker**: a `// FILE-SIZE-EXEMPT: <reason> (per ADR-NNNN)`
   line on lines 1-5 of the source file. The ADR reference is
   mandatory — silent exemption is rejected by the script's
   regex (`ADR-[0-9]+` required).
2. **Effective cap**: exempt files have hard cap raised to 2500
   (from 2000). Soft cap warning (1000) still fires — the file
   stays tracked.
3. **Audit visibility**: file_size_check emits an `EXEMPT: <file>
   (<lines>, in [HARD_CAP, EXEMPT_CAP] via marker)` line for any
   file currently using the exemption. The marker is grep-able
   project-wide (`rg '^// FILE-SIZE-EXEMPT'`).
4. **2500 itself is a cap**: if an exempt file crosses 2500
   (`EXEMPT-CAP EXCEEDED`), gate fails. The exemption is a
   relaxation, not removal.

This ADR's representative consumer is `entry.zig` (added in the
same commit landing this ADR).

## Alternatives considered

### Alternative A — Raise the global hard cap to 2500

- **Sketch**: change `HARD_CAP=2500` in file_size_check.sh
  unconditionally.
- **Why rejected**: removes the smell-detection signal for
  files where 2000 LOC genuinely IS bloat (runner.zig's
  multi-concern shape). The cap is a default, not a target;
  raising it shifts the default in the wrong direction.

### Alternative B — Comptime-generate entry helpers

- **Sketch**: replace the 84 `pub fn callXX_yy` declarations
  with a `comptime` loop over a table of (result-type, arg-types)
  tuples, generating the function pointer type and body for
  each.
- **Why rejected**: legitimate path forward, but ~1 day of
  work + ABI-edge-case risk + harder for new contributors to
  navigate (function names exist only at comptime; grep
  becomes less direct). Filed as a follow-up consideration,
  NOT a near-term prerequisite for hook re-activation. The
  exemption is the cheap-now path; comptime generation is the
  long-term clean path. See `.dev/debt.md` for the deferred
  follow-up entry.

### Alternative C — Force split entry.zig into result-type groups

- **Sketch**: split into `entry_void.zig` / `entry_i32.zig` /
  `entry_i64.zig` / `entry_f32.zig` / `entry_f64.zig` /
  `entry_v128.zig`, each ~400 LOC, with a top-level `entry.zig`
  re-exporting via `pub usingnamespace` (Zig 0.16 removed
  `usingnamespace` — would need explicit re-export of all 84
  symbols).
- **Why rejected**: the resulting files are still all
  identical-shape catalogs; the cohesion of "entry helpers for
  spec_assert dispatch" is fragmented across 5-6 files.
  Discovery suffers (grep for `callI32_` now has to know which
  file to look in). Adds friction without semantic gain.

### Alternative D — Silent exemption (no ADR required)

- **Sketch**: marker that says "don't enforce hard cap on this
  file", no rationale required.
- **Why rejected**: violates `.claude/rules/no_workaround.md`
  "fix root causes" — silent exemption is exactly the kind of
  drift the file-size check exists to catch. Forcing an ADR
  reference makes the design choice load-bearing and re-
  reviewable.

## Consequences

- **Positive**:
  - `entry.zig`'s catalog shape is honestly described, not
    artificially fragmented.
  - The exemption marker is grep-able and project-auditable
    (`rg '^// FILE-SIZE-EXEMPT'`).
  - Smell-detection signal preserved for genuinely multi-concern
    files (runner.zig).
  - Pre-commit hook can re-activate via `.githooks/pre-commit`
    without rejecting commits on the entry.zig hard-cap
    violation.

- **Negative**:
  - The escape hatch could be misused for files that are
    legitimately multi-concern. Mitigated by:
    - Mandatory ADR reference in the marker.
    - `audit_scaffolding` skill can grep for `FILE-SIZE-EXEMPT`
      markers and re-validate the cited ADR's "uniform pattern"
      claim at phase boundaries.
  - 2500 is itself arbitrary. If a future catalog file genuinely
    needs 3000+ LOC, this ADR will need amendment.

- **Neutral / follow-ups**:
  - **Follow-up debt entry**: comptime-generate entry helpers
    (Alternative B). Filed as a deferred refactor; barrier is
    "next time entry.zig approaches the 2500 exempt cap OR a
    new ABI variant requires touching every helper". See
    `.dev/debt.md` for the row.
  - **ADR-0064** (separate ADR, same commit): runner.zig split
    into `runner.zig` + `runner_validate.zig` to address the
    LEGITIMATE multi-concern case.
  - Hook re-activation: depends on this ADR + entry.zig marker
    + runner.zig split landing together. The chain is
    sequential, not optional.

## References

- ROADMAP §A2 (file size hard cap)
- `scripts/file_size_check.sh` (the script being amended)
- ADR-0064 (`runner.zig` legitimate split — companion decision)
- `.claude/rules/no_workaround.md` (silent-exemption rejection)
- `.claude/skills/audit_scaffolding/CHECKS.md` §B.1 (file-size
  finding category)
- Commits: `c89ec713` (hook re-activation history), `00f93d24`
  (D-057 close + `file_size_check warn → --gate` restoration)

## Revision history

| Date       | Change                                             | Commit |
|------------|----------------------------------------------------|--------|
| 2026-05-17 | Initial draft + acceptance + entry.zig consumer    | (this commit) |
