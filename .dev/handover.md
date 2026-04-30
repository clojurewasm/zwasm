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
  (`d2578ea`), 1.4 (`bbc5aca`), 1.5 (`73eaef9`) are `[x]`. ZIR
  shape + ZirOp catalogue + DispatchTable + module / section
  iterator + MVP-subset validator with polymorphic-stack rule
  are all in place. The first remaining `[ ]` is
  **§9.1 / 1.6 — `src/frontend/lowerer.zig`** (wasm-op → ZirOp
  lowering for the MVP subset).
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

## Active task — §9.1 / 1.6 (`src/frontend/lowerer.zig`)

§9.1 / 1.5 closed at `73eaef9`. `src/frontend/validator.zig`
exposes `validateFunction(sig, locals, body) → !void`. Internally
it uses bounded inline stacks (operand 1024 / control 256) and a
`TypeOrBot` sentinel for the polymorphic-stack window per spec
§3.3.5. The opcode dispatch is a switch covering the MVP smoke
set; **un-implemented MVP opcodes return `Error.NotImplemented`**
on purpose — the giant switch migrates to dispatch-table lookup
when feature modules register at §9.1 / 1.7. Multivalue block
type and untyped `select_typed` (Wasm 2.0) are deliberately
deferred. Survey note at `private/notes/p1-1.5-survey.md`.

§9.1 / 1.6 lands the **wasm-op → ZirOp lowerer** in
`src/frontend/lowerer.zig` (Zone 1 — may import `ir/`,
`util/leb128.zig`, frontend/parser, frontend/validator). Scope:

- single pass over a function-body expression, emitting a
  `ZirInstr` stream into a `ZirFunc` (ROADMAP §4.2 shape — already
  declared in `src/ir/zir.zig` as of §9.1 / 1.1).
- maps each MVP wasm opcode to the matching `ZirOp` tag (e.g.
  `0x6A` → `.@"i32.add"`). Block / loop / if / else / end produce
  the corresponding control-flow ZirOps and populate
  `ZirFunc.blocks` (start_inst / end_inst).
- consumes immediates and stashes them into `ZirInstr.payload` /
  `extra` (e.g. `i32.const` value, local index). Memarg-bearing
  ops are deferred to the feature-module wiring in 1.7.
- **does not** re-validate; lowerer assumes a validator pass has
  already accepted the body. (1.7 will compose them via dispatch
  table; until then both run independently as per-task tests.)

Tests: lower an empty function frame; lower a const + drop +
end sequence; lower a nested block with br; verify
`ZirFunc.instrs.items[i].op` matches the expected `ZirOp` tag and
payloads round-trip immediates correctly. The validator's
operator coverage (control flow + locals + const + i32 add/sub
/mul/eqz + drop) is the lower-bound for 1.6 too.

Step 0 (Survey) for 1.6: zwasm v1's `frontend/lowerer.zig` (or
the equivalent — v1 may have folded lowering into validator);
wasmtime's `crates/cranelift-codegen/src/...` for the CLIF
shape that informs ZirOp encoding choices; the `ZirOp` catalogue
in `src/ir/zir.zig` (already complete). Cite ROADMAP §P13 / §4.2
(slot-typed IR, day-1 catalogue) when deciding payload encoding.

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
