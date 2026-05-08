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

## Current state — Phase 8 / §9.8 / 8.4 (Hoist pass — JIT optimisation begins)

§9.8 / 8.0–8.3 [x]. Phase 8 carry-over rows from Phase 7 all
closed (D-050 / D-051 / windowsmini-bench-disposition).
Optimisation pipeline rows 8.4–8.7 (Hoist / Coalescer / Regalloc
upgrade / AOT skeleton) are the Phase 8 substantive work.

直近 commits (latest at top):

- (this commit) feat(p8): §9.8 / 8.3 — windowsmini bench subset
  path (`--windows-subset` flag + 5-fixture fast set);
  SSH-from-Linux CI rejected; mark 8.3 [x].
- `89dee4d` feat(p8): §9.8 / 8.2 — D-051 close via emit_test
  family split per ADR-0030.
- `85d75b7` feat(p8): §9.8 / 8.1-b — per-fixture fork+SIGALRM
  timeout; close D-050; mark 8.1 [x].

Mac local realworld_run_jit baseline (8.1 exit, carried as the
Phase 8 starting point): 52/55 compile-pass → 15/55 RUN-PASS,
37 RUN-TRAP, 0 RUN-TIMEOUT, 0 fail-other.

**Phase 8 status**: §9.8 / 8.0-8.3 [x]; 8.4 NEXT. Phase 8 残
rows = 8.4 (Hoist pass) + 8.5 (Coalescer) + 8.6 (Regalloc upgrade)
+ 8.7 (AOT skeleton) + 8.8 (bench delta ≥10%) + 8.9 (boundary
audit) + 8.10 (open §9.9).

## Active task — §9.8 / 8.4: Hoist pass (ZIR transformation) **IN-PROGRESS**

Sub-chunk plan (per `continue` skill chunk-table discipline):

| #     | Description                                                                              | Status      |
|-------|------------------------------------------------------------------------------------------|-------------|
| 8.4-a | ADR-0031 draft (`zir_hoist_pass.md`) — constant-hoist MVP, pre-regalloc placement, alternatives + lifecycle. | **NEXT**    |
| 8.4-b | `src/ir/hoist/pass.zig` MVP: hoist `*.const` ops out of `loop` frames; mutate `func.instrs` + `blocks[]` + `branch_targets[]`; populate `func.hoisted_constants`. Unit tests cover splice mechanics + branch-target shift. | [ ]         |
| 8.4-c | Pipeline integration in `src/engine/codegen/shared/compile.zig` (between lower and liveness); 3-host gate verifies realworld_run_jit ≥ 15/55 RUN-PASS (no regression vs 8.1 baseline). | [ ]         |
| 8.4-d | Bench delta vs Phase 7 close baseline; record entry to `bench/results/history.yaml` if ≥ tinygo/* fixtures show measurable improvement; close 8.4 [x]. | [ ]         |

Pre-requisite confirmed at survey time: `loop_info.compute()` in
`src/ir/analysis/loop_info.zig` already implemented (Phase 5
discharge); `ZirFunc.hoisted_constants: ?[]HoistedConst` slot
already reserved in `src/ir/zir.zig:568`. Liveness in pipeline
at `compile.zig:95`.

Three-way differential gate (P12) carried forward from §9.7 /
7.11. Hoist must not change observable behaviour vs interp.

Open structural debts (current):

- D-007 / D-010 / D-016 / D-018 / D-020 / D-021 / D-022 /
  D-026 / D-028 / D-052 — all `blocked-by:` with concrete
  triggers; refresh on every resume per Step 0.5 barrier-
  dissolution check.

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
