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
  (`d2578ea`), 1.4 (`bbc5aca`), 1.5 (`73eaef9`), 1.6 (`36c4834`)
  are `[x]`. ZIR shape + ZirOp catalogue + DispatchTable +
  module / section iterator + MVP-subset validator + wasm-op →
  ZirOp lowerer are all in place. The first remaining `[ ]` is
  **§9.1 / 1.7 — `src/feature/mvp/`** (MVP feature handlers +
  `register(*DispatchTable)` wiring).
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

## Active task — §9.1 / 1.7 (`src/feature/mvp/`)

§9.1 / 1.6 closed at `36c4834`. `src/frontend/lowerer.zig`
exposes `lowerFunctionBody(alloc, body, *ZirFunc) → !void`. It
walks a validated body once, emitting `ZirInstr`s into the
caller's `ZirFunc.instrs` and pushing/patching `BlockInfo`s
into `ZirFunc.blocks`. Immediate packing: `i32.const` →
`payload` (bitcast u32); `i64.const` / `f64.const` split
low32+high32 across `payload`+`extra`; `f32.const` raw LE bits in
`payload`; local index / br depth in `payload`; `block`/`loop`/
`if` carry block_index in `payload` and the raw blocktype byte in
`extra`. Opcode coverage mirrors validator's MVP smoke set;
others return `Error.NotImplemented`. Survey note at
`private/notes/p1-1.6-survey.md`.

§9.1 / 1.7 lands the **MVP feature handlers + DispatchTable
wiring** in `src/feature/mvp/` (Zone 1 — may import `ir/`,
`util/leb128.zig`, `frontend/`). Scope:

- per-feature module(s) under `src/feature/mvp/<feature>.zig`,
  each exposing a `register(*DispatchTable)` per ROADMAP §4.5 /
  §A12 (no pervasive build-time `if`).
- migrate the validator's giant switch (§9.1 / 1.5) and the
  lowerer's giant switch (§9.1 / 1.6) into per-opcode handlers
  registered through `DispatchTable.parsers` (lowerer side) and
  the validator-handler slot (whichever shape lands here — this
  task may need to extend `DispatchTable` to add a validator
  slot; flag any §4.5 deviation in an ADR per §18 if so).
- after the migration, the validator + lowerer should drop their
  inline switch and call the dispatch table. The remaining
  un-implemented MVP opcodes (those still returning
  `NotImplemented` in 1.5/1.6) get implemented as the matching
  feature handlers register here.

Tests: round-trip an MVP-shaped body byte → validator + lowerer
through the dispatch table → confirm same end-state as the
inline switch produced. Add at least one test per registered
feature module.

Step 0 (Survey) for 1.7: zwasm v1's `feature/mvp/` directory
layout (may not exist as such — v1 might inline features), the
existing `src/ir/dispatch_table.zig` from §9.1 / 1.3 to confirm
the slot shapes, and the wasmtime `wasmparser` per-proposal
trait split for grouping inspiration. Cite ROADMAP §A12 (no
pervasive `if`) explicitly.

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
