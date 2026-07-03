# bench/

Benchmark history (append-only) and runner data.

## Layout

```
bench/
├── README.md          # this file
├── results/
│   ├── history.yaml   # committed, append-only, phase-boundary entries only
│   └── recent.yaml    # gitignored, rolling per-commit
├── runners/           # bench wasm samples (Phase 10+)
│   └── src/           # source for runners (committed)
└── fixtures/          # bench-specific data files (Phase 10+)
```

The `results/` split (committed `history.yaml` vs gitignored
`recent.yaml`) was introduced 2026-05-04 per §9.6 / 6.H +
ADR-0012 §7. The two-file approach prevents per-commit bench
runs from inflating git history; only phase-boundary results are
preserved long-term.

## Cadence (ROADMAP §12.4)

- **Local manual**: `bash scripts/run_bench.sh [--quick]` writes
  `bench/results/recent.yaml`. Adding `--phase-record
  --reason="<tag>: <gist>"` also appends one row to
  `bench/results/history.yaml`. `scripts/record_merge_bench.sh`
  is the wrapper.
- **Per-merge under PR-only `main`**: record the bench **on the
  feature branch before opening the PR** and commit
  `history.yaml` **into the same PR** as the code — NOT as a
  post-merge follow-up (ruleset-protected `main` would require a
  separate PR per merge). Put the PR intent in `--reason`; the
  entry's SHA is the branch tip (cosmetic). Skip for trivial /
  doc-only changes.
- **Per-push CI**: [`.github/workflows/bench.yml`](../.github/workflows/bench.yml)
  runs `--quick --phase-record` on every push to
  `main` across `macos-latest` (aarch64-darwin) +
  `ubuntu-latest` (x86_64-linux). Each arch uploads a YAML
  fragment as an artifact; an `aggregate` job merges them in
  arch-name-sorted order into `history.yaml` and pushes one bot
  commit tagged `[skip ci]`. windowsmini stays a local-only path
  (no GitHub-hosted Windows bench runner).

## Schema (ROADMAP §12.3)

```yaml
- date: 2026-XX-XXTHH:MM:SSZ
  commit: <full SHA>
  arch: aarch64-darwin | x86_64-linux | x86_64-windows
  reason: "<phase-tag>: <one-line>"
  runs: 5
  warmup: 3
  benches:
    - name: <bench-name>
      mean_ms: 12.34
      stddev_ms: 0.45
      min_ms: 11.80
      max_ms: 13.10
```

The recorded values are `mean / stddev / min / max` as produced
by hyperfine's `--export-json`. Earlier drafts of this README
documented a `median_ms` field; the script never wrote one. Use
`mean_ms` as the primary central-tendency field (rationale:
hyperfine reports mean, and we keep tool fidelity rather than
compute a derivative). For sub-millisecond fixtures, treat
`mean_ms` as ordinal — `min_ms / max_ms` give the dispersion
shape. (Schema clarification 2026-05-12 / §9.9-j-2 per
ADR-0056.)

`bench/results/history.yaml` is append-only (ROADMAP §A9). Rows
are added by `scripts/run_bench.sh --phase-record` (manual /
phase boundary) and the per-push CI bench-aggregate job
([`.github/workflows/bench.yml`](../.github/workflows/bench.yml)).
Never edit historical rows.

`bench/results/recent.yaml` is gitignored and overwritten on
every local run.

## No fixed numeric targets (ROADMAP §12.1)

Per-phase numeric ratios (e.g. "within 1.5× of wasmtime") are
deliberately not set. Goodhart's law: a numeric target distorts
behaviour toward the number, not the underlying goal. Comparison
against reference runtimes (wasm3, wasmtime baseline, wasmtime
cranelift, wasmer singlepass) is recorded but not gated.

## Current status (post-Phase-7, Phase-8 onward)

`scripts/run_bench.sh` is hyperfine-driven; CI records two arch
rows per push (per the cadence above). Local phase-boundary
rows continue to land via `--phase-record`. The pre-Phase-6
trap-time baseline rows are preserved per ADR-0011 §3.
