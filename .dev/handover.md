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

## Active task — §9.1 / 1.9 (Wasm 1.0 corpus fail=0 / skip=0 gate)

§9.1 / 1.8 closed at `8ab5b55`. `zig build test-spec` runs an
addExecutable rooted at `test/spec/runner.zig` that walks a
corpus directory, parses each `.wasm` via the frontend parser,
and exits non-zero on any failure. The runner imports the
frontend through a new `zwasm_lib` module re-exported from
`src/main.zig` (`pub const parser / validator / lowerer = ...`).
The 1.8 smoke corpus at `test/spec/smoke/{empty,single_func,
block}.wasm` was hand-baked via wat2wasm and is committed for
hermetic three-host runs. `test-all` now depends on test-spec.
**Section-body decoders for type / function / code are still
not implemented** — the runner exercises only the parser
(structural decode); validate + lower are not yet driven on the
corpus.

§9.1 / 1.9 closes Phase 1 by delivering the **Wasm Core 1.0
(MVP) corpus fail=0 / skip=0 gate** across Mac + OrbStack +
windowsmini. Scope:

- Add type / function / code section-body decoders in
  `src/frontend/sections.zig` (or split per section). Each
  decodes the raw section bytes into structured data:
  - type:     `[]FuncType` (params + results)
  - function: `[]u32` (per-function type_idx)
  - code:     `[](sig, locals, body_bytes)` per function
- Vendor the upstream Wasm 1.0 MVP corpus: copy
  `~/Documents/OSS/WebAssembly/spec/test/core/*.wast` (Wasm 1.0
  files only; defer 2.0 / 3.0 to later phases) into
  `test/spec/wat/` per ROADMAP §5 layout. Pin the upstream
  commit hash in a sidecar README. Add
  `scripts/regen_test_data.sh` invoking `wast2json` to bake
  `.wat` → `.wasm` into `test/spec/json/` (gitignored).
- Upgrade `test/spec/runner.zig` to drive parser → section
  decoders → validator + lowerer per function. The fail=0 /
  skip=0 gate is the corpus passing on Mac + OrbStack +
  windowsmini.
- `test/spec/smoke/` retains the small hand-baked smoke corpus
  for fast PR-loop runs; the bigger json/ corpus is the gate.

Tests: `zig build test-spec` returns 0 on the full vendored MVP
corpus on each host. Any single failure is a release-blocker
per ROADMAP §A10.

Step 0 (Survey) for 1.9: the upstream corpus's `.wast` directive
shapes (`(module ...)`, `(module binary ...)`, `(assert_invalid
...)`, etc.); zwasm v1's spec runner output JSON shape — what
fields it relied on; how to filter Wasm-2.0/3.0-only `.wast`
files. Cite ROADMAP §11 / §A10.

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
