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
  1.0 (`src/util/leb128.zig`, commit `922521f`) and 1.1
  (`src/ir/zir.zig` skeleton, commit `9305414`) are `[x]`. The
  first remaining `[ ]` is **§9.1 / 1.2 — declare the full
  `ZirOp` enum catalogue** per ROADMAP §4.2.
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

## Active task — §9.1 / 1.2 (full `ZirOp` enum catalogue)

§9.1 / 1.1 closed at `9305414`. `src/ir/zir.zig` mirrors §4.2's
`ZirFunc` shape verbatim with all `?T` slots reserved day 1
(Liveness, LoopInfo, ConstantPool, RegClass, SpillSlot,
CacheLayout, LaneRouting, GcRootMap, LandingPad, TailCallSite,
HoistedConst, ElisionRecord, CoalesceRecord). `ZirOp` itself is
still the open enum stub `enum(u16) { _ }` — task 1.2 fills it.

§9.1 / 1.2 must **declare** every entry from ROADMAP §4.2 lines
~248–605 (Wasm 3.0 ops + Phase 3 / 4 proposal ops + JIT
pseudo-ops). "Declared" = the enum tags exist; no handler / lower
/ emit code is required. The verifying test should assert that
the enum has at least N tags and that core MVP ops
(`i32.const`, `i32.add`, `local.get`, `block`, `loop`, `if`,
`br`, `br_if`, `call`, `call_indirect`, `drop`, `select`,
`return`, `nop`, `unreachable`, `end`, `else`) are present.

Step 0 (Survey) for 1.2: read ROADMAP §4.2 directly and verify
no entries are missed. Cross-check with the Wasm 3.0 spec
opcode listing in `~/Documents/OSS/WebAssembly/spec/document/`
and zwasm v1's opcode enum (read never copy). Identify the
JIT pseudo-ops that v2 adds beyond Wasm spec ops (e.g.,
mov-coalesce hints, hoisted-constant materialise, prologue /
epilogue markers).

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
