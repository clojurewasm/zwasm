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
    flush bug `6995bbd3`). **AssemblyScript + WasmGC (Kotlin/Wasm/Dart) → D-324** (need
    `asc`/SDK provisioning + a call-export harness; AS dropped WASI).
  - **A2 (autonomous)**: **embenchen** (emcc in `.#gen`) — the classic Emscripten bench;
    the find = the emscripten env-stub host-import gap (D-026/D-082).
  - **A3 (autonomous)**: **3-way differential** — zwasm vs wasmtime vs wasmer (both on
    PATH) + hyperfine perf, over the corpus.
  - **A4 (user-assisted)**: remote provisioning — **D-254** (native rust on ubuntu +
    windows → 3-host rust differential; user chose (a)) + **D-249** (hyperfine on win).
- **Phase B — deep JIT bug-hunt (SUSTAINED; settle in)**:
  - **B1 = D-283**: triage + fix the live JIT signal (run `ZWASM_JIT_RUN=1` corpus:
    interp 55/55 but **JIT 35 pass / 11 trap / 9 compile-gap**). cljw-excluded set:
    **6 RUN-TRAP** (`tinygo_{fib,hello,json,sort}`, `rust_file_io`, `c_sha256_hash` —
    interp-passes ⇒ JIT miscompile / WASI-gap) + **9 COMPILE-OP** (ALL `go_*` —
    `UnsupportedOp` ⇒ unimplemented JIT op). Root-cause each cluster, fix, add boundary
    fixtures, enable `ZWASM_JIT_RUN=1` by default for the runnable set. Multi-cycle.

**First action on resume**: Phase A3 — wire the **3-way differential** (zwasm vs wasmtime
vs **wasmer**) over the corpus: confirm wasmer is on PATH (`.#gen` / bench shell), extend
`diff_runner` (or a sibling) to byte-compare a second reference + add hyperfine perf.
Then A2 (embenchen via emcc, D-026/D-082). (No active bundle/campaign; this agenda drives.)

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
