# Session handover

> Read this at session start. Update at session end (1–2 lines).
> Mutable, current-state only. Authoritative plan is `.dev/ROADMAP.md`.
> Future-Claude reads this in a fresh context window and must
> understand the state in < 30 seconds.

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file)
2. `.dev/ROADMAP.md` — find the IN-PROGRESS phase in §9, then its
   expanded `§9.<N>` task list; pick up the first `[ ]` task.
3. The most recent `.dev/decisions/NNNN_*.md` ADR (if any) — to
   recover load-bearing constraints in flight.

## Current state

- **Phase**: **Phase 0 IN-PROGRESS.** Skeleton landed; ROADMAP §9.0 /
  0.0 (bootstrap commit) is `[x]`. Next is §9.0 / 0.1 (Mac native
  build verify — already passes locally; just needs the §9.0 row to
  be flipped to `[x]` once handover is updated).
- **Branch**: `zwasm-from-scratch` (long-lived; v1 charter-derived,
  pushed to `origin/zwasm-from-scratch`).
- **Last commit on this branch** *(at the moment of bootstrap)*:
  `chore(p0): bootstrap zwasm v2 skeleton` — scaffolds CLAUDE.md,
  ROADMAP, skills, rules, scripts, ADR infrastructure
  (`.dev/decisions/0000_template.md` only). Subsequent commits will
  bump this line.
- **ADRs filed**: none. Founding decisions live in ROADMAP §1–§14.
  ADRs come into existence only when a deviation from ROADMAP is
  discovered during development (per §18).
- **Build status**: `zig build`, `zig build test`, `zig build test-all`
  all green on Mac native (aarch64-darwin) at bootstrap. OrbStack
  Ubuntu and `windowsmini` SSH have not yet been re-verified on this
  freshly-set-up machine — §9.0 tasks 0.2 and 0.3 cover that.
- **OrbStack VM `my-ubuntu-amd64`**: presumed available per the
  user's existing setup; §9.0 task 0.2 verifies via `orb info`.
- **`windowsmini` SSH host**: presumed reachable from this Mac per
  the user's existing zwasm v1 setup; §9.0 task 0.3 verifies via a
  smoke `ssh windowsmini "echo ok && zig version"`.

## Active task — §9.0 / 0.2

§9.0 / 0.0 (bootstrap), 0.1 (Mac build), 0.4 (hooks wired) are `[x]`
already (bootstrap commit `9bd21b2` plus the audit-fix follow-up).
The next concrete `[ ]` is **§9.0 / 0.2 — verify `zig build` on
OrbStack Ubuntu x86_64 native**.

If `orb info my-ubuntu-amd64` reports the VM does not exist on this
freshly-set-up Mac, surface to the user with the bootstrap recipe
in `.dev/orbstack_setup.md` and stop. Do not provision the VM
autonomously.

After 0.2 lands, 0.3 (`windowsmini` SSH smoke), 0.5 (full
`zig build test` on all three hosts), 0.6 (audit pass), 0.7
(open §9.1) follow in order.

**Retrievable identifiers**:

- ROADMAP §1 — mission, v0.1.0 = v1 parity + wasm-c-api
- ROADMAP §2 — P1-P14 (inviolable principles), A1-A12 (verifiable rules)
- ROADMAP §4 — architecture (Zone 0-3, ZIR, dispatch tables, AOT/JIT pipeline)
- ROADMAP §4.2 — full ZirOp catalogue (~600 ops, day-1 reserved)
- ROADMAP §9.0 — Phase 0 task list
- ROADMAP §11 — test strategy + test data policy
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
  Not strictly per-phase or per-N-commits.
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
