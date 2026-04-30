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
  1.0 (`922521f`), 1.1 (`9305414`), 1.2 (`c2cd9b5`) are `[x]`.
  The full ZirOp catalogue (Wasm 1.0 / 2.0 / 3.0 + Phase 3-4
  reserved + JIT pseudo-ops, ~280 tags) is now declared in
  `src/ir/zir.zig`. The first remaining `[ ]` is **§9.1 / 1.3 —
  `src/ir/dispatch_table.zig`** (table type + `register` API).
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

## Active task — §9.1 / 1.3 (`src/ir/dispatch_table.zig`)

§9.1 / 1.2 closed at `c2cd9b5`. `ZirOp` enum now contains the
full §4.2 catalogue (~280 named tags + open-enum sentinel `_,`).

§9.1 / 1.3 lands `src/ir/dispatch_table.zig` — the central
registry that maps each `ZirOp` to per-feature handler function
pointers (parser / interp / jit_arm64 / jit_x86 emitters). Per
ROADMAP §4.5 / A12 the table is the **only** allowed dispatch
mechanism for feature-conditional behaviour (no pervasive
build-time `if`). Phase 1 wires the type + `register` API; the
emit-side functions are `?fn(...)` slots filled per-feature in
1.7 (`src/feature/mvp/`). Phase 2+ populates interp / JIT
slots.

Step 0 (Survey) for 1.3: re-read ROADMAP §4.5 (lines ~719–774)
for the registration shape and §4.5 line 759-762 example. Check
zwasm v1 dispatch (read never copy). Identify whether the table
holds bare function pointers (`?*const fn(...)`) or a tagged
struct; pick a Zig 0.16 idiom that allows null-default + later
`register(*DispatchTable)` calls.

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

- Push gate for windowsmini: §9.1 / 1.0 (commit `922521f`) and
  the §9.0 / 0.7 phase-close commit (`2e11dcb`) await user
  approval to push to `origin/zwasm-from-scratch`. Until pushed,
  windowsmini cannot be exercised against the new code (its
  transport syncs from origin).

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
