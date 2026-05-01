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

- **Phase**: **Phase 3 IN-PROGRESS.** Phases 0 + 1 + 2 are
  `DONE`. §9.3 / 3.0 closed at `05bd4e4`; §9.3 / 3.1 closed at
  `19c5228` (`include/README.md` documents the vendor policy +
  bump workflow; `build.zig` adds `include/` to exe_mod's
  include path). §9.3 / 3.2 closed at `9abb951`
  (`src/c_api/wasm_c_api.zig` Zone-3 shapes:
  Engine/Store/Module/Instance/Func/Trap + ValKind / Val /
  ByteVec). §9.3 / 3.3 closed at `b4d1146` — first concrete
  binding pair `wasm_engine_new` / `wasm_engine_delete`
  exported with C linkage; build.zig links libc. §9.3 / 3.3b
  closed at `647dfc7` — `wasm_store_new` / `wasm_store_delete`
  (Store carries an Engine back-pointer for allocator
  recovery). §9.3 / 3.4 closed at `7c321d5` —
  `wasm_module_new` / `_module_validate` / `_module_delete`
  wrap parser + sections + validator. §9.3 / 3.5 closed at
  `0417675` — `wasm_instance_new` / `wasm_instance_delete`
  wire the Instance lifetime; Instance owns a heap-allocated
  `interp.Runtime` allocated through Store→Engine. The first
  remaining `[ ]` is **§9.3 / 3.6 — `wasm_func_call`**. 3.6
  splits into chunks: 3.6a closed at `00f4d9e` —
  `wasm_instance_new` now decodes the Module bytes into the
  owned Runtime (per-instance `ArenaAllocator` backs types +
  lowered `ZirFunc`s + the func-pointer table; `Instance` is now
  a regular `struct` since C only sees the opaque pointer). 3.6b
  is the dispatch surface (`wasm_func_call` + Func handle +
  arg/result `wasm_val_t` marshalling) — that is the next chunk.
- **Branch**: `zwasm-from-scratch` (long-lived; v1 charter-derived,
  pushed to `origin/zwasm-from-scratch`).
- **ADRs filed**:
  - `0001_phase1_corpus_vendor_split.md` — split of §9.1 / 1.8
    (smoke) and 1.9 (corpus) vendoring.
  - `0002_phase1_mvp_corpus_curation.md` — §1.9's curated
    Wasm-1.0-pure subset; runner closes the gate against it.
  - `0003_phase2_wasm_2_0_corpus_curation.md` — §9.2 / 2.8's
    curated Wasm-2.0 subset (50 corpora / 1158 modules /
    fail=0); mirrors ADR-0002.
  - `0004_phase3_wasm_c_api_pin.md` — pins upstream wasm-c-api
    commit `9d6b9376…` for the vendored `include/wasm.h`.
- **Build status**: `zig build test`, `test-spec`,
  `test-spec-wasm-2.0`, `test-realworld`, `test-all` are all
  green on Mac aarch64 native, OrbStack Ubuntu x86_64
  (`my-ubuntu-amd64`), and `windowsmini` SSH. Three-host gate is
  live; the 🔒 Phase-2 boundary gate (per §9 / Phase 2) is now
  satisfied per the Phase Status widget.
- **`windowsmini` layout**: cloned at
  `~/Documents/MyProducts/zwasm_from_scratch` (mirrors v1).
  `origin` = `git@github.com:clojurewasm/zwasm.git`, branch
  `zwasm-from-scratch`. `scripts/run_remote_windows.sh` syncs via
  `git fetch + reset --hard origin/zwasm-from-scratch` (rsync was
  the original draft; Windows mini PC has no rsync, so v2 reuses
  v1's git-pull discipline).

## Active task — §9.3 / 3.6 chunk b (wasm_func_call surface)

3.6a (Module → Runtime instantiation in `wasm_instance_new`)
landed at `00f4d9e`. Remaining for 3.6:

1. Add a Func handle that resolves to `(instance, func_idx)`.
   Either expose a project-extension helper
   (`zwasm_instance_get_func(*Instance, u32) *Func`) for first
   pass — folding into the standard `wasm_instance_exports`
   shape comes alongside `wasm_extern_vec_t` in §9.3 / 3.7.
2. Wire `wasm_func_call(*Func, *wasm_val_vec_t args,
   *wasm_val_vec_t results)`: marshal input `wasm_val_t`s onto
   `Runtime.operand`, push the entry frame with the right
   FuncType + locals slice, run `interp.dispatch.run` over the
   ZirFunc body, marshal `Runtime.operand` results back to the
   `wasm_val_vec_t`. The dispatch table comes from
   `interp.feature.mvp` (or wherever the standard MVP table is
   built — check `src/feature/mvp/mod.zig`).
3. Trap surface stays stubbed: on a Trap error from `dispatch.run`,
   return a non-null sentinel `*Trap`. The message body and
   proper `wasm_trap_t` lifetime land in §9.3 / 3.7.

The realworld toolchain wasms (cpp_struct_test etc.) parse but
won't dispatch yet because they pull in WASI imports. The first
dispatch test should use a hand-rolled `(func (result i32)
(i32.const 42))` body so it stays import-free.

Note for 3.2+ work: a `@cImport` smoke test catches "header
unreachable" regressions but tripped Rosetta on OrbStack
(translate-c bss_size overflow). Defer header-parse smoke to
the C-host test step in §9.3 / 3.9 (`zig build test-c-api`)
where it can run via the host C compiler instead of
translate-c.

## Phase-2 audit `soon` / `watch` carry-over

From `private/audit-2026-05-02.md` (Phase-2 boundary):

- `soon`: mvp.zig 1965 / 2000 lines (split into int_ops /
  float_ops / conversions queued for Phase 5 analysis layer).
- `soon`: validator.zig 1426 lines over §A2 soft cap; lowerer
  1062 likewise. ADR for split plan is the gating step.
- `soon`: proposal_watch quarterly refresh due 2026-07-30.
- `watch`: missing `test/spec/wasm-2.0/README.md` documenting
  the upstream-pin per ADR-0003. Land alongside Phase-3 setup
  if convenient.

## Phase-2 deferred items (queued for Phase 3+ / Phase 14)

- **chunk 3b** — multi-param multivalue blocks. Needs `BlockType`
  to carry both params and results; `pushFrame` to consume params.
- **chunk 5d-3** — element-section forms 2/4-7 (explicit-tableidx
  and expression-list variants).
- **chunk 5e** — ref.func §5.4.1.4 strict declaration-scope check.
- **mvp.zig file split** — int_ops / float_ops / conversions
  modules, per the §A2 1000-line soft cap. Tracked as `soon` in
  the audit.
- **Wasm-2.0 corpus expansion** — 47 of 97 upstream `.wast` files
  are deferred (block / loop / if 1-5 fails each, global 24, data
  20, ref_* 2-6, return_call* 3-5, etc.). Each surfaces a specific
  validator gap; chase per Phase 5 (analysis-layer cleanups).

## Key project shape (load-bearing)

- **Frontend** (`src/frontend/`): `parser.zig` → `sections.zig`
  decoders (type / function / code / import / global / table /
  data / element) → `validator.zig` (full Wasm 1.0 + 2.0 ops,
  single-result blocks, traps, table indirection) →
  `lowerer.zig` (ZIR emit). All zone-clean.
- **IR** (`src/ir/`): `zir.zig` (ZirOp catalogue + FuncType +
  TableEntry + ZirInstr) + `dispatch_table.zig` (per-op slots).
- **Interp** (`src/interp/`): `mod.zig` (Runtime + Value +
  Trap + frames + tables / datas / elems / module_types) +
  `dispatch.zig` (run loop) + `mvp.zig` + `memory_ops.zig` +
  `trap_audit.zig` + `ext_2_0/{sign_ext,sat_trunc,bulk_memory,
  ref_types,table_ops}.zig`.
- **Test surface** (`test/`): `spec/runner.zig` (wasm-1.0
  curated), `spec/wast_runner.zig` (wasm-2.0 manifest-driven),
  `realworld/runner.zig` (toolchain wasms parse smoke).

## Open questions / blockers

(none — push to `origin/zwasm-from-scratch` is autonomous inside
the `/continue` loop per the skill's "Push policy"; no user
approval required.)

## Notes for the next session

- Skill `continue` (`.claude/skills/continue/SKILL.md`) handles
  "続けて" / "/continue" / "resume". It auto-triggers on those phrases
  and drives the per-task TDD loop autonomously. Stops only when the
  user intervenes or a problem cannot be solved (no other stop
  conditions).
- Skill `audit_scaffolding` runs at adaptive cadence (after large
  refactors, after scaffolding accretes, when something feels off,
  and at every Phase boundary).
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
