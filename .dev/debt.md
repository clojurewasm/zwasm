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
| D-006 | code   | blocked-by: ImportPayload extension + Instance source-side type metadata | `c_api/instance.zig` `instantiateRuntime` checks import `kind` only — global valtype/mutability, func sig, table elem-type+limits, memory limits sub-typing all unverified. Currently 9 `linking-errors/*.wasm` PASS for the **wrong reason** (manifest discovery rejects before type-check would fire). **Refined 2026-05-04 after Phase-6-cleanliness probe**: honest discharge needs (a) `ImportPayload` extension to surface table.{elem_type, min, max} + memory.{min, max} (currently `void`); (b) source-side type metadata accessor on `Instance` (currently exports only carry `kind` + `name`, not the structural types); (c) func sig comparison resolving importer typeidx → exported FuncType. Partial-discharge harms (only-globals validation regresses fixtures 5-9 to "succeed-when-should-fail"). Estimated ~200-300 lines + tests; full discharge belongs in its own ROADMAP row at Phase 7+. | 2026-05-04 | 2026-05-04 | `src/c_api/instance.zig` import-resolution loop ~line 615; `src/frontend/sections.zig:ImportPayload`; `skip_embenchen_emcc_env_imports.md` "What v2 needs" §1 |
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
| D-022 | code   | blocked-by: ADR-0016 M3 work item                       | `wast_runtime_runner` cannot localise `result[0] mismatch` — needs M3 (interp trap location + trace ringbuffer). 5 deferred misc-runtime fixtures' silent-failure path is gated on this. | 2026-05-04 | 2026-05-04 | `test/runners/wast_runtime_runner.zig`                            |
| D-024 | infra  | blocked-by: `audit_scaffolding` next run                 | `flake.lock` may have churned during 6.K.7 (wasm-tools + lldb addition). dev-shell startup time impact unmeasured. Trigger via the audit skill, not standalone. | 2026-05-04 | 2026-05-04 | `flake.nix`, `flake.lock`                                          |
| D-025 | infra  | blocked-by: §9.6 / 6.H Phase 11 hyperfine wiring          | ROADMAP §9.6 / 6.J's "bench-quick green Mac-only" exit clause technically referenced a step that is currently a Phase-11+ stub (scripts/run_bench.sh). Phase 6 close declared OK because real numbers belong in Phase 11+ per ADR-0012. The 6.J wording stays as written; this row tracks the structural→running transition for honest revisitation when bench infra lands. | 2026-05-04 | 2026-05-04 | `scripts/run_bench.sh`, ROADMAP §9.6 / 6.J + 6.H |

## Recently discharged

> Move rows here briefly for backreference; remove after one cycle.

| ID    | Discharged  | How                                                                             |
|-------|-------------|---------------------------------------------------------------------------------|
| D-001 | 2026-05-04  | `src/cli/run.zig` — `surfaceTrap()` helper collapses 4× `catch {}` cluster.     |
| D-002 | 2026-05-04  | `src/cli/run.zig:36` docstring renamed §9.4 / 4.10 → §9.6 / 6.F.                |
| D-003 | 2026-05-04  | `build.zig` + `test/realworld/diff_runner.zig` renamed §9.6 / 6.2 → §9.6 / 6.F. |
| D-005 | 2026-05-04  | `skip_embenchen_emcc_env_imports.md` § "Spike outcome" added (5→14 fail spike). |
| D-013 | 2026-05-04  | `scripts/check_skip_adrs.sh` + `scripts/check_adr_history.sh` landed.           |
| D-019 | 2026-05-04  | `test/realworld/README.md` documents argv basename convention.                  |
| D-015 | 2026-05-04  | ADR-0014 §3.γ (Author candor) + §6.K.3 (How this contract was discovered) inline the load-bearing parts of `p6-6K3-lifetime-survey.md`. Remaining survey content stays in `private/notes/` as scratch. |
| D-008 | 2026-05-04  | `diff_runner.resolveWasmtime` drops `which`-based path resolution; uses bare `"wasmtime"` argv[0] so Zig's spawn does PATH lookup uniformly. Three-host gate: 39/55 matched on all of Mac aarch64 + OrbStack Ubuntu + windowsmini (was 0/55 SKIP-WASMTIME-UNUSABLE on windowsmini). |
| D-023 | 2026-05-04  | `bench/results/{recent,history}.yaml` layout introduced; old `baseline_v1_regression.yaml` + `history.yaml` migrated. Hyperfine wiring stays Phase 11 deferred (scripts' own TODO p11). |

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
