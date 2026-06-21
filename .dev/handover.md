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

- **Bundle-ID**: D-489-x86_64-miscompile-campaign (user-directed 2026-06-21, anti-先回しロック)
- **Cycles-remaining**: ~3
- **Continuity-memo**: STEPS 2-3 DONE. Controllable repro `private/spikes/d489-minimal-repro/`
  (min.wasm json = floor; main.go source there). iovec diff: x86_64-jit `data` slice from
  `json.Marshal` has len=0. Hypotheses RULED OUT: pure-fmt-codegen (literal printf fine),
  multi-value-return-capture (mv2.go clean `([]byte,int)`+pressure FINE; captureCallResult
  op_call.zig:1006 inspected = correct R10-staged read-back). Bug needs json/REFLECT-specific
  pressure → likely a COUNT/LENGTH computed→0 under x86_64 spill in reflect field-iter / encoder.
  Minimal-repro track EXHAUSTED.
- **Next step (STEP 4)**: GUEST-VALUE differential trace to pinpoint the miscompiled instruction.
  UNLOCK: min.wasm has a NAME SECTION (266 named funcs) + full DWARF — the json encoder funcs are
  named (`(*encoding/json.encodeState).reflectValue/.marshal`, etc.). Plan: map those names→wasm idx
  (wasm-tools print), add func-boundary entry/exit value trace keyed by idx (interp trivial; JIT =
  debug-gated trace call in prologue/epilogue emit, 2 sites) OR enhance jit.dump to print names +
  disassemble the specific encoder fn arm64-vs-x86_64. Find the fn whose return/count diverges. Repro:
  `zig build -Dtarget=x86_64-macos && ./zig-out/bin/zwasm run --engine jit private/spikes/d489-minimal-repro/min.wasm`
  (x86_64-jit: `json: ` empty + roundtrip FAIL; interp correct).
- **Exit-condition**: miscompiled instruction/value identified + fixed (interp==jit on min.wasm +
  tinygo_json x86_64) OR proven root-cause class with a targeted fixture. Unblocks `.auto`→JIT flip.

## RESUME POINTER (2026-06-21) — D-489 ACTIVE CAMPAIGN (flip blocker); D-491 CLOSED; D-492/493 filed

**ADR-0200 JIT embedding API delivered + explicit `.jit` SOLID** (cljw actively dogfooding, 4 reported bugs fixed):
dual-engine accessors @3d701ddaf, exportFuncSig @5b6449779, export_types-on-JIT @f68532e44, FP/mixed 1-2arg invoke
@d7da97e04/@3cf40a573. The **jit-export-invoke-dispatch-matrix bundle is CLOSED** (pivot): 1/2-arg invoke matrix
COMPLETE (veneer→buffer-path fall-through); 3-arg+ ride the generic buffer-write path (`invokeViaBufferSingle` →
`wrapper_thunk.emit`, ADR-0106). cljw all-consumed (to_cljw_05; default `.interp`, agreed).

**`.auto`→JIT flip = blocked on D-489, now an ACTIVE CAMPAIGN** (see `## Active bundle` above — user-directed
2026-06-21, NOT a 妥協/defer). Twice-reverted (last @7dbdb973c; origin green). The flip is a FORCING FUNCTION that
exposed the D-489 x86_64 spill-pressure miscompile Mac-arm64 masks. Ruled out this session: emitMemOp-isolated
(@d856f89ef, 2 bounded fixtures clean), arm64-pressure-repro (@5f1f08db1, ADR-0077 blocks pool-shrink → x86_64-only),
Zig-optimizer-mode (Debug+ReleaseFast both repro → deterministic). NOW localized to printf#2 (see bundle). D-490 was a
SEPARATE bug (FIXED @eddd74941). Other flip prereqs (post-D-489): **(b)** pin interp-conformance runners
(`wast_runtime_runner`) to `.interp`; **(c)** wide-shape `wrapper_thunk.emit` (D-477). **cljw NOT blocked** (explicit
`.jit` works). Adjacent sweep this session: D-491 CLOSED, D-492/D-493 filed (v128-in-GC-type niche gaps).

**D-491 CLOSED @56fcc53cd**: typed `select (result v128)` (0x1c/0x7B) now validates (validator.zig:3046) + lowers
(lower.zig:355) + JIT-executes on both arches (codegen already dispatched v128 via value shape-tag). Interp traps
(SIMD-JIT-only, by design). Fixture `test/edge_cases/p17/select_typed_v128` (=111). test-spec-simd 25075/0 +
wasm-2.0-assert 25539/0 both arm64 + x86_64-macos.

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

**Step-0.7 NOTE**: `failed command: test…--listen=-` is COSMETIC (exits 0); trust `[run_remote_*] OK/FAIL` + `N
passed, 0 failed`, not that line.

**PARKED / gated (do NOT speculatively grind)**: D-305 long-tail (niche, + `component_graph.zig` 1895/2000
file-split first); D-464 async; 21 `blocked-by`. **validator.zig at 3449/3450 cap — NEXT validator edit MUST
extract per the file's marker plan.** Closed-arc detail (D-305/ADR-0192/async/WASI-0.3) is in git/ADRs/debt.

## Long-tail (debt-tracked / parked — NOT active; see debt.yaml)

- **JIT-correctness** (front B): D-331(B) CLOSED · D-330 c_sha256 PROVABLY-BLOCKED · D-331(A) go runtime-corruption
  DRIVABLE · D-333 folds into D-330 (all in debt.yaml; D-489 may share the go/x86_64 spill root). D-454 GC-program
  fixture future-bucket. Trace tooling: `ZWASM_DEBUG=jit.dump` + `scripts/jit_value_trace.sh` (Recipe 18).

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
