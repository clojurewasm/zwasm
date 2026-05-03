---
name: 0009 — Adopt zlinter `no_deprecated` as a Mac-host pre-commit gate
date: 2026-05-03
status: Accepted
tags: tooling, lint, deprecation, gate, ci
---

# 0009 — Adopt zlinter `no_deprecated` as a Mac-host pre-commit gate

- **Status**: Accepted
- **Date**: 2026-05-03
- **Author**: Claude (in-session, on user direction)
- **Tags**: tooling, lint, deprecation, gate, ci

## Context

The session that produced commit `4cf4294` ("zig 0.16 compliance audit
+ expand zig_tips.md") demonstrated three things:

1. **AI training corpora are pre-0.16-skewed.** Three Explore subagents
   were briefed with a 40-pattern checklist of 0.14 → 0.16 deprecation
   patterns, and the codebase still kept `std.meta.Int(.signed, ...)`
   in two places that no agent and no manual `grep` found
   (`src/interp/memory_ops.zig:125`, `src/util/leb128.zig:137`).
   `std.meta.Int` is a deprecated wrapper around the new `@Int(...)`
   builtin in Zig 0.16; the old name compiles silently because the
   stdlib keeps the alias as `pub const Int = @Int;` with a `///
   Deprecated:` doc-comment.
2. **Manual `zig_tips.md` upkeep cannot keep up.** The expanded table
   in `4cf4294` covers ~40 stdlib renames, but the project will keep
   adding code (interp ext_3.0, JIT layers, WASI p2, GC) and stdlib
   will keep deprecating things. A grep-based DIY script
   (`scripts/zig_deprecation_check.sh`) would need every new pattern
   added by hand and would lag behind `/// Deprecated:` annotations
   in the upstream Zig stdlib.
3. **Zig itself does not have `-fdeprecated` or `@deprecated()`
   shipping in 0.16.** The proposal
   ([ziglang/zig#22822](https://github.com/ziglang/zig/issues/22822))
   is accepted and on the "urgent" milestone but unmerged. There is
   no compiler flag to turn deprecated declarations into errors.

A web survey of the Zig lint ecosystem
(KurtWagner/zlinter, DonIsaac/zlint, rockorager/ziglint,
nektro/ziglint, AnnikaCodes/ziglint) identified
[`KurtWagner/zlinter`](https://github.com/KurtWagner/zlinter) as the
only tool that:

- ships a built-in `no_deprecated` rule that consumes the stdlib's
  own `/// Deprecated:` doc-comments via ZLS-driven AST analysis
  (so it auto-tracks new deprecations without project-side rule
  authoring),
- supports Zig 0.16.x explicitly (alongside 0.14.x / 0.15.x /
  master),
- integrates as a `b.step("lint", ...)` custom build step (matches
  the `zone_check.sh` / `file_size_check.sh` discipline),
- exits non-zero with `--max-warnings 0`, suitable for CI gating.

A spike on a throw-away worktree (`spike/zlinter`,
`../zwasm_from_scratch-zlinter-spike`) confirmed:

- baseline runtime ~0.6s on Mac aarch64,
- the `std.meta.Int` findings surface immediately,
- a deliberately injected `std.mem.indexOfScalar` call is detected
  with the upstream stdlib message ("in favor of `findScalar`"),
- `--max-warnings 0` produces `exit code 1` and `Build Summary: N/N
  steps succeeded (1 failed)`.

## Decision

Add `KurtWagner/zlinter` (pinned to the `0.16.x` branch) as a
project dependency and expose it through a single new build step:

```sh
zig build lint                       # warnings ok, errors fail
zig build lint -- --max-warnings 0   # any finding fails (CI gate)
```

Initial rule set: **`no_deprecated` only**. Phase B will widen the
set per the in-session survey (see `private/zlinter-builtins-survey-2026-05-03.md`
for the full inventory), but the Phase A landing keeps the surface
minimal so the integration itself can be reverted cleanly if zlinter
upstream becomes unmaintained or if `@deprecated()` lands natively
in Zig 0.17+.

The lint step is **Mac-host only**, not added to `test-all`. Reasons:

- zlinter requires `zig fetch` against GitHub; OrbStack and
  `windowsmini` already have a slower test cycle and do not need
  the additional dependency or network reach.
- Deprecation findings are platform-independent — a single host is
  enough to catch them.
- `scripts/run_remote_windows.sh` and the OrbStack invocations stay
  as-is; only Mac native gains the lint step.

The Mac native pre-commit gate (CLAUDE.md "Mandatory pre-commit
checks" section) gains a new item: `zig build lint -- --max-warnings 0`
must exit 0 before any commit on `zwasm-from-scratch`. The
`/continue` skill's per-task TDD loop incorporates the same check
in Step 4 (Refactor) so autonomous sessions enforce it.

Two existing call sites are corrected as part of the same landing
because they were the spike's first findings:

- `src/util/leb128.zig:137`: `std.meta.Int(.unsigned, width)` →
  `@Int(.unsigned, width)`
- `src/interp/memory_ops.zig:125`: `std.meta.Int(.signed,
  @bitSizeOf(W))` → `@Int(.signed, @bitSizeOf(W))`

`zig_tips.md` gains a row for `std.meta.Int` → `@Int` so the table
reflects the same lesson.

## Alternatives considered

### Alternative A — DIY grep script

- **Sketch**: `scripts/zig_deprecation_check.sh` walks `src/` and
  fails if any of a fixed pattern list (`std.io.AnyWriter`,
  `std.mem.indexOf*`, `std.meta.Int`, ...) is matched. Patterns
  derived from `zig_tips.md`.
- **Why rejected**: every new stdlib deprecation requires a project
  edit. The session that produced commit `4cf4294` proved that even
  a 40-pattern checklist misses real instances (`std.meta.Int`).
  The cost of pattern maintenance is exactly the cost the project
  is trying to avoid.

### Alternative B — DonIsaac/zlint

- **Sketch**: Pull in `zlint` instead. It has its own AST-level
  semantic analyser (separate from ZLS) and rules like
  `unsafe-undefined`, `homeless-try`.
- **Why rejected**: deprecation detection is not its focus
  ([README rule list](https://github.com/DonIsaac/zlint)). For a
  v2 codebase that mostly cares about stdlib API drift this is the
  wrong axis.

### Alternative C — Wait for `@deprecated()` builtin

- **Sketch**: Don't adopt anything; wait for ziglang/zig#22822 to
  land natively (likely 0.17.x).
- **Why rejected**: open-ended schedule. Phases 5 → 7 will accumulate
  more code in the meantime, increasing the cost of the eventual
  back-fix sweep. The cost of adopting and later replacing zlinter
  is a single `build.zig` revert and dependency removal — small
  enough to make the wait-and-see option strictly worse.

### Alternative D — All-builtins-on initial integration

- **Sketch**: Enable all 25 zlinter built-in rules from the start.
- **Why rejected**: spike showed 81 errors + 1314 warnings, the
  bulk from rules that are mismatched to the project's conventions
  (`declaration_naming` requires identifier length ≥ 3; the
  codebase uses math conventions like `i`, `n`, `rt`, `ea`).
  Phase B will widen the rule set deliberately, one rule at a time,
  with a TDD-loop fix pass per rule.

## Consequences

- **Positive**:
  - Zero-maintenance deprecation tracking — zlinter consumes the
    stdlib's own `/// Deprecated:` annotations.
  - One-step CI semantics: `zig build lint -- --max-warnings 0`.
  - 0.6s on Mac native; small enough to gate every commit without
    perceptible overhead.
  - Two real bugs fixed (`std.meta.Int` → `@Int`).
  - Survey artefact (`private/zlinter-builtins-survey-2026-05-03.md`)
    documents what each builtin rule is, what it would cost to
    enable, and why each is in / out of the recommended set —
    persists the spike learning so Phase B can pick from it.

- **Negative**:
  - First external dependency in `build.zig.zon`.
  - Dependent on a third-party project (`KurtWagner/zlinter`); if
    upstream stops shipping a 0.16-compatible branch, we either
    fork or fall back to grep.
  - Mac-only enforcement means a Linux-only contributor (none today)
    could merge without running it. Mitigation: the `/continue`
    skill always runs on Mac native first.

- **Neutral / follow-ups**:
  - **Phase B** — widen the rule set. Recommended candidates from
    the spike (in priority order, by signal-to-noise): `no_deprecated`
    (already on), `no_hidden_allocations`, `no_inferred_error_unions`,
    `no_undefined`, `no_orelse_unreachable`, `no_swallow_error`,
    `no_empty_block`, `no_unused`, `require_exhaustive_enum_switch`.
    Each lands as one commit (rule on + every finding fixed).
  - **Phase C** — case-by-case judgment for `function_naming`,
    `field_naming`, `import_ordering`, `max_positional_args` (low
    finding count; review and decide per rule).
  - **Excluded** for the foreseeable future: `declaration_naming`
    (1026 findings, conflicts with math/short-name conventions),
    `field_ordering` (alphabetical-only rule), `require_doc_comment`
    (cannot express "pub + non-self-evident"), `no_literal_args`
    (low-level code uses constants).
  - **Sunset path**: when `@deprecated()` and `-fdeprecated` ship
    in Zig (likely 0.17+), revisit this ADR. Native compiler
    enforcement may obsolete the zlinter dependency entirely.
  - `zig-pkg/` (zlinter's package cache) is added to `.gitignore`.

## References

- ROADMAP §A1 (zone discipline / single-source-of-truth gate
  pattern), §P3 (cold-start / dependency minimalism — adoption is
  intentional, scoped, and reversible)
- Related ADRs: 0007 (c_api file split), 0008 (Phase 6 conformance
  baseline)
- Upstream: [KurtWagner/zlinter](https://github.com/KurtWagner/zlinter)
- Native proposal: [ziglang/zig#22822 — `@deprecated()`
  builtin](https://github.com/ziglang/zig/issues/22822)
- Session artefact: `private/zlinter-builtins-survey-2026-05-03.md`
  (full builtin rule inventory + per-rule finding counts at
  the time of adoption)
