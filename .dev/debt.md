# Debt ledger

> Tracked technical debt. Refresh on every `/continue` resume —
> see `.claude/skills/continue/SKILL.md` Step 0.5.
>
> **Discipline (per 2026-05-04 dialogue)**:
>
> - Every entry has `Status: now` OR `Status: blocked-by: <具体的な
>   構造的障害>`. There is no "later" / "low priority" / "small effort"
>   bucket — those are how debt accumulates.
> - On every resume, attempt to discharge **every `now` entry** before
>   moving on to the active task. Effort estimate is irrelevant; only
>   structural impossibility blocks discharge.
> - When discharged, **delete** the row (git log retains the trace
>   via the discharge commit message — `chore(debt): close D-NNN
>   <one line>`).
> - When a `blocked-by` row's structural barrier is removed, flip to
>   `Status: now` immediately.
> - The **`Last reviewed`** column is mandatory for `blocked-by` rows.
>   Step 0.5 of `/continue` SKILL.md tracks resume-cycle staleness:
>   if a row's `Last reviewed` is more than 3 cycles old, the loop
>   fires `audit_scaffolding` in narrow mode (§F only) to re-evaluate
>   the named barrier. This closes the failure mode where
>   `blocked-by:` quietly outlives its barrier.

## Active

| ID    | Layer  | Status                                                 | Description                                                                                              | First raised | Last reviewed | Refs                                                   |
|-------|--------|--------------------------------------------------------|----------------------------------------------------------------------------------------------------------|--------------|---------------|--------------------------------------------------------|
| D-026 | code   | blocked-by: env-stub host-func wiring + externref reftype | `embenchen_*1.wasm` (4 fixtures) + `externref-segment.0.wasm` (1) — newly visible after D-006's import-type validation closed (auto-register lifted them past manifest discovery; validator passes their imports as type-equivalent against the env stub; runtime wiring of the env stub's func bodies is what now blocks them). The validator gap that D-006 documented is gone; what remains is implementation-side host-function dispatch for emcc-style env stubs. Reuses `skip_embenchen_emcc_env_imports.md`'s "What v2 needs" § text but with a sharper barrier. | 2026-05-04 | 2026-05-04 | `src/c_api/instance.zig` cross-module func dispatch; `skip_embenchen_emcc_env_imports.md`; `skip_externref_segment.md` |
| D-007 | code   | blocked-by: WASI envv / preopens threading task        | `runWasm(alloc, io, bytes, argv)` uses positional args; should refactor to `RunOpts` struct when envv/preopens land. Currently 4 callsites pass `&.{}`. | 2026-05-04 | 2026-05-04 | `src/cli/run.zig:23-49`                                  |
| D-009 | code   | blocked-by: Zig 0.17+ stdlib API (`std.posix.getenv` revival) | `src/util/dbg.zig` calls `std.c.getenv` — Zone 0 (util) implicitly depends on libc. `zone_check.sh` doesn't catch this. | 2026-05-04 | 2026-05-04 | `src/util/dbg.zig`, ADR-0015                                      |
| D-010 | code   | blocked-by: Zig stdlib `Allocator.free @memset(undefined)` semantics | `Runtime.deinit` uses `rawFreeOwned` to skip the wrapper's poisoning — needed for cross-instance shared slices via the zombie-instance contract. Currently lives inside `interp/mod.zig`; promote to `src/util/` or `src/platform/` once the wrapper changes or once the same idiom appears in a third site. | 2026-05-04 | 2026-05-04 | `src/interp/mod.zig`, ADR-0014 §6.K.2 sub-change 4         |
| D-011 | code   | blocked-by: ADR-0016 phase 2 (M2 frontend location) start | Diagnostic M2/M3/M4/M5 deferred per ADR-0016 phase 1. M3 (interp trap location + trace ringbuffer) is the prerequisite for diagnosing `wast_runtime_runner`'s `result[0] mismatch` failures. | 2026-05-04 | 2026-05-04 | `.dev/decisions/0016_error_diagnostic_system.md`                  |
| D-014 | code   | blocked-by: §9.7 / 7.3 emit pass (or earliest JIT row that touches `Runtime`) | `Runtime` doesn't yet hold `io: std.Io`. **Refined 2026-05-04 at Phase 7 start**: the original "decide before Phase 7 starts" deadline triggered re-evaluation; rows 7.0 (`reg_class.zig`), 7.1 (`regalloc.zig`), 7.2 (`jit_arm64/{inst,abi}.zig`) are pure type / encoding work and do NOT touch Runtime. The injection-point design decision is genuinely deferred to the first JIT row that needs Runtime — likely 7.3 (`emit.zig` ZIR→ARM64 pass). At that point the barrier dissolves and the design ADR fires. | 2026-05-04 | 2026-05-04 | `src/interp/mod.zig:Runtime`, ROADMAP §9.7 / 7.3 |
| D-016 | infra  | blocked-by: build.zig surpasses 600 lines               | `applySanitize(mod, ...)` invoked 10+ times across module factories. Wrapper into `b.createModuleSanitized(...)` is opt-in cleanup, not currently load-bearing. | 2026-05-04 | 2026-05-04 | `build.zig`                                                       |
| D-017 | infra  | blocked-by: `zone_check.sh` flags a runner exe        | `test/runners/*.zig` exes (notably `wast_runtime_runner.zig`, `diff_runner.zig`) call `cli_run.runWasmCaptured` from non-test top-level code. `zone_deps.md` exempts test blocks but not runner exes; baseline=0 is currently fine but the rule is grey. | 2026-05-04 | 2026-05-04 | `.claude/rules/zone_deps.md`                                       |
| D-018 | code   | blocked-by: cross-module-heavy bench scenario           | `host_calls` thunk + CallCtx allocated on Instance arena — held until store_delete in zombie case. Long-running hosts with many cross-module calls may bloat. Re-evaluate at Phase 7 JIT or when bench shows it. | 2026-05-04 | 2026-05-04 | `src/c_api/cross_module.zig`, ADR-0014 §6.K.3                       |
| D-020 | infra  | blocked-by: `private/dbg/<task>` reaches 5 entries      | `zig build run-repro -Dtask=<name>` step has no listing (`--help` shows no enumerated tasks). Add `scripts/list_repros.sh` when the corpus grows. | 2026-05-04 | 2026-05-04 | `build.zig` run-repro step, ADR-0015                              |
| D-021 | code   | blocked-by: Phase 14 concurrency phase                  | `Diagnostic` is `threadlocal var` per ADR-0016 phase 1. Concurrent guest threads (Phase 14+) require a thread-mapping decision. | 2026-05-04 | 2026-05-04 | `src/runtime/diagnostic.zig`                                       |
| D-022 | code   | blocked-by: ADR-0028 M3-a-2 (trap event runtime write) + interp trap-location wiring | `wast_runtime_runner` cannot localise `result[0] mismatch` — needs M3 (interp trap location + trace ringbuffer). 5 deferred misc-runtime fixtures' silent-failure path is gated on this. **2026-05-05 follow-up**: ADR-0028 superseded ADR-0016's M3 deferral; M3-a-1 (ringbuffer infra + compile-time bounds writes) landed. The remaining barrier is M3-a-2 (trap stub → ring buffer write at runtime; needs trap-stub helper-call calling-convention coordination per ADR-0028 §"Trap-time JIT register state") + interp trap-location capture. Once those land, the runner can correlate result mismatches with the actual trap site. | 2026-05-04 | 2026-05-05 | `test/runners/wast_runtime_runner.zig`, `src/diagnostic/trace.zig`, ADR-0028 |
| D-028 | infra  | blocked-by: zig 0.16 test runner ↔ build process IPC stability on windowsmini SSH | `bash scripts/run_remote_windows.sh test-all` occasionally aborts with `error: test runner failed to respond for 1m4ms` even though 795/805+ tests passed in the failed run (only `test runner failed to respond` itself is the failure). Observed twice during §9.7 / 7.5d sub-b chunk 9 + §9.7 / 7.7-alu (commit `741a9b4`). Retry succeeds every time. **Trigger condition (named in concrete terms per `extended_challenge.md` Step 1)**: long-running test executable on Windows (zig 0.16's MSVC-spawned test process), exit code 1 with the IPC-timeout message rather than test failures. **Reproduction**: re-run after a successful run; flake rate observed 2/30 commits ≈ 6%. Workaround: retry once. The /continue loop's "windowsmini transient" treatment lets it slip past, but root-cause investigation needs upstream zig issue search (extended_challenge.md Step 4 — WebFetch ziglang/zig issues for "test runner failed to respond" + "Windows IPC"). **2026-05-05 follow-up**: 10 連続 (private/d028-logs/run-1..10.log @ commit eea7e75) で 0 fail。WebSearch も upstream 報告ゼロ → 汎用 zig 0.16 + Windows 問題ではない。再現条件は (a) 特定の commit 内容、(b) windowsmini ホスト側の I/O 状況、(c) test count 増加に伴う confluence の何れか。**次の Step**: 別 commit (実装変更を含む coverage の異なる commit) で再度 ×10 連回し → そこで再現したら delta の特定可能。 | 2026-05-05 | 2026-05-05 | `scripts/run_remote_windows.sh`, observed in commits `741a9b4` (chunk 9) + likely earlier 7.5d-era runs |
| D-031 | infra  | blocked-by: §9.7 / 7.5b-iii (richer JitRuntime + memory init from module data section) | `src/engine/runner.zig:runI32Export` は `mem_limit = 0` の dummy JitRuntime しか組み立てない。このため `test/edge_cases/p7/memory_bounds/` の "ちょうど境界に届く OK" fixture (例: `at_limit_load_i32` で eff_addr=65532, size=4, mem_limit=65536) を runner が exercise できず、削除した。trap ケース 2 件 (`past_limit_load_i32`, `past_limit_load8_u`) は exercise 可能で spec strictness を実証している。**Discharge 時**: runner が module の memory section + data segment を読んで JitRuntime.vm_base / mem_limit を populate するようになったら `at_limit_load_i32` を再追加して OK 境界を回帰検出に組み込む。 | 2026-05-05 | 2026-05-05 | `src/engine/runner.zig:166-173`, removed `test/edge_cases/p7/memory_bounds/at_limit_load_i32.{wat,wasm,expect}` |
| D-030 | code   | blocked-by: §9.7 / 7.7 完了 (全 op chunk landing 後)             | `src/engine/codegen/x86_64/emit.zig` (1964 LOC) と `inst.zig` (1134 LOC) は ADR-0023 §269-314 が規定する arm64/ mirror shape (`emit.zig` orchestrator ≤ 1000 LOC + `op_const`/`op_alu`/`op_memory`/`op_control`/`op_call` 等への分散) に従っていない。現状 op_*.zig はシェルファイルとして存在するのみで、handler 実装が emit.zig に集約されている。**Discharge 手順** は ARM64 が ADR-0021 sub-b で実証した 10-chunk 抽出 (label / ctx / gpr / op_const / op_alu_int / op_alu_float / op_convert / op_memory / op_control / emit_test) を x86_64 で踏襲。新規 ADR は不要 (ADR-0023 が load-bearing)。**Why not "now"**: 7.7-globals/wrap/call/fp の残 chunk landing でモジュール内訳の見積もりが固まってから抽出する方が手戻りなし。 | 2026-05-05 | 2026-05-05 | `src/engine/codegen/x86_64/emit.zig` + `inst.zig`, ADR-0023 §269-314, ADR-0021 sub-b 手順 |
| D-033 | code   | now    | ARM64 emit's `local.get` / `local.set` / `local.tee` use STR W / LDR W (32-bit) regardless of the local's declared type. With 7.5-i64-params accepting i64 params (which the prologue stores via STR X, full 64-bit), reading the same slot via local.get's 32-bit LDR W silently truncates to 32 bits. **Discharge** = thread the per-local type through ZirFunc → emit so local.get/set picks STR W vs STR X (and eventually similar for FP via V regs). Surfaces semantic miscompile; spec-jit-compile-runner reports PASS for fixtures with i64 locals + reads even though the bytes would execute incorrectly. Required for §9.7 / 7.5 spec-test pass=fail=skip=0 to be meaningfully green. **Why not "blocked"**: no structural barrier, just non-trivial threading work. | 2026-05-06 | 2026-05-06 | `src/engine/codegen/arm64/emit.zig:local.get/set/tee handlers`, ZirFunc.locals shape |
| D-034 | code   | blocked-by: spill-aware op handlers (gpr.resolveGpr + per-op refactor) | ARM64 emit's `gpr.resolveGpr` rejects spilled vregs (`.spill => Error.UnsupportedOp`). With fresh-vreg-per-op allocation, large functions (5+ params + many local.gets + intermediate conversions) overflow the 9-GPR / 8-V regalloc pool — `test/spec/wasm-1.0/local_get.0.wasm` + `local_set.0.wasm` func[9] (params i64 f32 f64 i32 i32 + 4 locals + 10+ local.get + conversions) hit `SlotOverflow`. **Discharge** = thread spill-staging through every per-op handler that calls `resolveGpr` / `resolveFp` (use `gprLoadSpilled` / `gprStoreSpilled` already in place per sub-1c). Major refactor — every i32/i64/f32/f64 op handler in op_alu_int / op_alu_float / op_convert / op_memory / op_call / op_const / op_globals needs to switch from `resolveGpr` to staged-load. **Required** for §9.7 / 7.5 spec gate (currently 10/12 spec-jit-compile pass). | 2026-05-06 | 2026-05-06 | `src/engine/codegen/arm64/gpr.zig:resolveGpr` + every consumer in op_*.zig; spec-jit-compile-runner surfaces it on local_get/set.0 func[9] |
| D-029 | code   | blocked-by: x86_64 regalloc port (currently fresh-vreg-per-op)   | `emit.zig:emitI32Binary` and `emit.zig:emitI32Shift` reject `dst == rhs` with `Error.UnsupportedOp` because the `MOV dst, lhs` would clobber `rhs` before the OP reads it. With fresh-vreg-per-op allocation (current shape) this never fires; the regalloc port enabling slot reuse will trip it. **Discharge requires** parallel-move in `emitI32Binary` (commute or use a scratch when dst==rhs) + a similar treatment for shift / convert handlers as they land. The same constraint exists on ARM64 conceptually but ARM64's 3-operand ALU ops sidestep it (ADD Xd, Xn, Xm puts dst in a separate field). x86_64's 2-operand encoding makes this unavoidable until parallel-move lands. **Verified 2026-05-05** via `rg 'fn emitI32Binary' src/engine/codegen/arm64/op_alu_int.zig` — ARM64 emitI32Binary uses `encAddRegW(wd, wn, wm)` with three independent vreg-resolved operands; no `dst == rhs` clobber path on that backend (per `bug_fix_survey.md` same-class grep). **Why not "now"**: the regalloc port itself is a Phase 7 follow-up (no concrete row yet — likely 7.7-regalloc or 7.8-regalloc). | 2026-05-05 | 2026-05-05 | `src/engine/codegen/x86_64/emit.zig:emitI32Binary` + `:emitI32Shift`, ADR-0026 §"Pool sizing" |

## Recently discharged

> Move rows here briefly for backreference; remove after one cycle.

| ID    | Discharged  | How                                                                             |
|-------|-------------|---------------------------------------------------------------------------------|
| D-032 | 2026-05-06  | x86_64 `emit.zig` function-level `end` now dispatches on `func.sig.results[0]`: i32/funcref/externref → MOV EAX (.d), i64 → MOV RAX (.q, full width), f32/f64 → MOVAPS XMM0, src_xmm (via fpSlotToReg), v128 → UnsupportedOp. 4 byte-level emit tests added. ARM64 reference at `arm64/emit.zig:475-503`. Commit `57cf94c`. |
| D-001 | 2026-05-04  | `src/cli/run.zig` — `surfaceTrap()` helper collapses 4× `catch {}` cluster.     |
| D-002 | 2026-05-04  | `src/cli/run.zig:36` docstring renamed §9.4 / 4.10 → §9.6 / 6.F.                |
| D-003 | 2026-05-04  | `build.zig` + `test/realworld/diff_runner.zig` renamed §9.6 / 6.2 → §9.6 / 6.F. |
| D-005 | 2026-05-04  | `skip_embenchen_emcc_env_imports.md` § "Spike outcome" added (5→14 fail spike). |
| D-013 | 2026-05-04  | `scripts/check_skip_adrs.sh` + `scripts/check_adr_history.sh` landed.           |
| D-019 | 2026-05-04  | `test/realworld/README.md` documents argv basename convention.                  |
| D-015 | 2026-05-04  | ADR-0014 §3.γ (Author candor) + §6.K.3 (How this contract was discovered) inline the load-bearing parts of `p6-6K3-lifetime-survey.md`. Remaining survey content stays in `private/notes/` as scratch. |
| D-008 | 2026-05-04  | `diff_runner.resolveWasmtime` drops `which`-based path resolution; uses bare `"wasmtime"` argv[0] so Zig's spawn does PATH lookup uniformly. Three-host gate: 39/55 matched on all of Mac aarch64 + OrbStack Ubuntu + windowsmini (was 0/55 SKIP-WASMTIME-UNUSABLE on windowsmini). |
| D-023 | 2026-05-04  | `bench/results/{recent,history}.yaml` layout introduced; old `baseline_v1_regression.yaml` + `history.yaml` migrated. Hyperfine wiring stays Phase 11 deferred (scripts' own TODO p11). |
| D-006 | 2026-05-04  | Substantial discharge: ImportPayload extended (table/memory limits surfaced); Instance.export_types populated during instantiation; checkImportTypeMatches per Wasm 2.0 §3.4.10 covers global valtype+mut, table elem-type+limits, memory limits, func sig. wast_runtime_runner re-adds bare-name auto-register. linking-errors {1-9} now PASS via `error.ImportTypeMismatch` (the spec-honest reason) instead of UnknownImportModule. Embenchen-stub host-func wiring split off as D-026. |
| D-025 | 2026-05-04  | bench infra real hyperfine numbers landed (commit `e568077`). 26 fixtures ran; "Phase 6 close baseline" entry recorded in bench/results/history.yaml. The 6.J row text is now substantively met (was structural-only). |
| D-024 | 2026-05-04  | `git log -- flake.lock` shows no churn since `5762fd3` (initial Phase 0). The 6.K.7 ADR-0015 flake.nix edits added tools but didn't update lock — confirmed via git history. Concern was hypothetical; closing without further work. |
| D-027 | 2026-05-04  | Merge-aware label stack landed in emit.zig. `Label.merge_top_vreg` captures the then arm's result vreg at `else`; `end` of else_open frame emits MOV merge_reg ← else_result_reg before patching B-uncond fixups so both arms converge on the merge target's register. Native `(if (result T))` fixtures (then=11, else=22) pass via JIT. Block-result + loop-result + br-with-target-arity may still need similar attention, but the if-frame case is closed. |

## How to read this file

- The Status column is the **only** column that determines whether a
  row is acted on now. `now` rows must be discharged on this resume
  cycle. `blocked-by: <X>` rows must explicitly name the structural
  barrier — vague "later" entries are forbidden.
- The Layer column is **informational** (code / doc / test / infra
  / process). It exists for reading speed; it does not influence
  the discharge decision.
- The First raised date carries forward across discharges and
  re-raises so we notice when a debt has been outstanding too long.
- Refs link to the artefact — file path + line, ADR §, or skill /
  rule path. If a Refs link 404s, that is itself a debt finding
  (the `audit_scaffolding` skill checks for this).

## Promotion to ADR

A debt row that needs **load-bearing design discussion** (alternatives
considered, decision rationale, removal condition spelling out
behaviour change) is promoted from this file to a `.dev/decisions/
NNNN_<slug>.md` ADR. The discharge commit removes the row from this
file. See `.claude/rules/lessons_vs_adr.md` for the decision tree.
