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
  §9.2 / 2.0 (`243d9ba`), 2.1 (`f292ae7`) are `[x]`. interp
  scaffold + dispatch loop are wired; an unbound `DispatchTable.
  interp` slot trips `Trap.Unreachable`. The first remaining
  `[ ]` is **§9.2 / 2.2 — `src/feature/mvp/` interp handlers**
  (numeric / control / memory MVP opcodes registered into
  `DispatchTable.interp`).
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

## Active task — §9.2 / 2.2 (MVP interp handlers) — IN-PROGRESS

§9.2 / 2.2 lands across multiple chunks. Progress so far on top
of `f292ae7` (2.1 close):

1. `ead0fe3` — chunk-1: i32 numeric (15 binops + 10 relops + 3
   unops + eqz) + consts (4) + drop + locals + globals.
2. `0558114` — chunk-2: i64 numeric (mirror of i32; 15+10+3+1).
3. `3ddb61c` — chunk-3: f32 / f64 numeric (6 relops + 7 unops +
   7 binops per width). NaN propagation explicit on min/max;
   strict canonical-NaN deferred to 2.4.
4. `bda2cae3` — chunk-4: numeric conversions (wrap, extend,
   trunc with InvalidConversionToInt / IntOverflow traps,
   convert, demote, promote, reinterpret).
5. `6caf492` — lowerer extension to mirror validator's full
   Wasm-1.0 coverage (br_if, br_table with branch_targets
   side-table, call, call_indirect, select, globals,
   loads/stores with memarg payload encoding, memory.size /
   grow, full numeric, full conversions).
6. `24fd6fc` — chunk-5: load / store / memory.size / memory.grow
   interp handlers. Effective addr = base + memarg.offset; OOB
   trips Trap.OutOfBoundsLoad / Store. Wasm page = 64 KiB.

`src/interp/mvp.zig` is now 1771 / 2000 lines. **File-split
refactor required before chunk 6** (control flow) + chunk 7
(call) push past the hard cap. Likely shape:
- `src/interp/int_ops.zig` (i32 + i64) — ~700 lines
- `src/interp/float_ops.zig` (f32 + f64) — ~400 lines
- `src/interp/conversions.zig` — ~250 lines
- `src/interp/memory_ops.zig` — ~250 lines
- `src/interp/mvp.zig` (aggregator + control + call + select +
  consts + drop + locals + globals) — ~400 lines

Remaining chunks for 2.2:
- chunk 6 control flow (block / loop / if / else / end / br /
  br_if / br_table / return) — needs dispatch loop refactor to
  read pc from `rt.currentFrame().pc` instead of a local.
- chunk 7 call / call_indirect — pushes a Frame with the callee's
  locals (params from operand stack + zero-init declared locals).
- `select` is already wired in chunk-1 dispatch via the validator's
  pattern, but the interp handler still needs to be added.

**Zone placement note**: `src/interp/mvp.zig` is Zone 2, not
Zone 1, because it imports `src/interp/mod.zig` for Runtime +
Value + Trap. ROADMAP §4.5's "feature modules" concept splits
per-engine: parser-side handlers stay in `src/feature/mvp/mod.zig`
(Zone 1), engine-side handlers live with their engine.

Remaining 2.2 chunks:

- **chunk 2 (i64 numeric)** — same shape as i32: 15 binops + 10
  relops + 3 unops + eqz.
- **chunk 3 (f32 / f64 numeric)** — 6 relops + 7 unops + 7 binops
  per width. NaN canonicalisation deferred to 2.4.
- **chunk 4 (conversions)** — wrap, extend, trunc (with
  InvalidConversionToInt traps), convert, demote / promote,
  reinterpret.
- **chunk 5 (loads / stores + memory.size / memory.grow)** —
  effective-address = `i32 base + memarg.offset`; `OutOfBoundsLoad`
  / `OutOfBoundsStore` against `rt.memory`.
- **chunk 6 (control flow)** — block / loop / if / else / end /
  br / br_if / br_table / return. These mutate the current
  frame's `pc` (the dispatch loop's outer `while` already advances
  pc by 1 per step; control flow handlers will need to subtract
  to keep the increment happy, OR the loop refactors to a
  `read pc → step → handler-set-pc` shape). Needs a small
  redesign of `dispatch.zig`'s `run` to consult `frame.pc`
  instead of a local.
- **chunk 7 (call / call_indirect)** — pushes a new Frame onto
  the runtime's frame stack with the callee's locals (params
  popped from operand stack + zeros for declared locals).
- **chunk 8 (select)** — pop i32 cond + 2 values, push the
  matching one.

Scope discipline: one chunk per turn (chunks are 2-5 commits each).

§9.2 / 2.2 wires the **MVP interp handlers** into
`DispatchTable.interp` via a new `src/feature/mvp/interp.zig`
(or by extending the existing `src/feature/mvp/mod.zig`). Scope:

- one handler per Wasm-1.0 numeric/control/memory opcode
  matching the validator's coverage (i32/i64/f32/f64
  binops/relops/unops/testops, control flow, locals/globals,
  load/store, const, drop, select, call, call_indirect).
- spec-conformant trap behaviour where the operation can fail
  (DivByZero on `div_*`/`rem_*`, IntOverflow on `*.div_s`
  INT_MIN/-1, InvalidConversionToInt on truncation, OOB on
  load/store).
- registration helper `register(*DispatchTable)` populating
  `interp` slots (the existing `parsers`-slot registration in
  `mod.zig` from §9.1 / 1.7 stays; both can co-exist).

Tests: drive `run` over each handler via a tiny ZIR stream
producing the expected operand-stack residue or trap. At least
one round-trip test per opcode group (integer arith / float
arith / load-store / control-flow / locals).

Step 0 (Survey) for 2.2: zwasm v1's per-opcode interp handlers
(probably under `src/interp/handlers/`); wasm3 source for
floating-point edge-case handling (NaN canonicalisation, signed
zero); ROADMAP §4.3 (engine pipeline shared with JIT/AOT) and
§4.8 (Float and SIMD strategy — float invariants Phase 2 must
honour).

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
