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
  1.7 (`702bc30`), 1.8 (`8ab5b55`) are `[x]`. The full MVP
  frontend stack + `zig build test-spec` infrastructure is in
  place. The first remaining `[ ]` is **§9.1 / 1.9 — Wasm Core
  1.0 (MVP) spec corpus decodes + validates fail=0 / skip=0 on
  all three hosts**.
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

## Active task — §9.1 / 1.9 (Wasm 1.0 corpus fail=0 / skip=0 gate) — IN-PROGRESS

§9.1 / 1.9 is large and lands across multiple commits. Progress
so far on top of `8ab5b55` (1.8 close):

1. `9e1440a` — `src/frontend/sections.zig` decodeTypes (arena-
   owned `Types`, vec(functype) for Wasm-1.0 valtypes).
2. `29a4d3d` — adds decodeFunctions ([]u32 typeidx) and
   decodeCodes (Codes; locals expanded from `(count valtype)`
   decls; body borrowed from input).
3. `4e82121` — runner upgrade: per-function validator drive
   via `Module.find` + section decoders. Smoke modules with no
   code section short-circuit to PASS.
4. `bb6a3a2` — validator extended from MVP smoke set to full
   Wasm 1.0 numeric + control + memory coverage:
   br_if / br_table / return / call (with module func_types) /
   select; load*/store* with memarg; memory.size / memory.grow;
   every i32/i64/f32/f64 binop / relop / unop / testop; full
   numeric conversion lattice. `validateFunction` signature is
   now `(sig, locals, body, func_types)`.

Remaining for 1.9 close:

- **Globals**: `global.get` (0x23) and `global.set` (0x24)
  require a module-wide `global_types: []ValType` (with
  mutability). Add `decodeGlobals` to sections.zig + plumb
  through the validator API + runner.
- **Imports**: `import` section decoder. Imported functions
  prepend to the func_types index space, so the runner needs
  to read them before mapping function indices to code bodies.
- **Corpus vendor**: copy `~/Documents/OSS/WebAssembly/spec/
  test/core/*.wast` (Wasm 1.0-only files) into
  `test/spec/wat/`; add `scripts/regen_test_data.sh` (wast2json
  wrapper) producing `test/spec/json/` (gitignored). Pin
  upstream commit in a README per ROADMAP §11.
- **`.wast` directive handling**: the script files contain
  `(assert_invalid ...)` / `(assert_malformed ...)` directives
  marking modules **expected to fail**. The runner needs to
  read the wast2json metadata and invert success/failure
  expectation per directive, otherwise skip=0 cannot hold.
- **Three-host gate**: Mac aarch64 + OrbStack Ubuntu x86_64 +
  windowsmini SSH all return EXIT=0 on the full corpus.

Failure modes already known to handle (and exercise after each
chunk lands): out-of-range func/type/local indices; bad
blocktype / valtype bytes; memarg truncation; trailing bytes
in any section.

Step 0 (Survey) for next chunk: zware's globals + imports
decoders (`module.zig`); wasm-tools `wast2json` metadata JSON
shape (the `commands[]` array and `module_type` field); ROADMAP
§11 / §A10 (vendor policy + skip=0 release gate).

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
