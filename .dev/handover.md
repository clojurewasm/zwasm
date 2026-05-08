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

## Current state — Phase 8 / §9.8 / 8.2 (D-051 x86_64 prologue extraction)

§9.8 / 8.1 [x] (D-050 closed). Mac local `ZWASM_JIT_RUN=1`
realworld_run_jit baseline: **52/55 compile-pass → 15/55
RUN-PASS, 37 RUN-TRAP, 0 RUN-TIMEOUT, 0 fail-other** (was 0/55
RUN-PASS at row entry). `fd_read` JIT thunk landed in 8.1-a
(`4fd8b61`); per-fixture fork+SIGALRM timeout machinery landed
in 8.1-b (this commit). Windows host falls back to compile-only
with a one-line warning per `extended_challenge.md` graceful-
degradation allowance.

直近 commits (latest at top):

- (this commit) feat(p8): §9.8 / 8.1-b — per-fixture fork+SIGALRM
  timeout; close D-050; mark 8.1 [x].
- `4fd8b61` feat(p8): §9.8 / 8.1-a — add WASI fd_read JIT thunk
  + close 8 pre-existing lint warnings.
- `9fb44dd` bench(ci): record 9da3c99 [skip ci] (CI bot).
- `9da3c99` chore(p7): close Phase 7; expand §9.8 inline.

**Phase 8 status**: §9.8 / 8.0+8.1 [x]; 8.2 IN-PROGRESS. Phase 8
残 rows = 8.2 (D-051 emit.zig prologue extraction, ADR-grade,
**NEXT**) + 8.3 (windowsmini bench disposition) + 8.4-8.10
(optimisation pipeline + AOT skeleton + bench delta + audit +
open §9.9).

The 37 residual RUN-TRAP fixtures from 8.1's baseline are
non-WASI engine gaps (globals / call_indirect / runtime-fn
paths) — to be discharged across §9.8 / 8.4-8.7 optimisation
pipeline as opportunistic gaps, not as fresh debt entries.

## Active task — §9.8 / 8.2: D-051 x86_64/emit.zig prologue extraction **NEXT**

ADR-grade refactor; mirror of ARM64 ADR-0021 (`prologue.zig`
pattern). Sub-tasks per `.dev/debt.md` D-051:

1. Draft ADR `0030_x86_64_prologue_split.md` mirroring
   ADR-0021's structure (compute byte-offsets via helper,
   `body_start_offset`, etc.).
2. Extract prologue/epilogue from `src/engine/codegen/x86_64/
   emit.zig` (4305 LOC) into `src/engine/codegen/x86_64/
   prologue.zig` with corresponding helpers.
3. Migrate the ~50+ test sites in `test/runners/` that compute
   byte offsets manually to use the helper (regret #6 from
   2026-05-04 retrospective applies here).
4. Verify spill-aware staging path remains green (BASELINE delta
   check).

Exit: `x86_64/emit.zig` under §A2 2000 LOC hard cap; D-051
deleted from `.dev/debt.md`; spec-jit-compile + realworld
baselines unchanged.

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
