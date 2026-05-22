# Encode invariants / rules after surveying the codebase, not directly from audit output

- **Date**: 2026-05-22
- **Citing**: `651bb15c` (I4 NOT-in-test-all false positive fix),
  `090bea82` (I2/I3 idiom correction — `test/api/` → in-source
  test blocks)
- **Tags**: invariant-encoding, audit-output, project-idiom,
  survey-discipline, phase-9-close-master-plan

## The observation

When the 2026-05-22 4-agent audit produced concrete findings (e.g.
"`wast_runtime_runner` NOT in test-all"; "Wasm-2.0 reftype c_api
round-trip: ZERO coverage"), the master plan §5 + invariant rule +
check script were authored using the **abstract requirement** the
audit named **plus the file paths the audit proposed**. The
audit's abstract requirements were correct; its proposed file
paths matched neither project state nor project idiom.

Two concrete misses surfaced in subsequent autonomous-loop cycles:

- **I4 false positive (`651bb15c`)**: the audit reported
  "wast_runtime_runner not in test-all" citing the `build.zig:454`
  comment `Not wired into test-all aggregate`. That comment
  applies to the **wasmtime_misc full-corpus step** (deferred to
  §9.6 / 6.E investigation per D-072), not to the **smoke step**.
  The smoke step (`run_wast_runtime_smoke`) IS wired at
  `build.zig:616`. My initial check script's grep matched the
  unrelated comment and produced a spurious FAIL.

- **I2/I3 idiom miss (`090bea82`)**: the audit proposed test
  paths `test/api/c_api_wasm2_reftype.zig`,
  `test/api/zig_facade_wasm2.zig`, etc. The project does not
  have a `test/api/` directory — c_api tests live as in-source
  `test "..."` blocks in `src/api/instance.zig` (`zig build test`
  discovers them via the core runner). The Zig facade test
  similarly belongs as an in-source block in `src/zwasm.zig`.

Both misses were fixable in one chunk each, but they consumed
mid-cycle attention and created a moment of "is this gate
working?" doubt. The fix in both cases was: **survey the existing
code shape** (`grep -rE "@cImport.*wasm\.h"` /
`grep 'test "wasm' src/api/*.zig`) and re-encode the invariant
to match.

## The rule (for future audit → invariant authoring cycles)

When encoding a subagent audit finding into:

- A `.claude/rules/<topic>.md` auto-loaded rule,
- A `scripts/check_<topic>.sh` mechanical gate,
- A `.dev/<phase>_close_master.md` exit predicate,
- An ADR's `Decision` section,

do this **first**:

1. **Grep the project for the audit's proposed file paths**. If
   they don't exist, the audit is proposing future state — **but
   so might the rule, if the project has a different idiom for
   the same concept**. Search for the abstract requirement's
   sibling concept (e.g. "where do existing tests for this c_api
   surface live?") before pinning paths in load-bearing rules.

2. **Grep for the audit's proposed comment / token strings**. If
   the audit cites "comment X is at line Y", re-read the
   surrounding 10 lines. The comment may refer to a related-but-
   different artifact (D-072 vs the smoke step; D-094 SysV vs
   D-164 Win64).

3. **If the audit's framing is project-idiom-incompatible**,
   correct the framing at encode time. Document the idiom
   correction in the encoded rule's body so future readers know
   the audit said X but the project does Y.

4. **The audit's abstract requirements are usually correct**.
   "Reftype c_api round-trip has zero coverage" is a valid
   structural observation. **The proposed file paths and code
   shapes are guesses** that need verification.

## Why this is not load-bearing enough for an ADR

The discipline is **investigative**, not architectural. It changes
**how I author rules**, not **what the rules contain**. A new
session inheriting this lesson via `INDEX.md` keyword grep
("invariant", "audit", "encode") will adjust its survey discipline
without needing a Decision § to consult. If this pattern recurs at
ADR-grade frequency (e.g. the next 3 close-plan cycles repeat the
same idiom-miss), promote to an ADR or amend
`.claude/rules/textbook_survey.md` to add an "encoding audit
output" sibling section.

## Mechanical follow-up

`scripts/check_phase9_close_invariants.sh` already documents the
project idiom inline (the new I2/I3 comments cite "per project
idiom"). Future sessions reading the script + this lesson will
see the discipline at both layers.

## Sibling lessons / rules

- `.claude/rules/textbook_survey.md` — Step 0 survey discipline.
  This lesson is the **encoding-time** sibling.
- `.claude/rules/bug_fix_survey.md` — same-class-cases grep before
  bug fixes. This lesson is the **rule-authoring-time** sibling.
- `.dev/lessons/2026-05-09-v1-monolith-file-survey-miss.md` — same
  class of failure: reading file names without grepping wider
  tree.
- `.claude/rules/phase9_close_invariants.md` — the artifact whose
  authoring surfaced this lesson.
