# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17 完成形 completion-refinement (release = USER-ONLY, ADR-0156)

Project at the **完成形 plateau** (all dims confirmed): clean (C/Zig/CLI audits), full-featured (WASI complete +
now cross-component STRING composition, D-305 milestone), 100% spec (`test-spec` 25539/0), lightweight-yet-fast
(v1-JIT parity, D-265 closed). Robustness: interp+JIT fuzz 0 crashes. Closed-arc detail lives in git/ADRs/lessons.

**D-305 cross-component linker — COMMON shapes + ARITY-COLLAPSE DONE** (ADR-0196; detail in the D-305 debt
row + git): string/list params (@689040e6), string result (@184b5e05), `(string)->string` (@2b9b14ee), boundary
error-trap (@30bd1881, SECURITY — marshalling failures TRAP). **(a) `defineFuncRaw` @4c8329428** replaced the per-arity
BoundarySig/3/4 with ONE Value-slice path (any flat-scalar arity). **(b) record AGGREGATE DONE**: (b1) flat-record
PARAM pass-through @b3ee9fcf0 + (b2) flat-record RESULT via retptr @3b5a0a4f8 (lift producer returns a storage
ptr, raw-copy blob to A's retptr). comp-assert 168/0. The nominal-type WAT snag was a spelling issue (spike-solved).
Remaining long-tail (consumer-gated, do NOT grind): mixed params+record-result, nested-pointer records, variant
results.

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

## RESUME POINTER (2026-06-20) — for a fresh session

**ACTIVE DIRECTIVE = CORRECTNESS SWEEP** (user 2026-06-20, memory `feedback_correctness_sweep_phase`): the
high-value bar is OFF. Sweep toward 0% the 3 gap classes — (1) wasmtime-works-zwasm-doesn't, (2) wasm/wasi spec
non-conformance (skips/missing), (3) instability/crashes — from already-known items, EASIEST-first, TDD + 3-host
gate, repeat. Do NOT stop to ask "is this high-value." **Inventory DONE** (subagent): spec-skip front already ~0
(only real skip-impl = simd `directive-register` = test-harness residue; #2/#3 validator-rejects already done, stale
comments fixed @94f0b7122). **#9 DONE @97abd6887**: arm64 v128 LOCAL ZERO-INIT large-frame `UnsupportedOp` (>32760
→ frameStrGpr/X16; fixture setup_v128_zeroinit) — the 9 go_* already compiled (stale "fail"). **D-330 + D-331A
root FOUND (the elusive class = ONE bug); fix arm64-correct but REVERTED (x86_64 regression).** See `## Active
bundle` for the full root + the re-land plan. Reverted to keep main green; diff @1c59101ff; lesson
`block-result-merge-vreg-survival`.
**Sweep queue (after re-land)**: D-209 memory64 >4GiB offset (≤1 CHUNK — survey found the codegen ALREADY exists
both arches; only an artificial cap at `lower.zig:1004` gates it; lift it for i64 memories + fixture) → D-336
borrow-export (blocked sort=value) → D-456 host-stubs (test-harness). (#1 simd = test-harness.)

**Phase 17 完成形 plateau** (validated — do NOT re-walk): async COMPLETE; v128 spill (D-034/D-460/D-461) CLOSED;
surface audits clean 2026-06-18; fuzz 0-crash; realworld JIT compile 56/56. NOT-WORTH: D-294-R2 TrapKind.

**COMPLETE this session (detail in debt/git/lessons)**: **D-467** simd invoke-boundary skips (271→1, no latent
v128-ABI bug); **D-305 cross-component AGGREGATE marshalling** — generic `defineFuncRaw` arity-collapse (a) + record
param/result flat (b1/b2) + record-with-string BOTH directions (b3/b4, canon liftFlat/lowerFlat + load/store);
comp-assert 170/0; 3-host green. Lessons `host-fn-two-value-types`, `component-record-retptr-asymmetry`.

**Step-0.7 NOTE**: `failed command: test…--listen=-` is COSMETIC (exits 0); trust `[run_remote_*] OK/FAIL` + `N
passed, 0 failed`, not that line.

**PARKED / gated (do NOT speculatively grind)**: D-305 long-tail (list<record>/variant/multi-param — niche, +
`component_graph.zig` 1895/2000 file-split first); D-464 async; 21 `blocked-by` (upstream/proposal/time-gate/corpus).
(D-331A's old "needs-infrastructure / NICHE" text is SUPERSEDED — root found, fix arm64-correct; see the bundle.)

## Active bundle

- **Bundle-ID**: D-330-D-331A-reland (block-merge-vreg liveness fix, br_table-aware, x86_64-verified)
- **Cycles-remaining**: 1-2
- **Continuity-memo**: ROOT FOUND + arm64 fix works (closes D-330 c_sha256 `\n` + D-331A go-runtime; diff
  @1c59101ff, lesson `block-result-merge-vreg-survival`). It REGRESSED x86_64 `labels.wast switch` (got 25 exp 50) →
  REVERTED. Cause: `liveness.zig captureBlockMergeVregs` is called with ONE `depth` at the br site, but `br_table`
  branches to MANY target depths — so a `block(result)` reached only via a `br_table` arm never captures its merge
  vregs, OR captures the wrong one. RE-LAND: in `compute`'s br_table handling, call `captureBlockMergeVregs` for
  EACH target depth (every case + default). Verify on BOTH arches: arm64 `zig build test-spec` + **x86_64 via
  Rosetta `zig build test-spec -Dtarget=x86_64-macos`** (the lens that catches this) + the labels switch must = 50;
  c_sha256 → 107; go_hello prints; realworld-diff 56/56; full emit byte-tests + spec + edge green; then 3-host.
- **Exit-condition**: c_sha256 107 AND labels.wast switch = 50 on BOTH arm64 AND x86_64 (Rosetta + ubuntu) AND full
  net green → re-discharge D-330 + D-331.

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
