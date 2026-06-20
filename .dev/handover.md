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

## RESUME POINTER (2026-06-20) — for a fresh session

**ACTIVE DIRECTIVE = CORRECTNESS SWEEP** (user 2026-06-20, memory `feedback_correctness_sweep_phase`): the
high-value bar is OFF. Sweep toward 0% the 3 gap classes — (1) wasmtime-works-zwasm-doesn't, (2) wasm/wasi spec
non-conformance (skips/missing), (3) instability/crashes — from already-known items, EASIEST-first, TDD + 3-host
gate, repeat. Do NOT stop to ask "is this high-value." **This session's sweep CLOSURES (detail in git/lessons/
ADRs — do NOT re-walk)**: D-330+D-331A liveness (@69a0953b1), D-209 memory64 >4GiB offset (@b8cf64123),
**D-468 go_* JIT-exit hang / proc_exit non-termination (@1a629c5fe, ADR-0199 post-call trap_flag check, both
arches)**, fd_seek/fd_tell (@571fb5176), poll_oneoff clock subs (@132cf5527). **MILESTONE: realworld
JIT-vs-wasmtime 56/56, lane flipped REPORT-ONLY→GATING @3b6f8d5b5** (D-283 discharged) — gap-class #1 = 0% for
the corpus + permanent regression gate (`zig build test-realworld-diff-jit`, Mac-host+wasmtime; run after
JIT-codegen changes). **VERIFICATION LESSON**: a JIT-codegen fix MUST be checked with `test-spec-wasm-2.0-assert`
on BOTH arm64 AND `-Dtarget=x86_64-macos` — NOT `test-spec`(interp)/`zig build test`(unit).
**Sweep front — KNOWN gaps EXHAUSTED (2026-06-20)**: the gap-inventory's 3 verified WASI preview1 stubs are
all DONE — fd_seek + fd_tell @571fb5176 (OpenFd gained a logical `pos` cursor; positional IO), poll_oneoff clock
subscriptions @132cf5527 (decode 48B subscription, sleep to earliest deadline, write 1 clock event; fd subs stay
notsup). Sweep status: spec skip-impl=0, debt `now`=0, realworld JIT 56/56 gating, no UnsupportedOp runtime
crash, fuzz 0-crash. **Net BROADENED @13ca72155**: fuzz_loader Path 4 now runs each smith module through the JIT
codegen pipeline (was interp-only) — verified **1840 diverse modules JIT-compiled, 0 crashes** (FUZZ_N=3000
campaign; gap-class #3 net now covers codegen). **Wider inventory DONE**: WASI/C-API/CLI surfaces VERIFIED
complete (no reachable stubs beyond the 3 done); only gap found = **JIT GC trap-kind precision** (the JIT routed
GC traps to the generic bounds bucket, kind 0, where the interp reports the precise kind). **DONE this turn**:
array.len/struct.get_u null-ref → null_reference (@3f267ef14); array.new_data/new_elem segment-oob → oob_memory
(@5ce49c70e); array.init_data/init_elem null vs oob split via an inline null-ref check (@fcbda5d79, D-470 DONE).
**GC trap-kind precision cluster COMPLETE** — all 6 ops, both arches, RED tests, GC spec 678/0; **3-host green
(win OK)**. **D-469 interp-vs-JIT EXECUTION differential fuzzer BUILT @fccbf61ce** (`test/fuzz/fuzz_exec.zig`,
`zig build test-fuzz-exec`): invokes 0-param/single-scalar smith exports under BOTH engines (fuel-bounded),
compares value/trap. Needed a corpus regen (smith exported nothing → `smith_config.json` export-everything).
Campaign: 1626 mods / 122 funcs / **0 mismatch, 0 crash** — interp+JIT agree. REPORT-ONLY (flip to gating later).
**Sweep at the floor + nets broadened**: concrete known gaps = 0 (WASI/C-API/CLI/spec-skip/GC-traps); JIT
codegen-fuzz + exec-fuzz both 0-finding. Remaining: D-456 host-stubs (test-harness), D-336 (blocked sort=value).
NEXT: periodic re-inventory / larger fuzz campaigns, or general 完成形 refinement / debt repayment.

**Phase 17 完成形 plateau** (validated — do NOT re-walk): async COMPLETE; v128 spill (D-034/D-460/D-461) CLOSED;
surface audits clean 2026-06-18; fuzz 0-crash; realworld JIT run 56/56 byte-match wasmtime (gating). NOT-WORTH: D-294-R2 TrapKind.

**Recently CLOSED (detail in debt/git/lessons)**: D-467 simd invoke-boundary skips; D-305 cross-component
AGGREGATE marshalling (record param/result flat + record-with-string both directions, comp-assert 170/0);
D-209 memory64 >4GiB offset @b8cf64123.

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
