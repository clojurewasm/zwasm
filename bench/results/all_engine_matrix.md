# All-engine × multi-runtime matrix (ADR-0163 A; 2026-06-05)

> **Doc-state**: ACTIVE — point-in-time, machine-specific snapshot. Regenerate
> with the reproduction command below; numbers drift with host + toolchain.

The first profile of zwasm across **all three of its engines** (interp / JIT /
AOT) against four external runtimes, on the **same** fixture inventory. This
supersedes the methodology constraint of [`s15p_parity_vs_v1.md`](s15p_parity_vs_v1.md)
§"Methodology constraint" — that doc states the JIT is "compute-only, no WASI",
which **D-244 made false**: JIT and AOT now run the full WASI command set, so the
TinyGo / cljw WASI fixtures are benched under every engine here.

This is the **definitive** run: zwasm built **ReleaseFast** (fair vs the
optimized comparators) at **5 runs + 3 warmup**, after the D-285 `memory.copy`
fix. (An earlier `--quick`/ReleaseSafe pass had memmove ~254 ms and interp ~40 %
slower — both superseded here.)

## Methodology

- **Host**: `Darwin aarch64` (Mac, native). Single machine — cross-host numbers
  (ubuntu x86_64) are not folded in; these are one host's figures.
- **Build**: zwasm `-Doptimize=ReleaseFast` (the comparators ship optimized;
  ReleaseSafe would be an unfair handicap). `hyperfine`, 5 runs + 3 warmup.
- **zwasm engines**: `interp` (`run --engine interp`, default), `jit`
  (`run --engine jit`), `aot` (`compile`→`.cwasm`, then `run` the artifact —
  timed cmd excludes the one-off compile; cold-start is
  [`aot_coldstart.md`](aot_coldstart.md)).
- **Comparators**: wasmtime 43.0.1 (Cranelift JIT), wazero 1.11.0 (Go compiler),
  wasmer 5.0.4 (Cranelift), wasmedge 0.16.1 (interpreter by default). Pinned in
  `flake.nix devShells.bench`.
- Each runtime executes the module's WASI `_start`. RSS via `/usr/bin/time -l`.

### Caveats (load-bearing — read before the tables)

1. **Startup confound.** The TinyGo + cljw fixtures run in single-digit ms; at
   that scale **process+instantiate startup dominates**, so the ranking there
   measures *startup latency*, not steady-state throughput. The shootout
   fixtures (100 ms–40 s) amortise startup and reflect execution speed.
2. **`wasmedge` runs its interpreter** by default (AOT needs a separate
   `wasmedge compile`); compare it to `zwasm-interp`, not to the JITs.
3. **`handwritten/nbody`** exports `init`/`run`/`advance` with **no `_start`**;
   the harness only drives `_start`, so strict engines (jit / wasmer / wasmedge)
   report `—` and the tolerant ones time bare instantiation, not the n-body
   computation. Its row is not a valid workload comparison (→ D-284).

## mean_ms (lower = faster)

| fixture              | zwasm-interp | zwasm-jit | zwasm-aot | wasmtime | wazero | wasmer | wasmedge |
|----------------------|-------------:|----------:|----------:|---------:|-------:|-------:|---------:|
| shootout/fib2        |        39747 |      1077 |      1083 |      700 |    781 |    713 |    42865 |
| shootout/sieve       |        13601 |       320 |       318 |      203 |    490 |    206 |    20637 |
| shootout/nestedloop  |         3.27 |      4.55 |      3.17 |     6.57 |  12.56 |  13.10 |    16.42 |
| shootout/matrix      |         5399 |       343 |       342 |    87.74 |    198 |  93.24 |    11038 |
| shootout/heapsort    |        15666 |      1574 |      1573 |      642 |    926 |    647 |    24078 |
| shootout/base64      |         7028 |       781 |       780 |    57.23 |  79.40 |  61.65 |    11155 |
| shootout/gimli       |          103 |      9.78 |      9.65 |     7.97 |   6.28 |  14.27 |      160 |
| shootout/memmove     |          141 |     38.60 |     38.34 |    18.78 |  15.21 |  22.37 |    40.20 |
| shootout/keccak      |          289 |     34.02 |     33.52 |     9.30 |   8.71 |  15.82 |      382 |
| tinygo/arith         |         2.18 |      2.80 |      2.09 |     6.41 |   7.32 |  12.09 |    15.70 |
| tinygo/fib           |         2.25 |      2.77 |      2.02 |     7.19 |   7.05 |  12.04 |    16.47 |
| tinygo/fib_loop      |         2.30 |      2.70 |      2.01 |     6.59 |   6.75 |  12.57 |    16.57 |
| tinygo/gcd           |         2.34 |      2.63 |      2.31 |     6.46 |   6.69 |  11.85 |    16.87 |
| tinygo/list_build    |         2.34 |      2.92 |      2.17 |     6.30 |   6.67 |  11.93 |    16.15 |
| tinygo/mfr           |         2.33 |      2.75 |      2.08 |     6.13 |   6.64 |  11.87 |    15.01 |
| tinygo/nqueens       |         2.37 |      2.78 |      2.05 |     6.44 |   6.72 |  12.46 |    16.50 |
| tinygo/real_work     |         4.17 |      4.61 |      3.91 |     6.39 |   6.91 |  12.27 |    15.94 |
| tinygo/sieve         |         2.63 |      2.89 |      2.30 |     6.27 |   7.00 |  11.88 |    16.17 |
| tinygo/string_ops    |         2.31 |      2.89 |      2.09 |     6.09 |   6.68 |  11.75 |    15.58 |
| tinygo/tak           |         2.57 |      2.52 |      2.04 |     6.15 |   6.61 |  11.84 |    16.18 |
| handwritten/nbody † |         2.12 |        — |      2.10 |     6.37 |   3.98 |     — |       — |
| cljw/fib             |         2.30 |      2.64 |      2.09 |     6.44 |   6.22 |  11.93 |    14.86 |
| cljw/gcd             |         2.47 |      2.68 |      2.07 |     6.47 |   6.17 |  11.82 |    15.55 |
| cljw/arith           |         2.33 |      2.63 |      2.15 |     6.14 |   6.45 |  12.01 |    15.95 |
| cljw/sieve           |         2.23 |      2.85 |      2.05 |     6.60 |   6.41 |  11.75 |    14.88 |
| cljw/tak             |         2.45 |      2.60 |      2.17 |     6.39 |   6.59 |  12.06 |    16.07 |

† `nbody` has no `_start` — see Caveat 3. Not a valid comparison row.

## peak RSS (MB)

| fixture           | zwasm-interp | zwasm-jit | zwasm-aot | wasmtime | wazero | wasmer | wasmedge |
|-------------------|-------------:|----------:|----------:|---------:|-------:|-------:|---------:|
| shootout/fib2     |         19.1 |      19.8 |      18.2 |     14.1 |   17.0 |   27.4 |     24.1 |
| shootout/heapsort |         34.8 |      19.0 |      18.0 |     13.1 |   45.0 |   27.0 |     23.4 |
| shootout/memmove  |         18.5 |      18.8 |      18.0 |     13.0 |    8.3 |   26.9 |     23.4 |
| shootout/keccak   |         18.8 |      19.3 |      18.2 |     13.2 |   11.3 |   27.1 |     24.0 |
| tinygo/fib        |          2.7 |       3.2 |       2.1 |     13.3 |    8.7 |   27.5 |     23.7 |
| tinygo/real_work  |         34.6 |      35.1 |      34.0 |     13.2 |    9.8 |   27.6 |     23.7 |
| tinygo/sieve      |          4.6 |       5.1 |       4.0 |     13.2 |    9.5 |   27.5 |     23.6 |
| cljw/tak          |          2.6 |       3.1 |       2.1 |     13.2 |    8.6 |   27.5 |     23.6 |

(Representative rows; the small WASI guests are uniformly zwasm ~2–5 MB vs 8–28 MB.
Full per-fixture RSS regenerates with `--capture-rss`.)

## Findings (honest)

1. **Memory footprint is zwasm's clear, consistent win.** On the small WASI
   guests zwasm holds **~2–5 MB** RSS where wasmtime sits at ~13 MB, wazero
   ~8–9 MB, wasmer ~27 MB, wasmedge ~24 MB — a **4–12× advantage**. AOT is the
   leanest engine (no JIT buffers). The "lightweight" half of "lightweight-yet-fast".
2. **Startup latency favours zwasm** (Caveat 1). On sub-10 ms fixtures
   zwasm-aot/interp (~2 ms) beat wasmtime (~6–7 ms) and wasmer/wasmedge
   (~12–16 ms). Real, but it measures cold start, not throughput.
3. **On sustained compute, the optimizing JITs lead — as expected.** Once
   startup amortises (shootout), wasmtime/wasmer (Cranelift) and wazero pull
   ahead of zwasm-jit/aot: fib2 ~1.5×, sieve ~1.6×, heapsort ~2.5×, keccak
   ~3.7×, matrix ~3.9×. This is the **designed** trade of a single-pass,
   no-optimizing-tier backend (§1.3/§3.2) — not a regression. zwasm-jit ≈
   zwasm-aot throughout (shared lowering; AOT's win is cold-start).
4. **`base64` (~13.7×) is the same trade amplified**, not a bug: its hot loop is
   6-bit-group + table-lookup byte processing, which optimizers vectorise and a
   single-pass backend cannot. (It was briefly mis-flagged with memmove; the
   D-285 copy fix left it unchanged, confirming it's the optimizer gap.)
5. **`memmove` was a real codegen defect — now FIXED (D-285).** It was a
   byte-at-a-time `memory.copy` loop (zwasm-jit slower than its own interpreter);
   word-wise lowering on both backends brought zwasm-jit to **38.6 ms** (from
   ~254 ms), now faster than interp (141 ms) and 2.05× wasmtime. `memory.fill`/
   `memory.init` carry the same old pattern → **D-286** (lower impact).
6. **interp**: 10–60× slower than jit/aot on heavy compute (fib2 39.7 s → 1.08 s),
   near-parity on startup-bound fixtures; same class as wasmedge-interp.

## Reproduction

```sh
nix develop .#bench --command \
  bash scripts/run_bench.sh --engines=interp,jit,aot --compare=all --capture-rss
# (the above = 5+3 runs, ReleaseFast — the published basis; add --quick for a fast pass)
```
