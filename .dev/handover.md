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

- **Phase**: **Phase 4 IN-PROGRESS.** Phases 0 + 1 + 2 + 3 are
  `DONE` (Phase 3 SHA backfill in this commit). §9.3 / 3.0 closed at `05bd4e4`; §9.3 / 3.1 closed at
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
  §9.3 / 3.6 closed at `88e8d79` (chunk a `00f4d9e` decoded the
  Module into the Runtime; chunk b `88e8d79` wired
  `zwasm_instance_get_func` + `wasm_func_delete` +
  `wasm_func_call` + a process-wide lazy `DispatchTable` cache).
  The first remaining `[ ]` is **§9.3 / 3.7 — `wasm_*_vec_t`
  §9.3 / 3.7 closed in three chunks: 3.7a at `fcfdc97` (Trap
  shape + lifecycle), 3.7b at `24567cc` (vec family for byte +
  val), 3.7c at `c7784e4` (`wasm_extern_t` Func variant +
  `wasm_extern_vec_*` pointer-vec family +
  `wasm_instance_exports` + `sections.decodeExports`). §9.3 /
  3.8 closed at `2ee0cb8` — `examples/c_host/hello.c` drives the
  binding end-to-end through the upstream surface (no project
  extensions). §9.3 / 3.9 closed at `414098b` — `zig build
  test-c-api` produces `libzwasm.a` from `src/c_api_lib.zig`,
  links the example against `include/wasm.h`, runs the binary
  with `expectExitCode(0)`, and is wired into `test-all`. End-
  to-end through the C ABI green on all three hosts. §9.3 /
  3.10 closed inline (audit at `private/audit-2026-05-02-p3.md`
  — 0 block, 6 soon, 3 watch). §9.3 / 3.11 closed at `53081ae`
  (Phase 3 SHAs backfilled, Phase Status flipped, §9.4 task
  table expanded 4.0 – 4.12). §9.4 / 4.0 closed at `3327c86`
  via ADR-0005 — `include/wasi.h` is hand-authored (no
  canonical upstream) declaring `zwasm_wasi_config_*` host-
  setup surface; both headers smoke-test under `zig cc`. §9.4 /
  4.1 closed at `b12456a` — `src/wasi/p1.zig` declares the
  WASI snapshot-1 type substrate (Errno 77 tags, Filetype /
  Whence / Clockid / Signal / EventType, Fdflags / Oflags /
  Rights / Fstflags / Lookupflags constants, Iovec / Ciovec /
  Fdstat / Filestat / Prestat extern structs with sizes
  verified). §9.4 / 4.2 closed at `02ff981` (with
  `867a29c` Windows-portability fix) — `src/wasi/host.zig`
  declares `Host` with `args` / `envs` / `preopens` / `fd_table`,
  pre-populates fd 0/1/2 = stdin/stdout/stderr, exposes
  `setArgs` / `setEnvs` / `addPreopen` / `translateFd`. §9.4 /
  4.3 closed at `b824f91` — `src/wasi/proc.zig` lands
  `procExit` + `argsSizesGet` / `argsGet` + `environSizesGet`
  / `environGet` with bounds-checked memory writes; `Host`
  gained `exit_code: ?u32`. §9.4 / 4.4 closed at `fafecf5`
  — `src/wasi/fd.zig` lands gather/scatter `fdWrite` /
  `fdRead` (stdio routes through `host.stdout_buffer` /
  `stdin_bytes` for capture-driven tests; production wiring
  lives in 4.7/4.8) plus `fdClose` / `fdSeek` / `fdTell`
  with the spec-conformant stdio behaviour. §9.4 / 4.5 closed
  in two chunks: 4.5a at `181d477` (fdstat handlers); 4.5b at
  `58ae2d1` (`pathOpen` enforces no `..` / no `/` prefix,
  resolves dirfd via preopen, opens via `std.Io.Dir.openFile`
  on `host.io`). `Host` gained `io: ?std.Io`; `OpenFd` gained
  `host_handle: ?std.posix.fd_t`. §9.4 / 4.6 closed at
  `3537ac9` — `src/wasi/clocks.zig` lands `clockTimeGet` (via
  `std.Io.Timestamp.now(io, clock)`), `randomGet` (via
  `io.randomSecure`), and a `pollOneoff` stub (nsubscriptions=0
  → success, otherwise notsup). The first remaining `[ ]` is
  **§9.4 / 4.7 — wire WASI imports into `wasm_instance_new`**,
  splitting into chunks. 4.7a closed at `505d3ae` —
  `zwasm_wasi_config_new` / `_delete` / `zwasm_store_set_wasi`
  exported; `Store.wasi_host` field added; ownership transfers
  Caller→Store; `wasm_store_delete` tears it down transitively.
  4.7b at `14e0a8f` — `instantiateRuntime` decodes imports
  and rejects unknown module names + WASI imports without a
  host. 4.7c at `da9d7e5` — `Runtime.host_calls: []const
  ?HostCall` parallel to `funcs`; `mvp.callOp` short-circuits
  imported funcidxs to host thunks; `thunkFdWrite` /
  `thunkProcExit` wired with a `lookupWasiThunk` table; WASI
  imports + host configured now succeed at `wasm_instance_new`.
  4.7d at `75992b2` — end-to-end dispatch test: guest `main()
  -> i32.const 42; call $exit` triggers `thunkProcExit` which
  sets `host.exit_code = 42`, unwinds via `error.WasiExit`,
  surfaces as a Trap. Drive-by fixes: `wasm_func_call` now
  indexes `func_ptrs_storage` (full funcidx space) and
  `frontendValidate` builds `func_types` over imports + defined.
  §9.4 / 4.7 fully closed. §9.4 / 4.8 closed in two chunks:
  4.8a at `896f534` (`src/cli/run.zig::runWasm` Zig-callable
  WASI driver; `pub export fn` on all 36 binding entries for
  Zig-import), 4.8b at `894b9ce` (`src/main.zig` `run`
  subcommand: argv → file read → runWasm → exit code; verified
  live: `zwasm run /tmp/proc_exit_42.wasm` returns 42). §9.4 /
  4.9 closed at `fe61fc8` — `test/wasi/runner.zig` walks
  `test/wasi/` (currently 1 fixture: `proc_exit_42.wasm` +
  `proc_exit_42.expected_exit`); `zig build test-wasi-p1`
  invokes it; wired into `test-all` so the three-host gate
  exercises WASI on every push. The first remaining `[ ]` is
  **§9.4 / 4.10 — diff 30+ realworld samples (stdout vs
  `wasmtime run`); land regression script**, splitting into
  chunks. 4.10a at `9ac7fe1` (`runWasmCaptured` + runner
  `.expected_stdout` byte-compare). 4.10b at `30da217` (memory
  + data section wiring in `instantiateRuntime`;
  `sections.decodeMemory` + tiny `evalConstI32Expr`; `hello.wat`
  fixture exercises fd_write through linear memory; runner
  normalises CRLF → LF for Windows portability via `6071b7a`).
  4.10c at `507722e` — `lookupWasiThunk` now resolves all 16
  WASI 0.1 imports. 4.10d at `49d9c9b` — `frontendValidate`
  extended to handle globals + tables; 6/7 realworld
  fixtures (Rust + C + cpp_struct_test) now pass
  validation; go_hello_wasi still rejects (2.5MB Go-runtime
  sections, deferred). Realworld guests reach dispatch but
  exit rc=1 — actual completion vs. wasmtime requires
  ground-truth capture + further interp/binding plumbing.
  4.10e+: promote a passing realworld fixture once we can
  capture its expected stdout via wasmtime; chase remaining
  validation gaps for go_hello_wasi.
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
  - `0005_phase4_wasi_h_authorship.md` — hand-author
    `include/wasi.h` (no canonical upstream wasi.h to vendor);
    pivots §9.4 / 4.0 from "vendor verbatim" to "hand-author".
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

## Windows portability note (added 4.2)

`std.posix.STDIN_FILENO` falls back to `else => 0` (a
comptime_int) on every non-Linux target, NOT a `fd_t`-typed
constant. On Windows, `fd_t = HANDLE = *anyopaque`, so passing
`STDIN_FILENO` (or any int literal) as a `fd_t` parameter
fails to compile with "expected '*anyopaque', found
'comptime_int'". For tests that need a placeholder fd, use
`@as(std.posix.fd_t, undefined)` — the only literal whose
type adapts to both shapes. Real fd values for production
paths come from `std.fs.File.handle` etc.

## Active task — §9.4 / 4.10 (realworld diff vs wasmtime run)

ROADMAP §9.4 exit criterion: "30+ realworld samples (out of
the 50 from v1) run to completion with stdout matching
`wasmtime run`". This is the conformance push that fleshes out
the WASI thunk table beyond `fd_write` + `proc_exit`.

Plan:

1. Pick fixtures from `test/realworld/wasm/` (already vendored
   from v1's diff suite — Rust / TinyGo / cpp_struct_test /
   etc.). Promote some to `test/wasi/` as runnable fixtures.
2. For each fixture:
   - Add `<name>.expected_exit` and `<name>.expected_stdout`
   - Run `wasmtime run <name>.wasm` once, capture stdout +
     exit code; manually verify against project expectations,
     freeze as expected output.
3. Extend `runner.zig` to capture stdout (set
   `host.stdout_buffer`) and compare against
   `.expected_stdout` byte-for-byte.
4. Add missing thunks as failure modes surface:
   - `fd_read` for stdin-piped tests
   - `clock_time_get` for time-using guests
   - `random_get` for randomness-using guests
   - `fd_close` / `fd_seek` etc. as guests touch them
5. Land a `scripts/diff_wasmtime.sh` (or similar) that runs
   the fixture set under both zwasm and wasmtime locally to
   help triage regressions during development.

Cross-host concern: wasmtime is not installed everywhere. The
runner stays self-contained (compares against frozen
`.expected_stdout`); the diff script is a developer tool, not
a CI gate.

This is a substantial task. Likely splits into chunks: first
the runner stdout-capture extension; then 1-2 fixtures at a
time as their thunks land.

Note for 3.2+ work: a `@cImport` smoke test catches "header
unreachable" regressions but tripped Rosetta on OrbStack
(translate-c bss_size overflow). Defer header-parse smoke to
the C-host test step in §9.3 / 3.9 (`zig build test-c-api`)
where it can run via the host C compiler instead of
translate-c.

## Phase-2 + Phase-3 audit `soon` / `watch` carry-over

From `private/audit-2026-05-02.md` (Phase-2) and
`private/audit-2026-05-02-p3.md` (Phase-3 boundary):

- `soon`: src/c_api/wasm_c_api.zig 1457 lines over §A2 soft
  cap. Recommended split: trap_surface.zig + vec.zig +
  instance.zig. File ADR `0005_phase3_c_api_split.md` before
  Phase 4 work piles WASI exports on.
- `soon`: src/frontend/sections.zig 1007 lines (just over).
  Watch trajectory; ADR if it crosses 1300.
- `soon`: mvp.zig 1965 / 2000 lines (split into int_ops /
  float_ops / conversions queued for Phase 5 analysis layer).
- `soon`: validator.zig 1426 lines over §A2 soft cap; lowerer
  1062 likewise. ADR for split plan is the gating step.
- `soon`: proposal_watch quarterly refresh due 2026-07-30.
- `watch`: ROADMAP.md 1900 lines — within documented
  exception, but consider extracting §6 / §11 / §17 at next
  natural break.
- `watch`: missing `test/spec/wasm-2.0/README.md` documenting
  the upstream-pin per ADR-0003. Land opportunistically.

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
