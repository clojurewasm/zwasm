# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## ACTIVE (2026-06-05, user→autonomous) — ADR-0163 bench program done; arm64 JIT completeness gaps queued

User-directed bench program (directives 1-4) all DONE: **D-285** memory.copy byte-loop FIXED both backends
(`4e6d17fc`/`838de5a1`; memmove jit 254→39ms, 3-host green, findings `.dev/findings/d285_*`); **ReleaseFast**
methodology fix (`b8fe1f74`); **docs refreshed** with definitive 3-host numbers (`bd0581e6`/`7d9dfbe0`); **bench
breadth** +6 shootout fixtures (`f8a0f43f`, crypto/parse/PRNG/dispatch). base64 re-attributed (optimizer gap,
not a bug). Breadth EXPOSED 4 real zwasm gaps — now the active queue, each mechanism CONFIRMED this turn with a
ready fix plan in its debt row:
- **D-289 GPR PATHS FIXED + VERIFIED (`340eaf5e`)**: arm64 large frame-offset addressing — `frameAddrLarge`
  + `frameLdrGpr`/`frameStrGpr` applied to body local.get/set/tee (i32/i64/ref) + prologue scalar/home-seed +
  gpr.zig spills. 2 new fixtures green (`many_locals` local off~40k→305419896; `many_locals_spill` spill
  off>32760→210) + 83 edge + full test + **ubuntu green** (`OK 701cbe60`), no regression. x86_64-clean (disp32).
  **Remaining D-289**: FP/v128 + param-marshal + stack-args large arms still cap (follow-on, no fixture yet).
- **D-291 (NEW)**: ed25519 now COMPILES but **SIGSEGVs at runtime** (jit). CORRECTED: the [stack_probe] diag
  margin was ~16 MB (SP far above limit) → **NOT stack exhaustion** (mis-said D-288 last turn). Genuine memory
  fault; needs `debug_jit_auto` (lldb at faulting PC) — D-289-path miscompile in an untested combo, OR a
  pre-existing JIT bug newly exposed (ed25519 never JIT-ran before). wasmtime runs it clean; not gated.
- **D-288 mechanism CONFIRMED (`3b128e97`)**: interp recursion cap = `frame.zig max_frame_stack=256` (fixed
  inline `frame_buf:[256]Frame`, pushFrame traps at 256). NOT a trivial bump — Frame embeds `label_buf[128]`
  so frame_buf is already large; fix = frame-stack inline+heap-overflow redesign (mirror label_buf+
  label_overflow) OR move label_buf off-Frame, likely an ADR. JIT side separate (native stack).
- **NEXT** (fresh-context candidates, all ready-scoped in debt): **D-288** (frame-stack redesign — real fix,
  ADR-likely) · **D-291** (ed25519 JIT SIGSEGV via debug_jit_auto) · **D-284** (entry-resolution unify) ·
  **D-289 FP/param/stack arms** (low signal) · **D-287** (control-stack cap ADR) · **D-286** (fill/init) ·
  **D-290** (wabt→wasm-tools hygiene). The deep/design ones (D-288/D-291/D-287) want fresh context.
- 3-host: ubuntu green @701cbe60; **windows gate (D-289 turn) — verify `/tmp/win.log` at Step 0.7**; the tail
  showed `zwasm-zig-host-hello.exe` mid-run/`failed command` — confirm OK vs a real Win64 issue (D-289 is
  arm64-only so unlikely from it). Prior full 3-host green = D-285 `838de5a1`. This turn = debt only (no src).

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** The **v0.1.0-scope program is
  thoroughly complete + 3-host green** (`deb97903`): all-engine WASI (interp+JIT+AOT; D-251/D-244), realworld
  validated (D-283), full AOT-WASI syscall test matrix, accurate docs, audited scaffolding, debt clean (0 `now`),
  perf no-deficiency (D-265 closed). The 2026-06-05 bucket-3 plateau is now **superseded** by a new user-directed
  program (below).

## USER-DIRECTED PROGRAM (2026-06-05) — release-readiness: benchmarks + official docs (ADR-0163)

Charter + scope + the ADR-0156 boundary (this PREPARES release artifacts; it does NOT tag/publish — release stays
user-only): **[`ADR-0163`](decisions/0163_release_readiness_bench_and_docs_program.md)**. Five workstreams; run as
ordinary Phase-16 work (survey-first; bundle multi-cycle pieces). Order **B→A→C→D→E** (D/E doc-only, parallel-OK).

- **B — Multi-runtime provisioning. ✅ DONE (`310314bb`).** `flake.nix` gained `devShells.bench` pinning
  wasmtime/wazero/wasmer/wasmedge (Mac-host-only; test hosts never build it). `run_bench.sh --compare` learned
  `wasmedge` (`wasmedge WASM`, WASI _start; interpreter by default). **wasm3 deliberately excluded** (nixpkgs marks
  0.5.0 insecure — 8 CVEs, unmaintained; not in v1's set → no parity lost). End-to-end verified: `--bench=tinygo/fib
  --compare=all --quick` → all 5 runtimes (zwasm 5.31 / wasmtime 6.87 / wazero 5.92 / wasmer 11.48 / wasmedge 13.47
  ms — startup-dominated tiny workload). node/bun still deferred (need JS WASI wrapper → A).
- **A — Benchmark suite expansion. ✅ core DONE.** `--engines=interp,jit,aot` matrix (`3195fda3`) +
  **full-inventory all-engine × all-comparator re-profile with RSS** (`81d99b1a`) → honest result doc
  `bench/results/all_engine_matrix.md`; corrected `s15p_parity_vs_v1.md`'s false "jit compute-only" claim (D-244).
  **Honest findings (no spin)**: zwasm wins memory footprint (2–5MB vs 8–28MB = 4–12×) + startup; optimizing JITs
  (wasmtime/wasmer Cranelift, wazero) lead on sustained compute 1.5–3.9× = the designed single-pass no-optimizer
  trade (§1.3). **Surfaced 2 real perf bugs → debt**: **D-285** (memmove zwasm-jit 254ms SLOWER than interp 138ms
  & ~15× wasmtime; base64 ~13× — byte-loop/bulk-`memory.copy` fast-path gap; ADR-0153 rework candidate) + **D-284**
  (nbody no-`_start` harness gap). *Optional A leftover (low priority)*: node/bun V8 comparator (JS WASI wrapper).
- **C — Official benchmark docs. ✅ DONE (`40959da3`).** `docs/benchmarks.md` (public-quality) built from the
  matrix: TL;DR positioning, methodology, how-to-read (startup confound), 3 result tables (sustained compute /
  startup-bound / RSS), engine-selection guide, reproduction. Honest throughout; linked from README Documentation.
- **D — OSS README.md. ← NEXT.** Current `README.md` already solid (status, platforms, coverage, CLI, embedding,
  build flags, quickstart, layout, docs links). D = audit/upgrade to general-OSS standard: confirm pitch/badges,
  feature highlights, engine table (done), WASI/proposal matrix, **bench link (done)**, embedding examples
  verified-to-run, contributing, license. Mostly a polish/verify pass, not a rewrite — check what's already there
  first (Step 0).
- **C — Official benchmark docs.** Public-quality `docs/benchmarks.md` (or `docs/reference/benchmarks.md`):
  methodology, host matrix, results vs other runtimes + vs v1, reproduction, caveats (startup-confound). Link from
  README.
- **D — OSS README.md.** General open-source README: pitch, badges, features, install, quickstart, engine table,
  WASI/proposal matrix, bench link, embedding (Zig/C API), contributing, license. Keep the accurate "all-engine
  WASI; jit adds SIMD" framing (`046c6b9e`).
- **E — User + migration guide final fix.** `docs/tutorial.md` + `docs/migration_v1_to_v2.md` to release quality
  (complete, accurate, examples verified-to-run). Migration compute-only claims already corrected (`046c6b9e`).

## Step 0.7 (next resume) — verify remote logs

Last 3-host green = `8b19faad`. ALL program commits so far (B: `20de319d`/`310314bb`; A: `3195fda3`/`81d99b1a`;
C: `40959da3`) touch only `flake.nix` (NEW `devShells.bench`), `scripts/run_bench.sh` (Mac bench script, not run
by `test-all`), and `bench/`+`docs/`+`README.md`+`.dev/` docs/debt → **no `src/` delta since `8b19faad`**, so no
remote re-kick. A fresh `/continue` resumes on **workstream D** (README polish), not a remote-verify.

## Deferred / open

- **D-285 (NEW, ADR-0153 rework candidate)** — JIT byte-loop/bulk-memory codegen deficiency (memmove jit slower
  than interp). Scheduled as a rework campaign **AFTER** the user's C/D/E doc program (don't abandon the explicit
  program to chase it; it's captured + the perf is a designed-trade-adjacent codegen gap, not a correctness bug).
- **v0.2.0 / Component Model + WASI 0.2** — ROADMAP-deferred (ADR-0161 §3); needs a user scope decision (NOT this
  program). **D-281** sockets (v1 also stubs — not a parity miss). **D-255** C-API io (ADR-0143). **D-211** precise
  GcRootMap (ADR-0148/0060). **D-284** nbody bench harness gap. Debt ledger = 61 rows, 0 `now`.

## Key refs

- **ADR-0163** (this program). ADR-0156 (no autonomous release — the boundary). ADR-0161 (WASI program, done).
  ADR-0012 §7 / ADR-0040 (bench cadence / cold-start). ADR-0159 (CLI=run+compile). ROADMAP §12.4 (bench), §16.
- v1 bench: `~/Documents/MyProducts/zwasm/bench/`. v2: `bench/README.md`, `bench/results/*`, `scripts/run_bench.sh`,
  `.github/workflows/bench.yml`. README/docs: `README.md`, `docs/{tutorial,migration_v1_to_v2,reference/cli}.md`.
