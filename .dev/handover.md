# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Just closed — D-293 array_oob COMPLETE (`855ca5ca` + `dafab5ce`); D-293 trap-kind demux effectively done

**`855ca5ca`**: array.get_s/get_u rerouted null→null_reference (10) + OOB→oob_memory (6) (were generic).
**`dafab5ce`**: array.fill/copy trampolines (jitGcArrayFill/Copy) now return `ARRAY_NULL_SENTINEL` (2) so
both arch callers split null (10) vs OOB (6) — were collapsed to W0=0. **All 6 array trap sites now
precise + consistent with array.get/set + interp.** Tests via wasm-tools `(array (mut i8))` (fill/copy need
MUTABLE). 2869/2881 + lint green. **3-host green** (windows recorded `27a02958`, 25437/0). **D-293 demux
COMPLETE**; only residual = D-294-R2 code-2 SUB-split (call_indirect vs table-access OOB message, both code
2), conformance-neutral CLI polish (deferred).

**STEADY-STATE (Phase-17 完成形)**: readily-actionable codegen refinement DONE + 3-host green (sandbox triad
+ full trap-kind demux + JIT value-trace tooling). Remaining = disproportionate-deep / conformance-neutral:
**c_sha256 `\n`** (real miscompile, confirmed wpos=10 not 11 for verify-line pure-string printf; multi-step
musl length trace, parked as disproportionate for a cosmetic symptom), **go corruption** (non-deterministic,
infra-blocked), **D-294-R2** (conformance-neutral CLI msg). No quick wins; loop monitors + holds steady-state.

## Earlier this session (SHAs durable; detail in commits/debt)

**D-294 R1** `2a53213f`: subtyping call_indirect null elem → uninitialized_elem (13) via `NULL_ELEM_SENTINEL`.
**Sandbox triad** `bd355258`+`fa4678f4`: JIT table initial-alloc + `table.grow` caps + CLI `--max-table-elements`
(fuel/memory/table cross-engine complete; D-314(b)/D-332 closed). **3-host**: windows green `cefdca2b` (25437/0).

**Phase-B debug tooling (prior turns)** — `ZWASM_DEBUG=jit.dump` (`db3109d8`/`f49b3675`) +
`scripts/jit_value_trace.sh` (`39d53605`) for JIT value-traces. Detail: debug_jit_auto Recipe 18 + lesson
`2026-06-15-lldb-value-trace-on-jit-code`.

**D-330 c_sha256 `\n`** mechanism confirmed `4365e478` (LINE-buffered; verify-line iov[0]=10 not 11, \n
dropped at buffer-construction). Full trail + next-probe in D-330 debt residual. Deprioritized cosmetic.

## Prior session (SHAs durable; detail in commits/debt)

**D-332** `3cb5e3bf` interp `max_table_elements` initial-alloc cap. **D-330 primary** `6790c204` LSRA
strict-`<` expiry (+ `cccb2313` x86_64 fp-select clobber). **D-289** `682401fd` regalloc cap 4095→65535.
wasm-2.0-assert 25437/0 on arm64 + Rosetta + ubuntu + Win64. Residual = c_sha256 `\n` (above).

## ACTIVE AGENDA (user-directed 2026-06-14) — real-world toolchain/bench reproduction

Project is feature-complete + 3-host green + tag-ready (**tag = USER-ONLY, ADR-0156**).
D-238 x86_64 EH `c534afca`; cljw guest-wasm retired `02ef14b0` (cljw tests consumer-side).

**The agenda — drive via `/continue`. Authoritative plan (ordering + 2026 language
scope + the live JIT-trap inventory):**
[`realworld_reproduction_plan.md`](realworld_reproduction_plan.md) — its work sequence
supersedes ROADMAP §9 for these tasks. **User ordering: Phase A QUICK → Phase B
SUSTAINED**; the user assists when a toolchain needs installing.

- **Phase A — reproduction infra: DONE.** A1 Zig fixtures (`5c044967`; AssemblyScript/WasmGC →
  D-329) + A2 embenchen (`1aac480f`) + A3 `--wasmer` 2nd-oracle lane (`897b54d7`) + runtime bump
  (wasmtime 45 / wasmer 7.1). A4 remote rust provisioning = D-254; hyperfine = D-249. Details in plan.
- **Phase B — deep JIT bug-hunt (SUSTAINED).** B1 = D-283 `--jit` lane DONE (`219dbd17`); now working
  the remaining miscompiles (D-330 coalescing FIXED `6790c204`; see Phase-B status below). Multi-cycle.

**Tool currency (user directive 2026-06-14) DONE+VERIFIED on ALL 3 hosts**: Mac+ubuntu via
flake (wasmtime 45, wasmer 7.1, nixpkgs 06-10, rust/zig-overlay 06-14; **zig PINNED 0.16.0**;
ubuntu gate green `fa0381cd`). windowsmini native via `install_tools.ps1` (wasmtime 45/
wasm-tools 1.251/+wasmer 7.1) — user REBOOTED 2026-06-14, verified ACTIVE (post-reboot ssh:
wasmtime 45.0.0/wasm-tools 1.251.0/wasmer 7.1.0/zig 0.16.0). windows gate re-validating with
wasmtime 45 (verify next Step 0.7). D-249 hyperfine-absent premise dissolved.

**Phase A+B history (DONE, archived in commits/debt/lessons)**: A2 embenchen `1aac480f`; B1 = D-283
`--jit` diff-lane `219dbd17` (realworld_run 56/56); D-331(A) table-cap red-herring fix `45ff0b94`
(+ D-332). All detail in those commits + the cited lessons; not repeated here.

**Dogfooding milestone (2026-06-15)**: the `test-realworld-diff-jit` corpus is now **1 mismatch** — ONLY
`c_sha256_hash` (107 vs 106). emcc_fasta flipped to byte-exact MATCH; this session's D-330 coalescing +
fp-select + D-289 fixes cleaned the rest. The last `c_sha256` `\n` residual is **DEPRIORITIZED** (niche
cosmetic; values + interp correct): **4 hypotheses now DISPROVEN** (func-11/func-8/block-merge/numbering-
desync). Empirically: func 4 regalloc VALID (0 overlaps) AND liveness↔emit PERFECT LOCKSTEP (561=561, 0
per-pc divergence) → NOT regalloc, NOT a desync. So it's a genuine value-miscompile (10→0 at a branch)
needing RUNTIME instruction tracing — source-level guessing failed 4×; do NOT re-chase. (NOT the same as
go_regex/D-331B, whose emit DOES exceed liveness — the prior "unification" was wrong.) **NEXT: diversify —
the JIT-residual cluster is exhausted of cheap leads; pick a 完成形 surface/dogfooding/debt item (e.g. D-332).**

**Phase-B status**: D-283 `--jit` lane 3-host green (REPORT-ONLY). **D-330 coalescing miscompile FIXED**
`6790c204` + x86_64 fp-select `cccb2313` — 4-env green. Remaining JIT-correctness debt, each its own
investigation, ALL parked/blocked with recipes recorded: **D-330 residual** (c_sha256 `\n` → func-8
`__overflow` fast-path miscompile; NICHE, partial — next-probe recipe in debt) + **D-331(A)-next** go_*
runtime-corruption (panicmem teardown deref; INFRA-BLOCKED — needs per-function interp-fallback bisect,
which does not exist) + **D-331(B)/D-289** go_regex — regalloc cap RAISED `682401fd` (4095→65535 +
allocator-backed buffers, the 4th dynamic-vs-fixed instance; func[1516]/16070 vregs now clears regalloc+
prologue); remainder = a SEPARATE emit-side `vreg>=slots.len` mismatch (parked, recipe in debt). **NEXT
(diversify — all JIT items parked/blocked)**: best COMPLETABLE clean item = **D-332** (sandboxing-triad:
bound the INITIAL eager table alloc, cross-engine). Design to decide+ADR: `store_table_elements_max` is
set post-instantiation, so add an instantiation-TIME cap source — thread `max_table_elements: ?u64=null`
through the JIT `RunLimits` + interp instantiate config (+ C/Zig API), enforce at the initial table
alloc (setup.zig + instantiate.zig) as a clean trap (not OOM); default null = unlimited (no regression).
TDD: adversarial fixture w/ huge declared table.min + cap. (go bugs are fix-but-still-broken / niche.) (A1 Zig + A2
embenchen + A3 wasmer-oracle + runtime-bump + tool-currency-3host + B1 jit-diff-lane DONE; D-331 primary
`10d7d2b2` + (A) `45ff0b94`; D-330 coalescing `6790c204` FIXED.)

## State (tag-ready baseline, all 3-host green)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM**
  default-ON (ADR-0182/0183; corpus 158/0/0). Sandboxing triad everywhere.
- **Surfaces**: C-API 293/293 (+preopen_dir/inherit_env, ADR-0184) · Zig-API
  complete (+`WasiConfig.{envs,preopens,io}` — full WASI parity) · lean CLI ·
  memory-safety sound · dogfooded into cw (consumer-side). Runners ReleaseSafe (ADR-0177,
  Rev 2026-06-14 floored `core_comp` too; `check_releasesafe_runners.sh` guards it).
- **EH**: cross-instance exception-handling on JIT works on BOTH arches (arm64 `4f73d9ee`
  + x86_64 D-238/ADR-0185 `c534afca`). Interp + JIT EH spec corpus green.
- **Debt**: 47 entries, **zero `now`**; all blocked-by are external (upstream
  Zig / hosts) / future-phase (11/12/14) / user-gated, or `note`/`partial` long-tail.
  D-283 Phase-B anchor; D-330 (%s) + D-331 (go, primary + (A) FIXED, miscompile-next) + D-332 JIT-debt.
- **Realworld corpus**: 50 fixtures (c/cpp/rust/tinygo/go), interp 50/50; JIT run-stage
  opt-in (`ZWASM_JIT_RUN=1`) — the Phase-B signal source. cljw fixtures retired.
- **Tag**: `v2.0.0-alpha.3` tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`realworld_reproduction_plan.md`](realworld_reproduction_plan.md) — the ACTIVE
  AGENDA's full plan. [`flake.nix`](../flake.nix) `devShells.gen` — fixture toolchains.
- [`docs/zig_api_design.md`](../docs/zig_api_design.md) · **ADR-0185** (x86_64 EH
  frame-walk) · **0177** (ReleaseSafe runners) · **0156** (NO autonomous release) ·
  **0153** (rework) · **0109** (Linker/facade API).
- lessons [`releasesafe-runner-floor-audit`] · [`global-predicate-cannot-replace-local-codemap`].
