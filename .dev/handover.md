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

## Active task — §9.8 / 8.4: Hoist pass — **PARTIAL; redesign required**

Sub-chunk progress (this cycle):

| #     | Description                                                                              | Status      |
|-------|------------------------------------------------------------------------------------------|-------------|
| 8.4-a | ADR-0031 draft (`zir_hoist_pass.md`) — constant-hoist MVP design framing. Committed. | [x]         |
| 8.4-b | `src/ir/hoist/pass.zig` MVP: instr-move + pc_shift / blocks / branch_targets update; unit tests for splice mechanics. Committed. | [x]         |
| 8.4-c | Pipeline integration in `src/engine/codegen/shared/compile.zig` — **REVERTED**. realworld_run_jit regressed 52/55+15/55 → 38/55+2/55 due to ZIR vreg renumbering at liveness (operand-stack push-order). Lesson `2026-05-08-hoist-vreg-semantic.md` records root cause; ADR-0031 amended; D-053 tracks the correct local-set/local-get rewrite. | (reverted)  |
| 8.4-d | Hoist redesign (D-053) — insert `*.const K; local.set N` before loop; rewrite in-loop `*.const K` to `local.get N`. Reuses 8.4-b's pc_shift/blocks/branch_targets infrastructure; what changes is what gets emitted. **NEXT** | **NEXT**    |
| 8.4-e | Bench delta vs Phase 7 close baseline; close 8.4 [x] only after 8.4-d lands and 3-host gate green. | [ ]         |

8.4 is **not closed** in this resume cycle. The MVP module
(8.4-b) is preserved as production code but not wired into the
compile pipeline — it serves as the starting point for D-053's
redesign. 8.4-d's redesign extends rather than replaces 8.4-b.

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
