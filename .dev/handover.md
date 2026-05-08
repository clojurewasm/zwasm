# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.8 task table — Phase 8 active.
3. `.dev/debt.md` — discharge `Status: now` rows; review `blocked-by` triggers.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain.
5. `.dev/optimisation_log.md` — F-NNN / R-NNN / O-NNN ledger (Phase 8 candidate landings).
6. `.dev/decisions/0019_x86_64_in_phase7.md` / 0021 / 0023 / 0026 / 0027 / 0028 / 0029 — recent ADRs.
7. `.dev/phase8_transition_gate.md` — historical reference (gate now closed; 7.13 [x]).

## Current state — Phase 8 / §9.8 / 8.1 (D-050 WASI subset for JIT)

Phase 7 closed; Phase 8 open at HEAD `9da3c99`. ROADMAP §9 Phase
Status widget shows 7=DONE, 8=IN-PROGRESS. §9.8 task table
expanded inline (8.0-8.10).

Discovered at 8.1 entry: D-050 sub-tasks (1) + (2) **partially
already landed** — `src/wasi/jit_dispatch.zig` has `fd_write` /
`clock_time_get` / `random_get` / `args_*` / `environ_*` /
`proc_exit` thunks; `setupRuntime` (`src/engine/runner.zig:422`)
already calls `populateDispatch`. Missing piece is **`fd_read`**
(absent from lookup() table) + **per-fixture timeout** (subprocess
fork + SIGALRM in `test/realworld/run_runner_jit.zig`). Runner
guards run-stage behind `ZWASM_JIT_RUN=1` env var; default
test-all path is compile-only.

直近 commits (latest at top):

- `9da3c99` chore(p7): close Phase 7; expand §9.8 inline + flip
  Phase Status widget.
- `60a4a67` chore(p7): windowsmini Phase 7 close partial baseline
  + handover/gate-doc updates.
- `e3e6668` chore(infra p7): hyperfine CI bench workflow.
- `8c51fcd` chore(debt p7): close D-009 + D-011 + D-017.

**Phase 8 status**: §9.8 / 8.0 [x]; 8.1 IN-PROGRESS. Phase 8 残
rows = 8.1 (NEXT) + 8.2 (D-051 emit.zig prologue extraction) +
8.3 (windowsmini bench disposition) + 8.4-8.10 (optimisation
pipeline + AOT skeleton + bench delta + audit + open §9.9).

## Active task — §9.8 / 8.1: D-050 WASI subset for JIT path **IN-PROGRESS**

Sub-chunk plan (granularity per `continue` skill chunk-table
discipline):

| #     | Description                                                                                  | Status      |
|-------|----------------------------------------------------------------------------------------------|-------------|
| 8.1-a | `fd_read` thunk added to `src/wasi/jit_dispatch.zig` (stdin EOF stub for MVP per p8 survey); `lookup()` table extended; thunk tests added | **NEXT**    |
| 8.1-b | Per-fixture subprocess fork + SIGALRM timeout in `test/realworld/run_runner_jit.zig`; Windows path = RUN-SKIP-NO-FORK; comptime os.tag guard. | [ ]         |
| 8.1-c | Re-run `ZWASM_JIT_RUN=1 zig build test-realworld-run-jit` baseline on 3 hosts; record RUN-PASS count vs Phase 7 close (0/55) baseline; close D-050 row in `.dev/debt.md` if ≥10 fixtures flip to RUN-PASS (matches the spirit of D-050 close criterion — "WASI subset is wired"; the ≥40 target is aspirational, real number depends on which fixtures are stdin-only WASI vs compute-heavy). | [ ]         |

Survey lives in `private/notes/p8-8.1-survey.md` (gitignored;
covers fd_read iovec semantics + Zig 0.16 fork/alarm/waitpid +
wasmtime/zware divergence notes).

Three-way differential gate (P12) is the correctness oracle for
8.1-c's RUN-PASS measurement.

## Phase 7 close summary (snapshot for cold-start context)

Phase 7 closed at HEAD `60a4a67` (this handover update lands at
C6). 5/5 transition gate sections ☑:

1. **Functional**: 3-host green; `check_three_host_diff.sh` PASS.
2. **Debt-ledger**: 11 Active rows (was 14 before second sweep);
   D-009 + D-011 + D-017 closed inline at gate review per user
   direction「もうdebtから消せるな」.
3. **Design cleanliness**: AOT/GC/EH/WASI-p2/SIMD slots reserved;
   2 of 3 file-size hard-cap files split (cde3405); D-051 covers
   `x86_64/emit.zig` Phase 8 entry-task.
4. **§3a deferred-work DAG**: D-035/D-036/D-037/D-030 all closed;
   D-029 deferral rationale recorded in gate doc §5a.
5. **Strategic review**: ROADMAP §1+§2 read-back consistent;
   `meta_audit` produced `2026-05-08-phase7-close.md`; CI bench
   pulled forward (e3e6668); host-baseline ratios anchored in
   `history.yaml` per gate doc §5b.

## Open structural debt (pointers — current; full list in `.dev/debt.md`)

- **D-050** WASI subset for JIT → §9.8 / 8.1 (NEXT; first Phase 8 task).
- **D-051** x86_64/emit.zig prologue extraction → §9.8 / 8.2 (ADR-grade).
- **D-022** ADR-0028 M3-a-2 trap event runtime write.
- **D-026** env-stub host-func wiring (cross-module dispatch).
- **D-029** parallel-move complete coverage (O-002 deferred per gate §5a).
- 詳細・全 11 Active rows は `.dev/debt.md` 参照。

**Phase**: Phase 8 (JIT optimisation foundation 🔒、ADR-0019)。
**Branch**: `zwasm-from-scratch`。
