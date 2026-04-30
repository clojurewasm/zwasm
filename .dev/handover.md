# Session handover

> Read this at session start. Update at session end (1–2 lines).
> Mutable, current-state only. Authoritative plan is `.dev/ROADMAP.md`.
> Future-Claude reads this in a fresh context window and must
> understand the state in < 30 seconds.

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` — read the **Phase Status** widget at the top
   of §9 to find the IN-PROGRESS phase, then its expanded `§9.<N>`
   task list; pick up the first `[ ]` task.
3. The most recent `.dev/decisions/NNNN_*.md` ADR (if any) — to
   recover load-bearing deviations in flight.

## Current state

- **Phase**: **Phase 1 IN-PROGRESS.** Phase 0 is `DONE`. §9.1 /
  1.0 (`922521f`), 1.1 (`9305414`), 1.2 (`c2cd9b5`), 1.3
  (`d2578ea`), 1.4 (`bbc5aca`), 1.5 (`73eaef9`), 1.6 (`36c4834`),
  1.7 (`702bc30`) are `[x]`. The full MVP frontend stack is
  scaffolded: ZIR shape, ZirOp catalogue, DispatchTable, module /
  section iterator, validator, lowerer, and feature/mvp/mod.zig
  registering MVP handlers via `register(*DispatchTable)`. The
  first remaining `[ ]` is **§9.1 / 1.8 — vendor the Wasm Core
  1.0 spec corpus + add `zig build test-spec` runner**.
- **Branch**: `zwasm-from-scratch` (long-lived; v1 charter-derived,
  pushed to `origin/zwasm-from-scratch`).
- **ADRs filed**: none. Founding decisions live in ROADMAP §1–§14.
  ADRs come into existence only when a deviation from ROADMAP is
  discovered during development (per §18).
- **Build status**: `zig build` and `zig build test` are green on
  Mac aarch64 native, OrbStack Ubuntu x86_64 (`my-ubuntu-amd64`),
  and `windowsmini` SSH. Three-host gate is live; Phase 1 has no
  🔒 boundary gate (interpreter not yet wired) — see §9 / Phase 1.
- **`windowsmini` layout**: cloned at
  `~/Documents/MyProducts/zwasm_from_scratch` (mirrors v1).
  `origin` = `git@github.com:clojurewasm/zwasm.git`, branch
  `zwasm-from-scratch`. `scripts/run_remote_windows.sh` syncs via
  `git fetch + reset --hard origin/zwasm-from-scratch` (rsync was
  the original draft; Windows mini PC has no rsync, so v2 reuses
  v1's git-pull discipline).

## Active task — §9.1 / 1.8 (vendor spec corpus + test-spec runner)

§9.1 / 1.7 closed at `702bc30`. `src/feature/mvp/mod.zig`
exposes `register(*DispatchTable)` and installs MVP-opcode
handlers into the `parsers` slot for the smoke set (const ops
with low32/high32 splits for 64-bit, local-indexed via uleb32,
br depth, no-immediate ops). The new `src/frontend/parse_ctx.zig`
holds a concrete `Ctx` struct that handlers cast `*ParserCtx`
back to via `Ctx.fromOpaque`. **Important non-deviation**:
`DispatchTable`'s 4-slot shape is unchanged; no validator slot
was added (no ADR filed). The lowerer's inline switch in 1.6
remains the production code path for Phase 1; production
migration to dispatch-table consumption is deferred to Phase 2
(interp) when the table actually replaces the switch.

§9.1 / 1.8 lands **Wasm Core 1.0 spec corpus vendoring + the
`zig build test-spec` runner**. Scope:

- Decide the on-disk location for the vendored spec corpus
  (likely `test/spec/wasm-1.0/` per ROADMAP §11 layout).
  Source is `~/Documents/OSS/WebAssembly/spec/test/core/` (read,
  copy as snapshot — see `no_copy_from_v1.md` exception clause:
  spec testsuite is upstream artifact, copied verbatim).
- The corpus is `.wast` script-format; for 1.8 we only need the
  binary-decoded modules (the validator + lowerer stop before
  execution). Either:
  (a) vendor the `.wast` files plus a small Zig parser for the
      `(module binary "...")` directive, or
  (b) pre-bake `.wast` → `.wasm` via `wasm-tools wast2json` and
      vendor the `.wasm` outputs.
  Plan (a) keeps the corpus updateable from upstream; plan (b)
  reduces the runner's complexity. Survey both before deciding.
- Add `zig build test-spec` to `build.zig`. Phase 1's exit
  criterion is **decode + validate** fail=0 / skip=0 on the MVP
  subset; the runner walks the corpus, drives parser → validator
  → lowerer, and counts failures.
- The runner does NOT run the `(assert_*)` directives that need
  execution (those land in Phase 2 with the interpreter).

Tests: smoke that the runner finds at least one corpus file and
runs to completion. The **§9.1 / 1.9** task is the actual
"fail=0 / skip=0 across all three hosts" gate — 1.8 only
delivers the runner infrastructure.

Step 0 (Survey) for 1.8: zwasm v1's spec-test runner layout
(probably under `test/spec/`), the wasm-tools `wast2json` output
shape (in case we choose path b), and the upstream
`WebAssembly/testsuite` structure (curated subset of `spec/test/
core/`). Cite ROADMAP §11 (test data policy — "vendored verbatim,
upstream commit pinned").

**Retrievable identifiers**:

- ROADMAP §1 — mission, v0.1.0 = v1 parity + wasm-c-api
- ROADMAP §2 — P1-P14 (inviolable principles), A1-A12 (verifiable rules)
- ROADMAP §4 — architecture (Zone 0-3, ZIR, dispatch tables, AOT/JIT pipeline)
- ROADMAP §4.2 — full ZirOp catalogue (~600 ops, day-1 reserved)
- ROADMAP §9.0 — Phase 0 task list (DONE)
- ROADMAP §9.1 — Phase 1 task list (IN-PROGRESS)
- ROADMAP §11 — test strategy + test data policy
- ROADMAP §11.5 — three-OS gate (Mac / OrbStack / windowsmini)
- ROADMAP §13 — commit discipline + work loop
- ROADMAP §14 — forbidden actions
- ROADMAP §18 — amendment policy

## Open questions / blockers

(none — push to `origin/zwasm-from-scratch` is autonomous inside
the `/continue` loop per the skill's "Push policy"; no user
approval required. The next loop iteration will push outstanding
local commits before running the windowsmini gate.)

## Notes for the next session

- Skill `continue` (`.claude/skills/continue/SKILL.md`) handles
  "続けて" / "/continue" / "resume". It auto-triggers on those phrases
  and drives the per-task TDD loop autonomously. Stops only when the
  user intervenes or a problem cannot be solved (no other stop
  conditions).
- Skill `audit_scaffolding` runs at adaptive cadence (after large
  refactors, after scaffolding accretes, when something feels off).
  Not strictly per-phase or per-N-commits, but Phase 0 / 0.6 calls
  for one explicitly.
- Rule `.claude/rules/textbook_survey.md` — auto-loaded on
  `src/**/*.zig`; defines the Step 0 brief and the no-pull guardrails.
- Rule `.claude/rules/no_copy_from_v1.md` — explicit ban on
  copy-paste from zwasm v1.
- Rule `.claude/rules/no_workaround.md` — root-cause fixes only;
  abandoned-experiment ADRs preferred over ad-hoc patches.
- The 🔒 marker on Phases 0 / 2 / 4 / 7 / 9 / 12 / 15 means a fresh
  three-host gate is due at that phase boundary:
  Mac aarch64 native + OrbStack Ubuntu native + windowsmini SSH.
- CI workflows (`.github/workflows/*.yml`) are deliberately absent
  in Phase 0 — they appear in Phase 13 per ROADMAP §9. Local Mac +
  OrbStack + windowsmini covers all three platforms until then.
- **Windows transport limitation (Phase 14 follow-up)**:
  `scripts/run_remote_windows.sh` syncs via `git fetch + reset
  --hard origin/zwasm-from-scratch` — it tests **what is on origin**,
  not unpushed local commits. Phase 14 should add a `git bundle`
  path so pre-push gates also exercise in-flight commits before
  they land on the remote.
- **Stray-artifact commit hygiene**: when an unrelated file
  (`flake.lock`, `.direnv`, …) appears in `git status` mid-task,
  commit it under its own scope (`chore: pin <thing>`), don't
  bundle it into unrelated work. Helps `git log -- <file>` stay
  readable.
