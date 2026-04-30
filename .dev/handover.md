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

- **Phase**: **Phase 2 IN-PROGRESS.** Phases 0 + 1 are `DONE`.
  §9.2 / 2.0 (`243d9ba`) is `[x]`: interp scaffold (Value /
  Trap / Frame / Runtime with bounded operand+frame stacks).
  The first remaining `[ ]` is **§9.2 / 2.1 —
  `src/interp/dispatch.zig`** (threaded-code dispatch loop
  reading `DispatchTable.interp`).
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

## Active task — §9.2 / 2.1 (`src/interp/dispatch.zig`)

§9.2 / 2.0 closed at `243d9ba`. `src/interp/mod.zig` exposes
`Value` (extern union, 8 bytes; bits64 carries IEEE-754),
`Trap` (Unreachable / DivByZero / IntOverflow / OOB family /
IndirectCallTypeMismatch / StackOverflow / CallStackExhausted),
`Frame { sig, locals, operand_base, pc }`, and `Runtime` with
inline 4096-slot operand stack + 256-slot frame stack plus
heap-backed `memory` and `globals`. No execution semantics yet.

§9.2 / 2.1 lands the **threaded-code dispatch loop** in
`src/interp/dispatch.zig` (Zone 2 — may import Zone 0 + 1, plus
sibling `src/interp/mod.zig`). Scope:

- A `step(rt: *Runtime, instr: *const ZirInstr) Trap!void` that
  looks up `DispatchTable.interp[@intFromEnum(instr.op)]` and
  invokes it with an `*InterpCtx` cast back to `*Runtime`.
- A `run(rt: *Runtime, table: *const DispatchTable, instrs: []const ZirInstr)` outer loop that walks instrs by `pc` until the
  current frame's body ends.
- A wiring path from frontend output (`ZirFunc`) through the
  table to one or two MVP handlers as a smoke (e.g. `i32.const`
  + `drop` + `end` so the loop terminates cleanly).
- The full MVP handler set lands in 2.2; 2.1 is just the
  dispatcher.

Tests: register a stub `i32.const` handler that pushes `42`,
plus a stub `end` that pops the frame; `run` over a synthetic
ZirInstr stream lands `42` on the operand stack.

Step 0 (Survey) for 2.1: wasm3's `m3_exec.c` (tail-call
dispatch idiom — likely a divergence target since Zig doesn't
guarantee tail-calls); zwasm v1's interp dispatch loop;
ROADMAP §4.3 (engine pipeline) and §A12 (no pervasive
build-time `if` — dispatch table only).

## Historical (§9.1 / 1.9) — IN-PROGRESS prior to close


§9.1 / 1.9 is large and lands across multiple commits. Progress
so far on top of `8ab5b55` (1.8 close):

1. `9e1440a` — `src/frontend/sections.zig` decodeTypes.
2. `29a4d3d` — decodeFunctions ([]u32 typeidx) + decodeCodes.
3. `4e82121` — runner drives validator per function.
4. `bb6a3a2` — validator extended to full Wasm 1.0 numeric +
   control + memory coverage; call (with func_types).
5. `354e4c6` — globals: decodeGlobals + global.get / global.set
   with `globals: []const GlobalEntry` parameter.
6. `62d2991` — call_indirect (0x11) + new `module_types`
   parameter (the type-section table separate from per-function
   func_types).

Probed against wast2json-baked upstream samples:
- ✅ PASS: const.0.wasm, nop.0.wasm (full call/call_indirect/
  globals/select/etc. exercised).
- ❌ FAIL with NotImplemented: i32.0.wasm / i64.0.wasm
  (i32.extend8_s / i64.extend8_s — Wasm 2.0 sign-extension);
  conversions.0.wasm (i32.trunc_sat_* — Wasm 2.0 saturating
  truncation, prefix opcode 0xFC).

Remaining for 1.9 close (in priority order):

- **Imports decoder**: `import` section. Function imports
  prepend the func_idx space, so without it any module that
  imports anything misindexes. Add to `sections.zig` and
  thread the resulting `func_types` (imports + defined) through
  the runner.
- **Corpus selection** for the Phase-1 gate: the upstream
  `~/Documents/OSS/WebAssembly/spec/test/core/` corpus tests
  Wasm 1.0 + 2.0 + 3.0 features in a single tree. For the
  Wasm-1.0 (MVP) gate we either (a) hand-curate a list of
  `.wast` files known to be MVP-only, OR (b) keep the post-MVP
  opcodes returning `NotImplemented` and treat MVP-pure files
  as the gate (the "skip=0" portion of the gate will need an
  ADR if option (b) is chosen).
- **`.wast` directive handling**: the script files contain
  `(assert_invalid ...)` / `(assert_malformed ...)` marking
  modules **expected to fail**. The runner needs to read the
  wast2json metadata (the `commands[]` array with `module_type`
  / `assertion` directives) and invert pass/fail expectation
  per module. Without this, `assert_invalid` files
  legitimately fail-to-validate but the runner reports them
  as failures.
- **Vendor scaffolding**: `scripts/regen_test_data.sh`
  invoking `wast2json`, output gitignored at `test/spec/json/`,
  upstream commit pinned in `test/spec/README.md`.
- **Three-host gate**: Mac aarch64 + OrbStack Ubuntu x86_64 +
  windowsmini SSH all return EXIT=0 on the chosen corpus.

Step 0 (Survey) for next chunk: zware's imports decoder
(`module.zig`); wasm-tools `wast2json` metadata JSON shape
(the `commands[]` array and `module_type` field); ROADMAP §11 /
§A10 (vendor policy + skip=0 release gate).

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
