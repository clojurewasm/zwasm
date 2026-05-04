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

## Active

| ID    | Layer  | Status                                                 | Description                                                                                              | First raised | Refs                                                              |
|-------|--------|--------------------------------------------------------|----------------------------------------------------------------------------------------------------------|--------------|-------------------------------------------------------------------|
| D-001 | code   | now                                                    | `runWasm` trap-stderr surface uses 4× `catch {}`; collapse via a `bestEffortPrint` / `surfaceTrap` helper. | 2026-05-04   | `src/cli/run.zig:158-162`                                         |
| D-002 | doc    | now                                                    | `runWasmCaptured` docstring still cites `§9.4 / 4.10`; should be `§9.6 / 6.F`.                            | 2026-05-04   | `src/cli/run.zig:36`                                              |
| D-003 | doc    | now                                                    | `build.zig` realworld-diff comment + `diff_runner.zig` error message both say `§9.6 / 6.2`; rename to `6.F`. | 2026-05-04   | `build.zig:249`, `test/realworld/diff_runner.zig:165, 173`        |
| D-004 | doc    | now                                                    | ADR-0014 §3.γ Rejected lacks the "Beta was originally preferred → survey revealed cost" footprint paragraph (a partial promote of `private/notes/p6-6K3-lifetime-survey.md` §4). | 2026-05-04 | `.dev/decisions/0014_redesign_and_refactoring_before_phase7.md` §3.γ |
| D-005 | doc    | now                                                    | `skip_embenchen_emcc_env_imports.md` lacks an entry recording the failed auto-register spike (5→14 fails) so the same trial isn't retried. | 2026-05-04 | `.dev/decisions/skip_embenchen_emcc_env_imports.md`        |
| D-006 | code   | blocked-by: import-type-validation work scope          | `c_api/instance.zig` `instantiateRuntime` checks import `kind` only — global valtype/mutability, func sig, table elem-type, memory min/max sub-typing all unverified. Exposed by the auto-register spike (would unblock 9 `linking-errors/*.wasm` fixtures + 4 embenchen). | 2026-05-04 | `src/c_api/instance.zig` import-resolution loop; `skip_embenchen_emcc_env_imports.md` "What v2 needs" §1 |
| D-007 | code   | blocked-by: WASI envv / preopens threading task        | `runWasm(alloc, io, bytes, argv)` uses positional args; should refactor to `RunOpts` struct when envv/preopens land. Currently 4 callsites pass `&.{}`. | 2026-05-04 | `src/cli/run.zig:23-49`                                  |
| D-008 | infra  | blocked-by: `wasmtime --version` SSH probe of windowsmini stub root cause | `diff_runner` `SKIP-WASMTIME-UNUSABLE` is a host-specific fallback; root cause of windowsmini wasmtime stub spawn-failure not investigated. Either fix or ADR-document the dev-shell scope boundary. | 2026-05-04 | `test/realworld/diff_runner.zig:171-183` |
| D-009 | code   | blocked-by: Zig 0.17+ stdlib API (`std.posix.getenv` revival) | `src/util/dbg.zig` calls `std.c.getenv` — Zone 0 (util) implicitly depends on libc. `zone_check.sh` doesn't catch this. | 2026-05-04 | `src/util/dbg.zig`, ADR-0015                                      |
| D-010 | code   | blocked-by: Zig stdlib `Allocator.free @memset(undefined)` semantics | `Runtime.deinit` uses `rawFreeOwned` to skip the wrapper's poisoning — needed for cross-instance shared slices via the zombie-instance contract. Currently lives inside `interp/mod.zig`; promote to `src/util/` or `src/platform/` once the wrapper changes or once the same idiom appears in a third site. | 2026-05-04 | `src/interp/mod.zig`, ADR-0014 §6.K.2 sub-change 4         |
| D-011 | code   | blocked-by: ADR-0016 phase 2 (M2 frontend location) start | Diagnostic M2/M3/M4/M5 deferred per ADR-0016 phase 1. M3 (interp trap location + trace ringbuffer) is the prerequisite for diagnosing `wast_runtime_runner`'s `result[0] mismatch` failures. | 2026-05-04 | `.dev/decisions/0016_error_diagnostic_system.md`                  |
| D-012 | doc    | blocked-by: §9.6 / 6.J close cycle                      | ROADMAP §9.6 task table mixes 6.A〜6.J + 6.K.1〜6.K.8 in one block; collapse 6.K rows to a 1-line ADR-0014 reference at 6.J close. | 2026-05-04   | `.dev/ROADMAP.md` §9.6 task table                                 |
| D-013 | infra  | now                                                    | `scripts/check_skip_adrs.sh` (proposed in 2 skip-ADRs) doesn't exist; the "Removal condition" lines have no automatic verifier. | 2026-05-04 | `.dev/decisions/skip_*.md`                                |
| D-014 | code   | blocked-by: Phase 7 design ADR for Runtime infra fields | `Runtime` doesn't yet hold `io: std.Io` — JIT compilation may need it. Decide injection point before Phase 7 starts. | 2026-05-04   | `src/interp/mod.zig:Runtime`                                       |
| D-015 | doc    | now                                                    | Survey notes that motivated load-bearing decisions live only in gitignored `private/notes/` (e.g. `p6-6K3-lifetime-survey.md` §4 is cited from ADR-0014 §3.γ but isn't tracked). Either inline the load-bearing parts or promote to `.dev/lessons/`. | 2026-05-04 | `private/notes/p6-6K1-survey.md`, `p6-6K3-survey.md`, `p6-6K3-lifetime-survey.md` |
| D-016 | infra  | blocked-by: build.zig surpasses 600 lines               | `applySanitize(mod, ...)` invoked 10+ times across module factories. Wrapper into `b.createModuleSanitized(...)` is opt-in cleanup, not currently load-bearing. | 2026-05-04 | `build.zig`                                                       |
| D-017 | infra  | blocked-by: `zone_check.sh` flags a runner exe        | `test/runners/*.zig` exes (notably `wast_runtime_runner.zig`, `diff_runner.zig`) call `cli_run.runWasmCaptured` from non-test top-level code. `zone_deps.md` exempts test blocks but not runner exes; baseline=0 is currently fine but the rule is grey. | 2026-05-04 | `.claude/rules/zone_deps.md`                                       |
| D-018 | code   | blocked-by: cross-module-heavy bench scenario           | `host_calls` thunk + CallCtx allocated on Instance arena — held until store_delete in zombie case. Long-running hosts with many cross-module calls may bloat. Re-evaluate at Phase 7 JIT or when bench shows it. | 2026-05-04 | `src/c_api/cross_module.zig`, ADR-0014 §6.K.3                       |
| D-019 | doc    | now                                                    | wasi runner / realworld run_runner pass `argv[0] = entry.name` (basename). wasmtime CLI uses absolute path. New `*_hello_wasi`-style fixtures may mismatch — document the chosen convention in `test/realworld/README.md` (or wherever doc-of-runners lives). | 2026-05-04 | `test/realworld/run_runner.zig:106`, `test/wasi/runner.zig:97`     |
| D-020 | infra  | blocked-by: `private/dbg/<task>` reaches 5 entries      | `zig build run-repro -Dtask=<name>` step has no listing (`--help` shows no enumerated tasks). Add `scripts/list_repros.sh` when the corpus grows. | 2026-05-04   | `build.zig` run-repro step, ADR-0015                              |
| D-021 | code   | blocked-by: Phase 14 concurrency phase                  | `Diagnostic` is `threadlocal var` per ADR-0016 phase 1. Concurrent guest threads (Phase 14+) require a thread-mapping decision. | 2026-05-04   | `src/runtime/diagnostic.zig`                                       |
| D-022 | code   | blocked-by: ADR-0016 M3 work item                       | `wast_runtime_runner` cannot localise `result[0] mismatch` — needs M3 (interp trap location + trace ringbuffer). 5 deferred misc-runtime fixtures' silent-failure path is gated on this. | 2026-05-04 | `test/runners/wast_runtime_runner.zig`                            |
| D-023 | infra  | blocked-by: §9.6 / 6.H bench honest-baseline            | `bench/results/{recent,history}.yaml` (per ADR-0012 §7) not yet generated. 6.K cycle changed the interpreter; performance impact unmeasured. | 2026-05-04 | `.dev/ROADMAP.md` §9.6 / 6.H, ADR-0012 §7                         |
| D-024 | infra  | blocked-by: `audit_scaffolding` next run                 | `flake.lock` may have churned during 6.K.7 (wasm-tools + lldb addition). dev-shell startup time impact unmeasured. Trigger via the audit skill, not standalone. | 2026-05-04 | `flake.nix`, `flake.lock`                                          |

## Recently discharged

> Move rows here briefly for backreference; remove after one cycle.

(empty — initial seeding)

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
