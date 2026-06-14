# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## ACTIVE AGENDA (user-directed 2026-06-14) — real-world toolchain/bench reproduction

**Just closed**: **D-238 (x86_64 cross-instance EH on JIT parity) CLOSED** `c534afca`
(ADR-0185 Implemented; functional proof = `ZWASM_SPEC_ENGINE=jit` x86_64
exception-handling `34/0/0`; 3-host test-all green). **cljw guest-wasm RETIRED**
`02ef14b0` (user decision — cw won't emit wasm; cljw tests zwasm consumer-side).
Project is feature-complete + 3-host green + tag-ready (**tag = USER-ONLY, ADR-0156**).

**The agenda — drive via `/continue`. Authoritative plan (ordering + 2026 language
scope + the live JIT-trap inventory):**
[`realworld_reproduction_plan.md`](realworld_reproduction_plan.md) — its work sequence
supersedes ROADMAP §9 for these tasks. **User ordering: Phase A QUICK → Phase B
SUSTAINED**; the user assists when a toolchain needs installing.

- **Phase A — reproduction infra (QUICK; get it working)**:
  - **A1 (Zig half DONE `5c044967`)**: `zig_{hello,fib,prime_sieve}` wasm32-wasi added;
    interp 53/53, byte-diff 53/53 vs wasmtime, JIT-clean (+ fixed a diff_runner green-path
    flush bug `6995bbd3`). **AssemblyScript + WasmGC (Kotlin/Wasm/Dart) → D-329** (need
    `asc`/SDK provisioning + a call-export harness; AS dropped WASI).
  - **A2 (autonomous, NEXT)**: **embenchen** (emcc in `.#gen`) — the classic Emscripten
    bench; the find = the emscripten env-stub host-import gap (D-026/D-082).
  - **A3 (DONE `897b54d7`)**: **3-way differential** — opt-in `--wasmer` second-oracle
    lane (`zig build test-realworld-diff-wasmer`) vs wasmtime; REF-DISAGREE flags the
    divergence a single-reference gate misses. argv[0] CLI convention normalized.
    **Runtimes bumped to latest `074a885f`** (wasmtime 43→**45.0.0**, wasmer 5.0.4→**7.1.0**
    via nixpkgs 06-10): re-validated — zwasm == wasmtime45 == wasmer7.1 on 53/53, **0
    divergence** across a 2-major bump (lesson `reference-runtime-bump-divergence-capture`).
  - **A4 (user-assisted)**: remote provisioning — **D-254** (native rust on ubuntu +
    windows → 3-host rust differential; user chose (a)) + **D-249** (hyperfine on win).
- **Phase B — deep JIT bug-hunt (SUSTAINED; settle in)**:
  - **B1 = D-283**: triage + fix the live JIT signal (run `ZWASM_JIT_RUN=1` corpus:
    interp 55/55 but **JIT 35 pass / 11 trap / 9 compile-gap**). cljw-excluded set:
    **6 RUN-TRAP** (`tinygo_{fib,hello,json,sort}`, `rust_file_io`, `c_sha256_hash` —
    interp-passes ⇒ JIT miscompile / WASI-gap) + **9 COMPILE-OP** (ALL `go_*` —
    `UnsupportedOp` ⇒ unimplemented JIT op). Root-cause each cluster, fix, add boundary
    fixtures, enable `ZWASM_JIT_RUN=1` by default for the runnable set. Multi-cycle.

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

**D-331 PRIMARY GAP FIXED `10d7d2b2`.** Root cause: the JIT liveness pass used a FIXED `[256]Frame`
control-nesting stack; fat standard-Go funcs (go_hello func[303]: 11151 instrs, >256 nested blocks)
overflowed it → UnsupportedOp. Made `block_stack` allocator-backed + doubling. Result: realworld JIT
compile-pass **47/56 → 55/56** (8 of 9 go_* flip compile-op→compile-pass); zig build test green, no
regression; boundary fixture deep_control_nest_300. D-331 now `partial` — 2 SEPARATE smaller remaining
gaps: (A) 8 go_* **UnsupportedEntrySignature** (they compile, but JIT run-path can't invoke Go's `_start`
ABI); (B) **go_regex SlotOverflow** (a different fixed vreg/slot cap — same dynamic-vs-fixed pattern,
likely a similar fix).

**Phase-B status**: D-283 `--jit` lane done + 3-host green (45/2/9, REPORT-ONLY). Remaining JIT-correctness
debt: **D-330** (2 `%s` regalloc-class miscompiles) + **D-331** partial (go entry-sig + go_regex slot cap).

**First action on resume**: continue D-331 — **(B) go_regex SlotOverflow** is the more tractable (same
fixed-cap→dynamic pattern just landed for the control stack; grep `SlotOverflow` in regalloc/emit, find
the fixed vreg/slot table, make it grow). OR (A) the go `_start` UnsupportedEntrySignature in the JIT
entry runner (`runVoidExportWasi`/`runWasiLenient` entry resolution). (Alt: D-330 %s disasm.)
(A1 Zig + A2 embenchen + A3 wasmer-oracle +
runtime-bump + tool-currency-3host + B1 jit-diff-lane DONE; D-331 primary FIXED; B2→D-330.)

## State (tag-ready baseline, all 3-host green)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM**
  default-ON (ADR-0182/0183; corpus 158/0/0). Sandboxing triad everywhere.
- **Surfaces**: C-API 293/293 (+preopen_dir/inherit_env, ADR-0184) · Zig-API
  complete (+`WasiConfig.{envs,preopens,io}` — full WASI parity) · lean CLI ·
  memory-safety sound · dogfooded into cw (consumer-side). Runners ReleaseSafe (ADR-0177,
  Rev 2026-06-14 floored `core_comp` too; `check_releasesafe_runners.sh` guards it).
- **EH**: cross-instance exception-handling on JIT works on BOTH arches (arm64 `4f73d9ee`
  + x86_64 D-238/ADR-0185 `c534afca`). Interp + JIT EH spec corpus green.
- **Debt**: 43 entries, **zero `now`**; all blocked-by are external (upstream
  Zig / hosts) / future-phase (11/12/14) / user-gated, or `note`/`partial` long-tail.
  D-283 (realworld-under-JIT) is the Phase-B anchor. D-026/D-082 (embenchen) feed Phase A.
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
