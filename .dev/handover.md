# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17 完成形 completion-refinement (release = USER-ONLY, ADR-0156)

Project at the **完成形 plateau** (all dims confirmed): clean (C/Zig/CLI audits), full-featured (WASI complete +
now cross-component STRING composition, D-305 milestone), 100% spec (`test-spec` 25539/0), lightweight-yet-fast
(v1-JIT parity, D-265 closed). Robustness: interp+JIT fuzz 0 crashes. Closed-arc detail lives in git/ADRs/lessons.

**D-305 cross-component linker — COMMON shapes ALL DONE + 3-host/x86_64-verified** (ADR-0196; detail in the
D-305 debt row + git): string/list params (@689040e6), string result (@184b5e05), `(string)->string` (@2b9b14ee),
boundary error-trap (@30bd1881, SECURITY — marshalling failures now TRAP, not silent-wrong). component_model
163/0; ubuntu OK @dfdcfdcf. Remaining rare shapes (record/result aggregates, >2-param arities) = consumer-gated
debt, do NOT grind speculatively.

**ADR-0195 guest↔guest async (multi-task scheduler) — FUNCTIONALLY COMPLETE 2026-06-17** (the D-335 last
functional gap; campaign closed-arc below). Cross-component async now works end-to-end: multi-task scheduler
(`driveScheduler`) → cross-component ROUTING (c-2b) → `task.return` capture + result round-trip (d-a/d-b-1) →
future rendezvous (d-b-2) → synchronous + BLOCKING multi-element stream rendezvous + pollSet/waitable-set delivery
+ AsyncDeadlock guard (d-c-1/d-c-2, @a82b4f84). Local gate green (test-all unit + comp-spec 163/0 + lint +
fallback). **D-463 cross-component async handle isolation CLOSED 2026-06-18 (@633189454, ADR-0197 ownership
ledger)**: a child can no longer reach a peer's un-granted stream/future end (adversarial isolation fixture
RED→GREEN). **Residual (debt-tracked, NOT blocking, do NOT grind): D-464** (broader (e) adversarial dropped/
cancelled cross-component cases + cancel-op/waitable wait-poll-drop graph builtins).

**Prior arcs**: wasi:random COMPLETE; ADR-0193 feature-separation + version SSOT; D-335 typed marshalling DONE;
C-API @b4d75506 (Windows export fix); interp+JIT fuzz 808 mods 0 crashes. ADR-0193 (D-462) + D-461 (ADR-0194)
CLOSED (below). **windowsmini RESUMED**. Version `2.0.0-alpha.3`.

**D-034 SIMD spill-completeness arc — CLOSED 2026-06-19 @411dd1e14 (bundle exit-condition met).** All scalar
sub-categories (a–g) + the full 18-site x86_64 v128-operand (g) sub-arc are spill-aware on both arches; the only
remaining bare-resolve sites are the structural emitV128Select val2 (3-V-reg-vs-2-stage) + emitI64x2Mul's
byte-identical all-reg fast path. Detail + per-op SHAs in the D-034 debt row (now `note`) + git. Low-pri follow-up:
consolidate the duplicated spill helpers into a shared op_simd.zig pub set.

## Active bundle

- **Bundle-ID**: D-331A-memdiff (correctness — fix the go-runtime miscompile)
- **Cycles-remaining**: ~3 (localized to a CONTROL-FLOW divergence in the allocator/systemstack path; now pin the bad codegen + fix)
- **Continuity-memo**: diagnostic mem.cksum committed @27244fe86, but **CORRECTED 2026-06-19 (subagent adc5667a,
  full detail → `private/notes/d331a-memdiff-plan.md`)**: per-host-call MEMORY hashing was a RED HERRING — the
  "2nd clock_time_get divergence" is non-deterministic CLOCK nanosecond reads (interp-A≠interp-B), not corruption.
  The PRODUCTIVE signal = a per-guest-CALL **func-idx sequence** diff: **the bug is CONTROL-FLOW**. Interp calls
  `runtime.recordspan`(470) ZERO times → clean exit; JIT calls it 35× stuck in an infinite `fixalloc.alloc`(314)↔
  recordspan(470) loop → panic. Gate in fixalloc.alloc loads `f.first` (`i64.load offset=8`): interp reads 0 (skip),
  JIT reads NON-ZERO (call→loop); first structural divergence after `call 1270`(systemstack) → spurious `call 246`.
  **HYPOTHESIS**: a JIT miscompile in the Go allocator/systemstack path clobbers the SP/g globals (`global.set 0/1`)
  OR an `i64.load/store` offset/width, so a pointer field that should be nil reads garbage. **NEXT (surgical)**:
  probe the VALUE of `i64.load offset=8`(f.first) + base `offset=56` at the FIRST call to func 314 on both engines
  → struct-BASE (SP/g) vs FIELD content; gate any prologue probe behind a comptime flag or func-idx==314 ONLY (the
  subagent's unconditional prologue probe broke byte tests — reverted).
- **Exit-condition**: the JIT miscompile making `fixalloc.alloc`'s `f.first` read non-zero (allocator/systemstack
  path — SP/g global or i64.load/store offset) is identified + fixed (go_hello JIT stops looping), OR the
  exact bad instruction is named in D-331 with a minimal repro if the fix needs its own bundle.

## RESUME POINTER (2026-06-19) — for a fresh session

0. **完成形 plateau** (2026-06-19, exhaustively validated — do NOT re-walk): ADR-0195 async campaign COMPLETE;
   v128 spill story (D-034/D-460/D-461) CLOSED; surface audits (C/Zig/CLI) clean; fuzz 0-crash; realworld JIT
   compile 56/56. NOT-WORTH-DOING (do NOT re-litigate): D-294-R2 TrapKind nicety; v128-spill helper-consolidation.
   **CLOSED 2026-06-19** (detail in git/debt/lessons): **D-331(B)** go_regex arm64 large-frame spill-offset
   @adb7b99a (diff-jit MATCHES wasmtime); **D-305 3+4-param arity** @db79e7df/@6e791d8c (BoundarySig3/4; comp-assert
   165/0); **D-466** failed-instantiateGraph double-free @99a33f9f (errdefers outliving append; regression test);
   **D-323 windows sockets** @3d8314df (the stdlib's windows real-TCP-connect crashed + aborted the Win64 unit binary;
   skipped on windows). **Step-0.7 NOTE**: `failed command: test…--listen=-` is COSMETIC (exits 0) — lesson
   `2026-06-19-zig-build-test-listen-failed-command-is-cosmetic`; trust `[run_remote_*] OK/FAIL` + `N passed, 0
   failed`, not that line.
   **NON-BLOCKED QUEUE (逐次, user 2026-06-19)** — work IN ORDER; each is drivable now (no external block); after
   each, re-survey debt for newly-drivable items before stopping:
   1. **D-331(A)** = the ACTIVE BUNDLE above (memdiff diagnostic → localize → fix the go-runtime poll_oneoff miscompile).
   2. **D-467 (now)** — UNSKIP the 271 simd `skip-impl` (NOT a harness excuse — exercises the v128 call-boundary
      ABI, may expose latent bugs, user). Extend `entry.zig` v128 arg/result marshal + simd-runner invoke value
      parse for load/store-lane (v128-param + i32 addr → v128) + f32→v128 splat; flip manifests skip-impl→live;
      run interp+jit. directive-register residue documented if a genuine wast-directive limit.
   3. **D-305** — STOP per-arity churn at 4; do the GENERIC `defineFuncRaw` (Value-slice host fn) refactor →
      collapses 5..7 arities + record/result aggregate marshalling (canon.store/load, built) in ONE path
      (record fixtures need NOMINAL types; a wasm-tools validate snag remains).
   PARKED (do NOT drive): **D-330** c_sha256 `\n` PROVABLY-BLOCKED (bucket-2; 1-byte cosmetic, constraint conflict);
   the 21 `blocked-by` (upstream Zig D-010/148/312/323 · proposal D-300/336 · phase/time-gate · consumer/corpus); D-464 async.
2. **Audit DONE 2026-06-18 CLEAN** (0 block/0 soon; fuzz 0 crashes). **v128 spill story COMPLETE** (D-460/D-461/D-034
   all `note`).

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
