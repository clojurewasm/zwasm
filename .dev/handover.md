# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure — §9.12-H ready to flip [x]; §9.12-I next

§9.12-H deliverables (3)+(4) landed this commit (the
phase-record bench row + mean_ms ratio documentation). With
(1)+(2) already in `06a09da6`, §9.12-H is functionally complete;
the `[x]` flip + handover retargeting happen in the same
commit pair.

**Baseline measurements** (Mac aarch64 ReleaseSafe, hyperfine
`--warmup 3 --runs 5`, 26 fixtures × 2 runtimes, history.yaml
row `p9-close: Wasm-2.0 baseline (Mac aarch64; §9.12-H)`):

- **zwasm wins startup-dominated workloads** (tinygo/* +
  cljw/* + handwritten/nbody): zwasm 1.05–2.89x faster than
  wasmtime. zwasm RSS ~3.3–5.5 MB; wasmtime RSS ~13 MB.
- **wasmtime wins compute-heavy workloads** (shootout/*):
  wasmtime 8–100x faster (fib2 / heapsort / sieve / matrix /
  base64). zwasm's per-op JIT-emit overhead dominates on the
  long-running benches; wasmtime's AOT optimisation amortises.
- shootout/nestedloop is the one shootout zwasm wins (1.56x
  faster) — light loop body, startup-cost-dominated.

Total (26-fixture sum): zwasm 87.06s / wasmtime 1.80s; the
shootout outliers dominate the aggregate — the ratio is most
useful per-fixture, not as a single number.

**Next pickup: §9.12-I** — ADR + lesson + private/ closure
(Phase 9 close). Sub-deliverables per ROADMAP:

1. D-149 discharge (ADR Phase-9 cohort SHA backfill 75 → 0).
2. ADR Status canonical pass (~22-25 `Accepted` → `Closed (Phase X DONE)`).
3. skip-ADR Status wording cleanup.
4. Lesson Citing backfill.
5. Lesson promotion scan (3+ citations → ADR conversion).

Exit: `check_adr_history.sh --gate` 0; `check_lesson_citing.sh`
0; ADR `Accepted` count < 30.

## Recent context

- §9.12-G closed (`4bd62842`); §9.12-H (1)+(2) `06a09da6`;
  §9.12-H (3)+(4) this commit.
- File-size reform (cycles C1..C6, 2026-05-21): ADR-0099/0100/0101
  + rule + script + lesson + init_expr.zig redesign.

## Active `now` debts

- **D-055** (mechanical, multi-cycle): emit_test_int has 27 sites
  pending.

## Other queued work

1. **§9.12-I** — this cycle's next pickup.
2. **D-055 continuation**.
3. **Phase 10 ZirOp slot policy ADR** — gates memory64 /
   relaxed-simd file-level placeholder additions.
4. **Bench follow-ups (Phase 11 scope)**: wazero / wasmer /
   bun / node comparators; `-Dwith-bench-compare` build flag.
5. **Bench observation: zwasm compute-heavy gap** — the
   shootout 8–100x wasmtime advantage is the canonical Phase
   11+ optimisation target; not actionable in Phase 9 close.

## Active state (snapshot)

- §9.12-A enforcement: 11 items OK + `check_wasm_h_upstream.sh`.
- §9.12-F (D-141 + reform): closed.
- §9.12-G: closed (`4bd62842`).
- §9.12-H: this commit closes it.
- §9.12-I: next.

## Open questions / blockers

- なし for §9.12-I.

## See

- [ROADMAP](./ROADMAP.md) §9.12-I scope + exit
- [`bench/results/history.yaml`](../bench/results/history.yaml) — baseline row landed
- [`scripts/run_bench.sh`](../scripts/run_bench.sh)
- [`debt.md`](./debt.md), [`lessons/INDEX.md`](./lessons/INDEX.md)
