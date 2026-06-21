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

## JIT-asyncify/coroutine campaign — PAUSED for breadth (debt-tracked D-489 + D-494)

Exhaustively investigated this session (built jit.callcount/jit.calledge profilers + trap-dump; 2 bugs localized):
- **D-489** (x86_64-only silent-wrong-value): run$1 wasm 1539-1551 nested-select/rewind-br_if region; static exhausted.
- **D-494** (`now`; both-arch defer/recover JIT deadlock/silent): localized to the asyncify global-state-machine
  (globals 0=__stack_pointer / 1=state / 2=data-ptr; unwind/rewind logic in main.safe-class fns). arm64-reproducible.
- Likely SHARED ROOT (asyncify unwind/global-state codegen). Full detail: debt D-489/D-494 + lessons.
- **GLOBALS RULED OUT @a1c589c58**: built interp+JIT `ZWASM_DEBUG=global.trace`. The asyncify state machine = g1 0→1→0
  (fn 205 start_unwind: g1=1,g2=89996; fn 206: g1=0). The JIT drives g1/g2 IDENTICALLY to interp (g1 last=0 sets=2,
  g2=89996 sets=1) yet STILL deadlocks → the asyncify global state machine is CORRECT under JIT. So the bug is AFTER
  the globals: the asyncify **SHADOW-STACK MEMORY** save/restore (g2-indexed `load[/offset=4]; … i32.store` local-spill
  on unwind + rewind-restore at fn entry). **NEXT = trace the g2-indexed shadow-stack memory writes (the local-save
  loop) interp-vs-jit on dfr2**, OR dump the saved locals at the yield. Reusable: callcount/calledge/global.trace primitives.

**WINDOWS GATE (D-495 batch @c3c4e8447) — ENV FLAKE, not a code regression** (2026-06-21): build summary 5736/6030
passed; ALL suites green on Win64 (wasm-3.0-assert 86/0, memory64/gc/multi-memory, realworld 56 PASS, component 170/0,
wasi 3/0). The 1 failed step = a host-embedding EXAMPLE (`zwasm-zig-host-hello.exe` + rust `main.rs`) panicking
`failed to create file: NotFound (code 44 = missing parent dir)` — a Windows path/harness issue, NOT my GC-array changes
(those are exercised by the green GC asserts). NOT reverted; tracked (windows-host-example-filecreate). Re-verify next windows gate.

## RESUME POINTER (2026-06-21) — STANDING CORRECTNESS SWEEP; D-491/492(abstract)/493 CLOSED; D-495 v128-array-fill host-PANIC GUARDED; D-489/494(asyncify) paused, D-492(typed-ref)/D-495(proper v128-fill) open

**v128-GC class swept this session**: select-v128 (D-491), select-GC-reftype (D-492), array.new_data-v128 (D-493) all
FIXED. struct.new v128-field + array.get-v128 (D-460) already worked. array.fill/new with a v128 VALUE crash-GUARDED
(D-495 — was a guest-triggerable host panic; proper pointer-marshal impl deferred). No more v128-GC host panics.

**JIT-execution sweep (interp-vs-jit diff over all 56 realworld fixtures)**: arm64 = **ZERO divergences** (corpus
JIT-correct on arm64; D-494's defer-deadlock pattern isn't in the corpus). x86_64 sweep RUNNING (will catalog
x86_64-only gaps — expect tinygo_json=D-489; file any NEW ones as debt). NEXT = read /tmp/x86sweep.log, file new gaps.

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
