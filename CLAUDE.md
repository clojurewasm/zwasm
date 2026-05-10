# zwasm v2

A from-scratch WebAssembly runtime in Zig 0.16.0.

> Project memory loaded by Claude Code on every session. Pointers
> only — detailed plans live in `.dev/ROADMAP.md`, runnable
> procedures in `.claude/skills/`, the canonical 3-host gate
> discipline in `.claude/skills/continue/LOOP.md`.

## Identity

**Project name (in all docs and the published artifact): `zwasm`.**
Binary / package: `zwasm`.

This branch is a ground-up redesign of zwasm on top of the v1 git
history (commit 517cc5a, charter):

- Working dir: `~/Documents/MyProducts/zwasm_from_scratch/`
  (distinct from `~/Documents/MyProducts/zwasm/`, the read-only
  v1 reference clone).
- Branch: `zwasm-from-scratch`. **Never push to `main`**; push to
  `zwasm-from-scratch` only with explicit user approval (or
  autonomously inside the `/continue` loop). `--force` always
  forbidden.
- v1 ABI compatibility is out of scope; `docs/migration_v1_to_v2.md`
  ships at v0.1.0 release time.

### Read-only reference clones

Read-only locations under `~/Documents/OSS/`, plus `zwasm/` (v1)
and `ClojureWasmFromScratch/` under `~/Documents/MyProducts/`. The
full list lives in [`.dev/reference_clones.md`](.dev/reference_clones.md);
the `additionalDirectories` setting in `.claude/settings.json`
mirrors it. Never edit or commit from any of these paths.

The investigation that motivated this project lives at
`~/zwasm/private/v2-investigation/` (CONCLUSION.md + surveys).
Treat it as v2 design rationale; ROADMAP.md is the operational
plan that descended from it.

## Language policy

Public project. **English by default** for code, comments,
identifiers, commit messages, README, ROADMAP, ADRs, `.dev/`,
`.claude/`, all configuration. **Japanese** for chat replies only.
Enforced by [`.claude/output_styles/japanese.md`](.claude/output_styles/japanese.md)
+ a SessionStart hook that re-injects the directive.

**Bilingual exception**: meta-prose pointers at the tail of an
otherwise-English file ("詳細は <ref> を参照。") and culturally-
loaded one-word labels (例: 気付いたら即追加, 裏取り) are allowed
when they anchor a concept more cleanly than the English
equivalent. Never use Japanese in normative rule text or code
identifiers.

zwasm v2 does **not** maintain `docs/ja/learn_zwasm/` chapters
(the CW v2 two-cadence learning material discipline is
intentionally dropped — P9). Knowledge compression lives in
ROADMAP narrative + ADRs (`.dev/decisions/`, written for
load-bearing ROADMAP deviations only — see ROADMAP §18).

## Working agreement

- TDD: red → green → refactor.
- **Step 0 (Survey) before each task**: Explore subagent surveys
  reference codebases (zwasm v1, wasmtime, zware, wasm3,
  wasm-c-api, Zig stdlib, regalloc2 when JIT-relevant) and lands
  200–400 lines under `private/notes/<phase>-<task>-survey.md`.
  Skip exception is narrow — see
  [`.claude/rules/textbook_survey.md`](.claude/rules/textbook_survey.md).
- **No copy-paste from v1** —
  [`.claude/rules/no_copy_from_v1.md`](.claude/rules/no_copy_from_v1.md)
  is load-bearing. Read v1; re-derive in v2.
- **3-host gate** (`zig build test` + `test-all` etc.) on Mac
  aarch64 + OrbStack Ubuntu x86_64 + `windowsmini` SSH.
  Per-chunk autonomous loop runs the **2-host subset (Mac +
  OrbStack)** per ADR-0049; windowsmini is reconciled at phase
  boundaries. Canonical invocation discipline (parallel,
  background, file-logged, no re-rerun for re-grep) lives in
  [`.claude/skills/continue/LOOP.md` §"Parallel test gate"](.claude/skills/continue/LOOP.md).
  Setup: [`.dev/orbstack_setup.md`](.dev/orbstack_setup.md),
  [`.dev/windows_ssh_setup.md`](.dev/windows_ssh_setup.md).
- Commit at the natural granularity of code changes.
  `private/notes/` is optional scratch.
- Subagent fork is the default for: Step 0 surveys, large test
  logs (>200 lines), cross-codebase searches (>5 files), audit /
  simplify / security-review fan-out.
- ROADMAP corrections follow [`ROADMAP §18`](.dev/ROADMAP.md#18-amendment-policy):
  edit in place as a now-snapshot. ADRs are required only for
  **load-bearing** changes (scope / exit criterion in §1, §2,
  §4, §5, §9 phase rows, §11, §14). Sub-chunk progress prose
  belongs in commit messages and `.dev/phase_log/<phase>.md`,
  not in §9 row cells (§18.3).
- `private/` is gitignored agent scratch and **not authoritative**.
  If a `private/` proposal matters, promote to ROADMAP / ADR /
  lesson / debt / `handover.md`.
- **Debt + lessons live in git, not in your head.**
  [`.dev/debt.md`](.dev/debt.md) is the ledger (refresh per
  `/continue` Step 0.5). [`.dev/lessons/`](.dev/lessons/) holds
  re-derivable observations ([`INDEX.md`](.dev/lessons/INDEX.md)
  is the keyword index — grep per Step 0.4). Boundary in
  [`.claude/rules/lessons_vs_adr.md`](.claude/rules/lessons_vs_adr.md).
- **Don't paper over absences.** Walk the 3-step procedure in
  [`.claude/rules/extended_challenge.md`](.claude/rules/extended_challenge.md)
  before declaring something missing or shipping a SKIP-X
  workaround.

## Skills (the runnable procedures)

- [`continue`](.claude/skills/continue/SKILL.md) — autonomous
  resume + per-task TDD loop. Triggers on "続けて" / "/continue"
  / "resume". Stops only on user intervention or
  provably-unsolvable problems (per `extended_challenge.md`).
- [`audit_scaffolding`](.claude/skills/audit_scaffolding/SKILL.md)
  — adaptive audit for staleness / bloat / lies / debt+lessons
  coherence / extended-challenge consistency across CLAUDE.md,
  `.dev/`, `.claude/`, `scripts/`.

## Layout (pointer)

`src/` Zig source (parse / validate / ir / runtime / instruction
/ feature / engine / interp / wasi / api / cli / diagnostic /
support / platform — shape per ADR-0023 + ADR-0024).
`include/` public C headers.
`build.zig` build script.
`flake.nix` Nix dev shell pinned to Zig 0.16.0.
`.dev/` ROADMAP + handover + debt + lessons + decisions +
phase_log + setup docs.
`.claude/` settings, skills, rules, output styles.
`scripts/` gate, zone_check, file_size_check, bench,
run_remote_windows, ...
`test/` unified `zig build test-all` aggregator + per-layer
suites.
`bench/` append-only benchmark history.
`private/` gitignored agent scratch.

## Build & test (pointer)

```sh
zig build               # compile
zig build test          # unit tests
zig build test-spec     # spec testsuite
zig build test-all      # all enabled layers
zig fmt src/            # format
```

Three-host invocation discipline (parallel, background,
file-logged, never re-rerun for re-grep) is in
[`.claude/skills/continue/LOOP.md`](.claude/skills/continue/LOOP.md).

## Pre-commit gate

Authoritative script:
[`scripts/gate_commit.sh`](scripts/gate_commit.sh) wraps the full
local gate (`zig build test`, `zone_check`, `file_size_check`,
`spill_aware_check`, `zig build lint`). The autonomous `/continue`
loop runs it per-task; manual commits should call it before
`git commit`.

Per-chunk parallel host gate is two-host (Mac + OrbStack) per
ADR-0049; windowsmini reconciliation is phase-boundary only.
The strict three-host `test-all` is the **A13 merge gate** —
required for any push to `main` and automated by
`scripts/gate_merge.sh`.

## References

- [`.dev/ROADMAP.md`](.dev/ROADMAP.md) — single source of truth
  for mission, principles, phase plan. If this file conflicts
  with ROADMAP, ROADMAP wins.
- [`.dev/handover.md`](.dev/handover.md) — current state (≤ 80
  lines, replaced not appended).
- [`.dev/debt.md`](.dev/debt.md) — debt ledger.
- [`.dev/lessons/`](.dev/lessons/) — observational notes (see
  `INDEX.md`).
- [`.dev/decisions/`](.dev/decisions/) — ADRs (load-bearing
  deviations only). See [`README.md`](.dev/decisions/README.md).
- [`.dev/phase_log/`](.dev/phase_log/) — sub-chunk records
  offloaded from §9 ROADMAP rows (per §18.3).
- [`.dev/proposal_watch.md`](.dev/proposal_watch.md) — Wasm
  proposal tracking (quarterly review).
