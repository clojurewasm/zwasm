# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active bundle

- **Bundle-ID**: d314-jit-sandbox (interrupt poll → fuel → mem-cap → C-API/CLI)
- **Cycles-remaining**: ~3
- **Continuity-memo**: DONE — trap surface `5564c553`; **prologue interrupt poll
  BOTH arches** (arm64 `c1a9da15`, x86_64 `6d56f517`, 3-host green — recursion/call
  case); **arm64 loop BACK-EDGE poll** `5b441f96` (poll at each br/br_if-to-loop
  site → POST-frame stub fb=frame_bytes via the SEPARATE `back_edge_interrupt_fixups`
  list; helper `emitBackEdgeInterruptPoll`; a tight `(loop)` now traps on arm64).
  **#3a interrupt COMPLETE both arches**: x86_64 back-edge poll `72801881`
  (32-byte R11-scratch poll at emitBr / branchOnReg / emitBrTableJmp backward
  sites; POST-frame `emitTrapExitStub(16)` via `back_edge_interrupt_fixups`;
  `usage.usesRuntimePtr += .loop` R15-forcing; 2 loop byte tests re-anchored) +
  arm64 br_table-to-loop poll `b365c190` (emitBranchToDepth loop path). Test
  honesty fix in b365c190: flag-set-BEFORE-invoke traps at the PROLOGUE poll
  (both arches) — renamed that test to "R15-forcing"; the real back-edge net =
  2 RUNNING-loop tests (FlagRaiser thread + INFINITE loop/br_table guests;
  back-edge regression = hang-as-failure). TDD red observed for both chunks
  (Rosetta completes-42 / arm64 hang exit-124). **#3b fuel-on-JIT DONE
  `a6d7ae72`** (both arches green 2678/0 + Rosetta; exact-crossing test pins
  units = prologue + back-edge crossings; ADR-0179 rev refined in-commit:
  `fuel_metered` u32 flag + `fuel_cell` i64 IN JitRuntime, NOT a self-ref
  fuel_ptr — RuntimeOwned moves by value, D-215; new x86_64 encoder
  `encSubMem64Disp32Imm8`; kind 17 = TrapKind.out_of_fuel wired interp+JIT+
  runner). `JitInstance.setFuel/fuelRemaining`; facade engine=jit arming
  joins #3a-4. **#3c-2 mem-cap-on-JIT DONE
  `866d784e`** (host-side only as predicted: `MemGrowCtx.host_max_pages` +
  one check in jitMemoryGrow + `JitInstance.setMemoryPagesLimit`; 2679/0).
  **NEXT = #3a-4 CLI/C-API surface — the LAST bundle item**: CLI
  `--fuel <N>` / `--timeout <ms>` / `--max-memory <bytes>` flags (run.zig,
  ADR-0179 sketch §CLI; keep lean per ADR-0159); `zwasm.h` C-API setters
  (today an empty placeholder — decide minimal set: instance-level
  set_fuel/set_memory_limit/interrupt + TrapKind.interrupted/out_of_fuel
  exposure); facade engine=jit arming seam (facade Instance.interrupt/
  setFuel/setMemoryPagesLimit currently assert handle.runtime != null =
  interp-only; route to the JIT instance when engine=jit). On close: bundle
  exit verified → `check_bundle_active.sh --close`, refresh D-314 debt row,
  consider the deferred epoch-counter + table-limit follow-ons (debt rows,
  NOT bundle extension). **Code-size**: poll
  +stub unconditional per fn — measure, consider opt-in flag (perf-measure-first).
  **GATE NOTE**: the 3 D-311 raw-entry-call tests (linker×2/entry-f32,
  releasesafe_jit_failures.md) crash SEED-FLAKILY in `zig build test` (undefined-
  memory read picks up test-order leftover) → can intermittently RED the local
  pre-commit gate. Pre-existing; retry the commit (reshuffles the seed) or the
  3-host test-all (Debug unit + ReleaseSafe integration) is the authority.
  NEW variant (2026-06-12): under the build-runner's `--listen` IPC the unit
  binary can crash AT EXIT after all 2685 results stream back OK — zig prints
  `failed command:` but the step (and `zig build test`) still exits 0; the same
  binary standalone = 2673/0. Same D-311 residual; don't chase it as a new bug.
- **Exit-condition**: a JIT looping/recursive fn traps `error.Interrupted` when the
  host raises the flag. **MET for #3a** (recursion + tight loop + br_table loop,
  both arches, RUNNING-loop verified). Bundle stays open for #3b/#3c-2/#3a-4.

## JIT-correctness pass (2026-06-12) — LANDED, 2-host green

JIT spec-correctness was the priority (`100% spec` held for interp; JIT had real
gaps). **Now wasm-3.0 JIT mode = assert_return 880/0 on BOTH arm64 + x86_64**,
matching interp. Commits `e758412a..9a9b46de` pushed, **ubuntu `test-all` OK
@9a9b46de** (no release — ADR-0156; windows suspended ADR-0174 — now resumable).

**Shipped (detail in git log)**: GC-ref-through-table JIT corruption `9a9b46de`;
memory64 `ea+size` 2^64-overflow `fc5be95e` (reopened+fixed D-234); capture-
allocator mismatch `008dc3be`; D-237 double-free `314a0c97`; 36 stale multi-
memory skips `93792696`. **D-318** (note): Rosetta x86_64-macos FULL corpus-JIT
SEGVs (pre-existing, local-diagnostic only). Remaining jit-mode skips are
eligibility-gated, NOT correctness.

**Prior passes (all green, pushed; detail in git log)**: embedder-hardening
2026-06-08 `14de5430..d6699b00` (InstantiateOpts budgets, decoder robustness,
D-315/D-316, Actions SHA-pinned); Tier-1 release-prep — #2 static-lib `45438b7a`
(D-312), **ADR-0179** design + **interp sandboxing TRIAD** via the facade
(interrupt `1001fa0e`/`460210f1`, mem-limit `7216e7b1`, fuel `58479dd6`),
migration-guide Phase B/D, musl (ADR-0178).

**Documented follow-ons (need a user decision / focused effort — NOT v0.1-blocking)**:
- **JIT-engine sandboxing**: extend interrupt/fuel/mem-cap to `--engine jit`.
  Multi-part: host→JIT interrupt DRIVING path (none today) + prologue-poll codegen
  both arches (Win64-risk → `should_gate_windows.sh --resume`, conflicts w/ cw dev)
  + a JIT-run-trap harness (none). Interp (default) carries the guarantee meanwhile.
  Bundle memo (interp/JIT runtimes separate, setInterruptFlag, arm64 poll plan) in
  git: commit `fb18bd82`.
- **#3a-4 CLI/C-API surface** (`--fuel`/`--timeout`/`--max-memory`; `zwasm.h`
  setters + `TrapKind.interrupted`) — small; the Zig facade already has it.
- **#1 C-API WASI preopen — D-251**: pure C-API has no `std.Io` to open dirs;
  needs an io-acquisition ADR. CLI `--dir` + Zig API cover preopen today.
- **Tier-2 #5** ILP32/watchOS (static-lib target + #97 accommodations).
- **D-313**: realworld `c_sha256_hash.wasm` fixture has a wrong baked hash (zwasm
  is correct vs `shasum`; gate-hole = realworld-run doesn't assert guest stdout) —
  fixture regen + runner-assert deferred.

## State at pause

- **Core Wasm 1.0/2.0/3.0**: 100% spec, 0 skip, 3-host green. **v0.2 features**
  (atomics / wide-arith / custom-page-sizes / relaxed-SIMD) complete + official
  corpora. **WASI 0.1** complete.
- **Component Model + WASI Preview 2** (opt-in `-Dcomponent`): a real Rust
  wasm32-wasip2 component runs e2e (ADR-0170/0175); E1 spec-corpus runner
  (`test/spec/component-model-assert/`); **structural validation** rules 1-4
  (type-index/Canon/alias/ExternDesc bounds — ADR-0176, `feature/component/validate.zig`).
- **Surfaces**: C-API 293/293 gap-free · Zig-API complete · CLI (`run`/`compile`,
  intentionally lean) · memory-safety sound · dogfooded into cw v1.
- **Test iteration**: integration runners build ReleaseSafe (ADR-0177); unit
  `zig build test` stays Debug. `zig build test-all` auto-fast, no flag.
- Debt ledger **53 entries**, **zero `now` rows** (stale D-299 row deleted
  2026-06-12 — its substance was fixed+discharged same-day as D-303 @5b0db8e1/
  31b05bf9; re-verified: misaligned atomic load/store traps on arm64 + Rosetta
  x86_64 JIT). Rest `blocked-by`/`note` = long-tail.

**Parked (demand-driven, NOT this campaign)**: CM deeper conformance
([`component_model_plan.md`](component_model_plan.md)); WASI-P2 sockets; Go/tinygo
proof; 32 `blocked-by` debt (call_ref / future proposals).

## Key refs

- [`docs/handoff_cw_v1.md`](../docs/handoff_cw_v1.md) — consumer-side handoff.
- **ADR-0170** (CM campaign) · **ADR-0176** (component validation) ·
  **ADR-0177** (runners ReleaseSafe) · **ADR-0156** (no release) ·
  **ADR-0174** (windows gate suspend) · **ADR-0153** (rework posture).
- [`component_model_plan.md`](component_model_plan.md) ·
  [`releasesafe_jit_failures.md`](releasesafe_jit_failures.md) (D-311 resolved).
