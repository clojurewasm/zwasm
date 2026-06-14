# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active bundle

- **Bundle-ID**: D-330-jit-printf-disasm (JIT `%s`/strnlen miscompile hunt)
- **Cycles-remaining**: ~1-2
- **Continuity-memo**: ARCH-INDEPENDENT (arm64 == x86_64-Rosetta, interp correct both) ⇒
  **shared** codegen. Culprit = repro2.wasm **func 12** (vfprintf, 1087 vregs, well under
  4095 cap → reuse bug not cap). **Cycle-4 localized it**: the regalloc_compute.zig expiry
  `last_use_pc <= def_pc` def==last_use **slot-coalescing** is the bug — EXP2 (`<` strict) FIXES
  repro + flips both fixtures (c_sha256_hash, emcc_fasta) to MATCH, but breaks the intended-design
  test `regalloc_compute.zig:448`. So coalescing (result⟵last-use-operand, same slot) is unsafe
  here via (a) an op emit that writes result before reading the coalesced operand, OR (b) liveness
  under-computing a last_use. EXP5 ruled out select-result. Normal ALU is read-before-write safe ⇒
  leans (b) liveness, unconfirmed. NEXT (cycle-5): PC-window bisect (disable boundary-coalescing
  per def_pc range in func 12) → nail the ONE corrupting (freed_vreg,new_vreg,op,slot); then fix
  emit read-order OR liveness range — keep the :448 test green. Full trail: spike README cycle-4.
- **Exit-condition**: `zwasm run --engine jit repro2.wasm` prints `1:hi`/`2:lit` + the :448 test
  stays green + boundary fixture + lesson; D-330 deletable.

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
  the remaining miscompiles (active bundle D-330, see top + Phase-B status below). Multi-cycle.

**Tool currency (user directive 2026-06-14) DONE+VERIFIED on ALL 3 hosts**: Mac+ubuntu via
flake (wasmtime 45, wasmer 7.1, nixpkgs 06-10, rust/zig-overlay 06-14; **zig PINNED 0.16.0**;
ubuntu gate green `fa0381cd`). windowsmini native via `install_tools.ps1` (wasmtime 45/
wasm-tools 1.251/+wasmer 7.1) — user REBOOTED 2026-06-14, verified ACTIVE (post-reboot ssh:
wasmtime 45.0.0/wasm-tools 1.251.0/wasmer 7.1.0/zig 0.16.0). windows gate re-validating with
wasmtime 45 (verify next Step 0.7). D-249 hyperfine-absent premise dissolved.

**A2 embenchen DONE `1aac480f`**: 3 benchmarks (fannkuch/fasta/primes) reproduced via MODERN
emcc `-sSTANDALONE_WASM`→WASI (NOT the legacy env-shim ABI of the vendored `embenchen_*`
fixtures, which stay Phase-11/D-026). The find: modern path Just Works — zwasm runs all 3
byte-identical to wasmtime under its existing WASI host, no shim. realworld_run 56/56, diff
56/56. windows gate green on the new wasmtime 45 toolchain (recorded 3bc17f04).

**Phase B / B1 = D-283 — JIT-DIFF LANE LANDED `219dbd17`.** `zig build test-realworld-diff-jit`
(WASI-aware `runWasmJitCaptured` + byte-diff vs wasmtime). Real signal replacing the false
12-trap framing: **`diff_runner [jit]: 45/56 matched, 2 mismatched, 9 skipped`**. The truth: 45
JIT-correct, 2 genuine miscompiles, 9 `go_*` compile-gaps. B1 bundle CLOSED (lane = the deliverable).

**B2 PIVOTED → D-330 `a0dfccaf`+ (no active bundle).** The 2 miscompiles (`c_sha256_hash`,
`emcc_fasta`) were bisected over 4 cycles to **plain `%s` (no precision)** under --jit/--aot (codegen,
interp correct). FOUR reductions (generic varargs, array-store, hand-SWAR, count-limited scan, AND
the EXACT musl null-scan `((0x01010100-w)|w)&0x80808080` as minimal `.wat`) ALL run CORRECT — so it's
a **context-dependent regalloc/spill-class miscompile** that only manifests under the real ~large
vfprintf's register pressure (reduction can't isolate it). Filed **D-330** (focused `debug_jit_auto`
disasm campaign of repro2.wasm's printf_core; private/spikes/jit-vararg has all reductions). The
`--jit` lane keeps it visible (report-only). Niche (emscripten plain-%s stdout only; values correct).

**D-331(A) RESOLVED `45ff0b94` — hypothesis was a RED HERRING.** Not a go `_start` void-sig
asymmetry: a debug print at `runWasiLenient`'s entry gate NEVER fired → fault was UPSTREAM in
`setupRuntimeLinked` (setup.zig), a fixed `table_size > 4096` reject (Go funcref table = 5790).
Interp (instantiate.zig allocs `min` uncapped) ran go_* fine → JIT-only fixed-cap asymmetry. FIX:
removed the arbitrary cap (allocator-backed buffers, no fixed-array dep). go_hello now compiles +
instantiates + RUNS (correct stdout). THIRD dynamic-vs-fixed instance ([256]Frame `10d7d2b2`;
table_size; still-open max_slots=4095). Boundary fixture p10/large_table/over_4096. Filed **D-332**
(eager table alloc unbounded by `store_table_elements_max`, cross-engine). Lesson
`reject-error-was-an-upstream-fixed-cap`.

**BUT it revealed the genuine deep gap**: go_* now JIT-MISCOMPILE — Go runtime detects corruption
AFTER correct output, NON-DETERMINISTIC across runs (`poll_oneoff` fatal / `badmorestackg0` / `unlock
of unlocked lock` / `switchToCrashStack0`) ⇒ a late memory-corruption miscompile (uninit reg/stack-
class), D-330/D-283 class — NOT entry-sig or WASI-host (poll_oneoff is wired, same impl as interp).
The `--jit` lane (report-only) now shows go_* run-and-corrupt (huge crash-dump) vs prior compile-skip.

**Phase-B status**: D-283 `--jit` lane 3-host green (REPORT-ONLY). Remaining JIT-correctness debt, all
HARD multi-cycle codegen miscompiles → **active bundle = D-330** (`%s`, see top). Sibling: **D-331(A)-
next** go_* runtime-corruption (non-deterministic; likely same regalloc/spill-class as D-330, may share
the fix) + **D-331(B)** go_regex SlotOverflow (= D-289 large-frame, lowest priority). (A1 Zig + A2
embenchen + A3 wasmer-oracle + runtime-bump + tool-currency-3host + B1 jit-diff-lane DONE; D-331 primary
`10d7d2b2` + (A) `45ff0b94` FIXED.)

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
