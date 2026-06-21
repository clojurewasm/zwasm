# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17 完成形 completion-refinement (release = USER-ONLY, ADR-0156)

Project at the **完成形 plateau** (all dims confirmed): clean (C/Zig/CLI audits), full-featured (WASI complete +
now cross-component STRING composition, D-305 milestone), 100% spec (`test-spec` 25539/0), lightweight-yet-fast
(v1-JIT parity, D-265 closed). Robustness: interp+JIT fuzz 0 crashes. Closed-arc detail lives in git/ADRs/lessons.

**Closed arcs (detail in git/ADRs/debt — do NOT re-walk)**: D-305 cross-component linker (string/list/record
marshalling both directions, ADR-0196, comp-assert 170/0); ADR-0195 guest↔guest async FUNCTIONALLY COMPLETE +
D-463 handle isolation (ADR-0197); D-034 SIMD spill-completeness CLOSED @411dd1e14; wasi:random, D-335 typed
marshalling, C-API Windows-export. Residual long-tails (debt-tracked, do NOT grind): D-464 async adversarial,
D-305 niche shapes. Version `2.0.0-alpha.3`. Low-pri follow-up: consolidate duplicated SIMD spill helpers.

## Active bundle

- **Bundle-ID**: D-478-host-func-jit-bridge
- **Cycles-remaining**: ~3 (0-arg bridge → N-scalar-arg spill → FP/Win64 + `.auto`→JIT flip)
- **Continuity-memo**: D-478 (1b) non-WASI host-func dispatch under JIT (unblocks `.auto`→JIT). FULL design
  `private/notes/d478-host-func-jit-bridge-design.md` — read it first. Multi-part: (0) thread `builder_state`
  into `instantiateJit` (`src/api/instance.zig:656` — doesn't receive it today) + resolve host-func payloads;
  per-import emitted bridge stub into `dispatch[]` (extend `func_import_targets`, `setup.zig:394`/`runner.zig:904`)
  + generic Zig marshaller; relax `runner.assertWasiImportsSatisfied` (runner.zig:513, reject instance.zig:678).
  CRUX: JIT passes guest args in NATIVE arg regs per callee C sig → **0-ARG FIRST** (stub embeds payload ptr →
  `genericHostBridge0(rt,payload)`); then signature-agnostic arg-spill stub. Per-arch (mirror `shared/thunk.zig`
  emitThunk); VERIFY each codegen increment arm64 + `-Dtarget=x86_64-macos` + windows gate.
- **Exit-condition**: a JIT-backed instance calls an embedder host-func import (C `wasm_func_new` /
  facade) — first 0-arg→i32, then ≤4 scalar args — asserted green via `wasm_func_call` (mirror
  `test/c_api_conformance/callback.c` with `.jit`), 3-host. Uncovered sigs stay `.interp` (no silent wrong).

## RESUME POINTER (2026-06-21) — for a fresh session

**ADR-0200 JIT-backed embedding API — COMPUTE PATH DELIVERED, bundle CLOSED @<this-commit>.** Both
surfaces (Zig `Module.instantiate(.{.engine=.jit})` + C `zwasm_instance_new_ex`) instantiate + call
JIT exports: scalar/FP/ref multi-arg + multi-result invoke, SIMD-body execution, fuel/memory/table/
interrupt sandboxing, exports discovery, D-451 import-reject. Mini-consumers
`examples/{c_host,zig_host}/jit_engine.*` (gated: `test-c-api-conformance` + `run-zig-host-jit` in
test-all) run engine=jit + multi-arg `add`→5 + SIMD-body `lane0`→42. Engine knob documented
(`docs/zig_api_design.md` §3.10 + `include/zwasm.h` ZWASM_ENGINE_*). **cljw readiness signal SENT**
(`private/dogfooding_handover/to_cljw_02.md` — engine shape + arity/type matrix + contract deltas + pin
`zwasm@025b1f2cb`); cljw obligation DISCHARGED. ADR-0200 ACCEPTED+delivered; commit-chain in git.

**NEXT FRONT = D-478 (ADR-0200 completeness tail)** — use `.interp` for not-yet-covered modules
(documented in to_cljw_02). **WASI host-fn dispatch under JIT DONE @b29606b17** (`jit.owned.rt.wasi_host
= store.wasi_host` + preopens in `instantiateJit`; `jit_wasi` conformance: clock_time_get→i64.load
nonzero, gated). Remaining: (1b) non-WASI host-func dispatch under JIT — SURVEYED (design
`private/notes/d478-host-func-jit-bridge-design.md`): JIT passes guest CALL args in NATIVE arg regs
per the callee's exact C sig (no uniform buffer) → host bridge must be SIGNATURE-SPECIALIZED (comptime
fn-table ≤4-scalar-arg×scalar-result, reg→Val[]→callback→trap_flag; plant via `func_import_targets` +
relax `assertWasiImportsSatisfied`). Multi-cycle codegen bundle = OPEN it when a consumer needs JIT
host-imports OR to unblock `.auto`→JIT; current safe state = host-func imports reject at JIT instantiate
→ `.interp` (no silent wrong answer). + proc_exit exit-code (jit_dispatch.zig:313). (2) `.auto`→JIT flip
once (1b) lands. (3)
WASI via the Linker (holds OWN wasi_host, linker.zig:95 — facade `Module.instantiate` + store.wasi_host
path works now; Linker path is separate). (4) accessor READS memory/global/table JIT arms (return null
today). (5) v128-at-boundary + Win64 ≥4-param stack-spill = D-477 niche slivers. Likely bundle the
host-import/Linker work if it proves multi-cycle. **OR** fall back to the STANDING CORRECTNESS-SWEEP
directive (below).

**STANDING DIRECTIVE = CORRECTNESS SWEEP** (user 2026-06-20, memory `feedback_correctness_sweep_phase`): high-value
bar OFF. Sweep toward 0% the 3 gap classes — (1) wasmtime-works-zwasm-doesn't, (2) wasm/wasi spec non-conformance,
(3) instability/crashes — easiest-first, TDD + 3-host, repeat; don't ask "is this high-value." Status: spec
skip-impl=0, realworld JIT 56/56 GATING (`test-realworld-diff-jit`), no UnsupportedOp crash, fuzz 0-crash.
ADR-0200 (JIT embedding API) + D-477 (JIT host-invoke) were the live fronts — both delivered/closed; the
ADR-0200 tail = D-478. Prior sweep closures (D-468/D-469/D-470/D-475/D-476/extended-const/GC trap-kind/
memory64+SIMD/fuzz exec-differential) are in git/lessons — do NOT re-walk.
**VERIFICATION LESSON (operationally live)**: a JIT-codegen fix MUST be checked with `test-spec-wasm-2.0-assert`
on BOTH arm64 AND `-Dtarget=x86_64-macos` — NOT `test-spec`(interp)/`zig build test`(unit).
**D-475 table64 slice 4 (JIT table64 codegen) PARKED** (structural u32→u64 descriptor widening, Win64-risk; bounded
4-cycle bundle in debt row, PERF not correctness). Self-contained table64 interp-conformance DONE.

**Phase 17 完成形 plateau** (validated — do NOT re-walk): async COMPLETE; v128 spill (D-034/D-460/D-461) CLOSED;
surface audits clean 2026-06-18; fuzz 0-crash; realworld JIT run 56/56 byte-match wasmtime (gating). NOT-WORTH: D-294-R2 TrapKind.

**Recently CLOSED (detail in debt/git/lessons)**: const-expr evaluators extracted to instantiate_const_expr.zig
@d9dbe7234 (marker's planned move; instantiate.zig 2014→1626, marker removed); D-467 simd invoke-boundary skips;
D-305 cross-component AGGREGATE marshalling (record-with-string both directions, comp-assert 170/0).

**Step-0.7 NOTE**: `failed command: test…--listen=-` is COSMETIC (exits 0); trust `[run_remote_*] OK/FAIL` + `N
passed, 0 failed`, not that line.

**PARKED / gated (do NOT speculatively grind)**: D-305 long-tail (list<record>/variant/multi-param — niche, +
`component_graph.zig` 1895/2000 file-split first); D-464 async; 21 `blocked-by` (upstream/proposal/time-gate/corpus).

## Closed arcs (detail in ADRs/git/debt)

- D-305 STRING milestone (@4cceeb1e, ADR-0196) · doc-inventory fresh (`42441634`) · ADR-0192 wasmtime differential
  (9+6 engine bugs fixed; residual D-209/D-456 parked) · 4-front async-maturity (wasmtime async .wast, wasip3, perf
  ROI-rejected D-450, GC corpus 6 bugs) · WASI 0.3 core DONE (D-335, ADR-0187-0191). **validator.zig at 3449/3450
  cap — NEXT validator edit MUST extract per the file's marker plan.**

## Long-tail (debt-tracked / parked — NOT active; see debt.yaml)

- **JIT-correctness** (front B): D-331(B) CLOSED @adb7b99a · D-330 c_sha256 PROVABLY-BLOCKED (bucket-2) ·
  D-331(A) go runtime-corruption (DRIVABLE; build mem-divergence diff first) · D-333 (folds into D-330). Corpus
  interp-green; run-stage opt-in. Trace: `ZWASM_DEBUG=jit.dump` + `scripts/jit_value_trace.sh` (Recipe 18).
- **D-454** (future-bucket): real GC-language program execution fixture, blocked on Hoot reflect-ABI host port.

## State (all 3-host green @046d9c67/win @886d0667; release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip (GC 362/0). **WASI 0.1** complete; **0.2/CM** default-ON (corpus 158/0/0);
  **0.3 core** done. Sandboxing triad everywhere.
- **Surfaces**: C-API 293/293 · Zig-API complete (full WASI parity) · lean CLI · memory-safety sound · dogfooded into
  cw. Runners ReleaseSafe (ADR-0177; `check_releasesafe_runners.sh`).
- **EH**: cross-instance JIT EH on BOTH arches (arm64 `4f73d9ee` + x86_64 `c534afca`). Interp + JIT EH corpus green.
- **Debt**: 62 entries; **ZERO `now`-class** (D-034 spill arc CLOSED @411dd1e14 → `note`; D-460 v128-GC + D-461 +
  D-293 + D-294 all `note`). Remaining partials: D-305 (consumer-gated CM shapes), D-331(A)/D-330 (go_* JIT; B closed).
  Rest front-tagged (future-bucket/parked); D-462 feature-separation = user-gated. **完成形 plateau.**
- **Realworld corpus**: 56 fixtures (c/cpp/emcc/go/tinygo/rust/zig), interp 56/0; JIT run-stage opt-in.
- **Tag**: `v2.0.0-alpha.3` tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3` — fixture toolchains. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0187-0191** (CM-async) · **0185** (x86_64 EH) ·
  **0099** (file-size caps) · **0126** (iso-recursive canonical equality).
- lessons INDEX: `.dev/lessons/INDEX.md` (keyword index for Step 0.4).
