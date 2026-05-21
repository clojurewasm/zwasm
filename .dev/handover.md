# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure — §9.12-H in progress

§9.12-H bench baseline (Mac aarch64 Wasm 2.0 + wasmtime comparison).

**Sub-deliverables**:

| # | Deliverable | Status |
|---|---|---|
| (1) | `--compare=wasmtime` flag in `scripts/run_bench.sh` (dual-runtime hyperfine + `runtime:` YAML field) | ✅ this commit |
| (2) | `--capture-rss` flag (/usr/bin/time -l on Mac, -v on Linux; `max_rss_kb` YAML field) | ✅ this commit |
| (3) | 26-fixture full bench run on Mac aarch64 ReleaseSafe with `--phase-record --compare=wasmtime --reason="p9-close: Wasm-2.0 baseline (Mac aarch64)"`; appends row to `bench/results/history.yaml` | open (next cycle: substantial wall-clock — 26 × 2 runtimes × hyperfine 5-runs + 3-warmups ≈ ~10-20 min) |
| (4) | Document zwasm vs wasmtime mean_ms ratio (in commit body or audit doc) | open (after (3); pulled from the history.yaml row) |

**Smoke-test evidence (this cycle)** on `tinygo/fib` quick mode:
- zwasm: mean 2.11 ms, max_rss 3488 KB
- wasmtime: mean 5.27 ms, max_rss 13696 KB
- (Single quick run; not the baseline record.)

**Next pickup**: (3) — run the full 26-fixture phase-record.
Command:

```sh
bash scripts/run_bench.sh --compare=wasmtime --capture-rss \
    --phase-record \
    --reason="p9-close: Wasm-2.0 baseline (Mac aarch64; §9.12-H)"
```

After it lands, commit the new `bench/results/history.yaml` row +
note the mean_ms ratio in handover.

## Recent context

- §9.12-G closed (`4bd62842`); all 7 sub-deliverables a-g done.
- File-size reform (cycles C1..C6, 2026-05-21): ADR-0099/0100/0101
  + rule + script + lesson + init_expr.zig redesign. Archived
  at `private/archive/2026-05-21-file-size-reform/`.

## Active `now` debts

- **D-055** (mechanical, multi-cycle): emit_test_int has 27 sites
  pending.

## Other queued work

1. **§9.12-H (3) + (4)** — this cycle's next pickup.
2. **§9.12-I** — ADR/lesson curation closure (Phase 9 close).
3. **D-055 continuation**.
4. **Phase 10 ZirOp slot policy ADR** — gates memory64 /
   relaxed-simd file-level placeholder additions.

## Active state (snapshot)

- §9.12-A enforcement: 11 items OK + `check_wasm_h_upstream.sh`.
- §9.12-F (D-141 + reform): closed.
- §9.12-G: closed (`4bd62842`).
- §9.12-H: in progress — (1)+(2) ✅ this commit; (3)+(4) open.
- §9.12-I: open.

## Open questions / blockers

- なし for §9.12-H continuation.

## See

- [ROADMAP](./ROADMAP.md) §9.12-H scope + exit
- [`scripts/run_bench.sh`](../scripts/run_bench.sh) — `--compare`
  + `--capture-rss` flags landed
- [`bench/README.md`](../bench/README.md) — YAML schema reference
- [`bench/results/history.yaml`](../bench/results/history.yaml) — destination for (3)
- [`debt.md`](./debt.md), [`lessons/INDEX.md`](./lessons/INDEX.md)
