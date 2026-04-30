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

- **Phase**: **Phase 0 IN-PROGRESS.** §9.0 / 0.0–0.6 are `[x]`.
  Only 0.7 remains (open §9.1 inline + flip the Phase Status
  widget). The previous session paused before 0.7 at user
  direction; **the next `/continue` invocation IS the explicit
  go-signal that releases that hold** (per the `continue` skill's
  "/continue itself is the go signal" rule). On resume, perform
  0.7 and proceed directly into §9.1's first task — no further
  pause needed.
- **Branch**: `zwasm-from-scratch` (long-lived; v1 charter-derived,
  pushed to `origin/zwasm-from-scratch`).
- **ADRs filed**: none. Founding decisions live in ROADMAP §1–§14.
  ADRs come into existence only when a deviation from ROADMAP is
  discovered during development (per §18).
- **Build status**: `zig build` and `zig build test` are green on
  Mac aarch64 native, OrbStack Ubuntu x86_64 (`my-ubuntu-amd64`),
  and `windowsmini` SSH. Three-host gate is live for Phase 0.
- **`windowsmini` layout**: cloned at
  `~/Documents/MyProducts/zwasm_from_scratch` (mirrors v1).
  `origin` = `git@github.com:clojurewasm/zwasm.git`, branch
  `zwasm-from-scratch`. `scripts/run_remote_windows.sh` syncs via
  `git fetch + reset --hard origin/zwasm-from-scratch` (rsync was
  the original draft; Windows mini PC has no rsync, so v2 reuses
  v1's git-pull discipline).

## Active task — §9.0 / 0.7 (release-on-resume)

§9.0 / 0.0 (bootstrap), 0.1 (Mac build), 0.2 (OrbStack build),
0.3 (windowsmini build), 0.4 (hooks), 0.5 (three-host `zig build
test` green), 0.6 (Phase-0 boundary `audit_scaffolding`) are `[x]`.
The audit produced `private/audit-2026-05-01.md` with **0 block /
0 soon / 4 watch** — Phase 0 is structurally healthy.

The only remaining task is **§9.0 / 0.7 — open §9.1 inline + flip
the Phase Status widget**. The previous session paused here at
user direction; the next `/continue` is the explicit go-signal
that releases the pause.

On resume, 0.7 means: expand the §9.1 task table inline (mirror
§9.0's structure: numbered `[ ]` table with the same Status column
shape), update the Phase Status widget (§9.0 → DONE, §9.1 →
IN-PROGRESS, "First open `[ ]` task" → §9.1 / 1.x), update this
handover to point at §9.1's first task, commit, then continue
straight into §9.1 / 1.0's Step 0 survey. Note: 0.7 touches a
load-bearing ROADMAP section (§9 phase rows / Phase Status
widget), but expanding the next phase's task table is a routine
status update, not a deviation — no ADR needed (the PreToolUse
hook will reprint the §18 decision rule when the edit fires).

**Retrievable identifiers**:

- ROADMAP §1 — mission, v0.1.0 = v1 parity + wasm-c-api
- ROADMAP §2 — P1-P14 (inviolable principles), A1-A12 (verifiable rules)
- ROADMAP §4 — architecture (Zone 0-3, ZIR, dispatch tables, AOT/JIT pipeline)
- ROADMAP §4.2 — full ZirOp catalogue (~600 ops, day-1 reserved)
- ROADMAP §9.0 — Phase 0 task list
- ROADMAP §11 — test strategy + test data policy
- ROADMAP §11.5 — three-OS gate (Mac / OrbStack / windowsmini)
- ROADMAP §13 — commit discipline + work loop
- ROADMAP §14 — forbidden actions
- ROADMAP §18 — amendment policy

## Open questions / blockers

(none — Phase 0 task list is the next concrete work)

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
