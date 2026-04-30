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
  (`d2578ea`), 1.4 (`bbc5aca`) are `[x]`. ZIR shape + ZirOp
  catalogue + DispatchTable type + module header / section
  iterator are all in place. The first remaining `[ ]` is
  **§9.1 / 1.5 — `src/frontend/validator.zig`** (type stack,
  control stack, polymorphic else/end markers).
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

## Active task — §9.1 / 1.5 (`src/frontend/validator.zig`)

§9.1 / 1.4 closed at `bbc5aca`. `src/frontend/parser.zig`
exposes `parse(alloc, input) → Module` with magic + version
validation, strict known-section ordering (data_count between
import and code), custom sections allowed anywhere, tag (id 13)
currently rejected as `UnknownSectionId`. Section bodies are
borrowed slices into `input`; no per-section decode runs in 1.4.
Tests cover empty module, bad magic / version, ordered iteration,
out-of-order, duplicates, custom interleaving, oversize section,
truncated leb128. Survey note at `private/notes/p1-1.4-survey.md`.

§9.1 / 1.5 lands the **type stack + control stack validator** in
`src/frontend/validator.zig` (Zone 1 — may import `ir/`,
`util/leb128.zig`, and the new parser). Scope:

- per-function value-stack tracking against `FuncType.params /
  results` and declared locals.
- control stack with frames for `block` / `loop` / `if` / `else`
  carrying the entry/exit type signature.
- polymorphic markers after `unreachable` / `else` / `end` so
  the spec's "polymorphic stack" rule is honoured exactly.
- only the MVP opcode set in this task; bulk-memory / SIMD /
  GC / tail-call validation is layered on in their feature
  modules at §9.1 / 1.7.

Tests: empty function (no opcodes), single `i32.const + drop`,
nested block / br typing, mismatched arity, polymorphic stack
after `unreachable`. Section-body decode for type / function /
code lives here (the validator needs to read the body before it
can stack-check), so 1.5 is also the natural place for the
Wasm-1.0 type / func / code body decoders. 1.6 then lowers the
validated stream into `ZirOp`s.

Step 0 (Survey) for 1.5: zwasm v1's `frontend/validator.zig`,
zware's `validator.zig`, wasmtime's `crates/wasmparser/.../validator/`,
the WebAssembly spec §3 (validation) text. Cite ROADMAP §P1
(spec fidelity) and the polymorphic-stack rule explicitly when
designing the control-stack invariants.

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
