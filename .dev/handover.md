# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17 完成形 completion-refinement (release = USER-ONLY, ADR-0156)

Recent closed arcs (3-host or ubuntu-verified; full detail in git/lessons): **D-457** SIMD systemic close (24805/0) ·
**D-458** core-2.0 corpus completeness + cross-corpus audit · doc-inventory pass · **C-ABI trap-kind drift guard** ·
**D-455** array-alloc dedup · **D-459** Wasm 3.0 §3.3.1 local definite-assignment (restore-at-end NOT intersection) ·
**win-specassert-pass0 (ADR-0174 Phase-1) CLOSED**: windowsmini wasm-3.0-assert pass=0 root-caused to CRLF — the
runner was the lone one not trimming `\r`, so windows-CRLF manifests gave `module_path` ending `\r` →
`error.BadPathName` → all modules silently un-loaded. Fixed @02592aa8 (trim, mirrors 4 other runners) → **windows
now pass=10234 = ubuntu, 0 MODULE-READ-FAIL, VERIFIED**; + @b1606384 gates the runner on fails (closes the
"OK-hides-pass=0" masking; lesson `windows-crlf-manifest-badpathname-hidden-by-nongating-skeleton`). D-458 RESIDUAL
(note): broad regen non-idempotency. Ratchet baseline 24 loose (real 22) — harmless. Stale-doc: ROADMAP §16.7 D-277.

CLI surface audit (@4e5e42fe): code↔`--help` fully consistent. Gate change @b1606384 **VERIFIED GREEN on BOTH hosts**
(windows `[run_remote_windows] OK.` wasm-3.0-assert pass=10234 fail=0 / simd 24805/0 / spec 25539/0; ubuntu OK
@f1a1d503). win-specassert campaign fully closed; the fail-gate is clean.

**NEXT (autonomous)**: `D-462` design (ADR-0193) AWAITS USER review. **Active bundle = `D-461` IV** (SIMD spill):
slice 1 DONE (`97afa4d4`) — arm64 i32x4.extract_lane i32-result spill-aware. **ENABLER discovered**: x86_64 codegen
is locally TDD-able via `zig build test -Dtarget=x86_64-macos` under Rosetta (short unit tests; lesson
`rosetta-x86_64-local-jit-unit-test`) — NO more ubuntu round-trips for the inner loop. **NEXT D-461 step (x86_64
blocker found, deeper than resolveXmm)**: fix the regalloc class-boundary OOB at `regalloc.zig:222` —
`spill_idx = id - max_reg_slots_gpr` uses the GPR boundary to index the **fp** `spill_offsets` (should use the FP
boundary) → OOB/panic on heavy fp spill, crashing x86_64 codegen before resolveXmm. Then: migrate x86_64
`resolveXmm` lane-op sites + remaining arm64 lane-op SPILL-EXEMPT scalar paths (replace_lane etc.). Then `D-209`
memory64. **windowsmini gating RESUMED** (Win64-risk codegen now in flight). Gating was SUSPENDED
(ADR-0174, `518a3b86`) → 2-host. Version → `2.0.0-alpha.3`.

## USER-flagged D-462 — feature-separation finished-form — DESIGN DONE (ADR-0193), implementation USER-GATED

- **Design delivered** (`ADR-0193`, Proposed): classified all ~11 scattered-branch sites (~6 unavoidable: parser
  byte-level / CLI display / diagnostics / interp subtype-arm; ~4 structuralisable). Per-axis grades: Wasm-level B,
  engine B+, GC B, WASI **D+**, component **D**. Target = single ordered `WasiLevel={none,p1,p2,p3}` (drop `both`),
  component gated by `wasi_level≥p2` (remove standalone `-Dcomponent`), P2/P3 reified as Zone-1 `register()` (mirror
  `src/feature/gc/register.zig`). 4-phase migration in the ADR. North-star = `feature-separation-finished-form-
  preference` lesson (directory > file > function-cluster > branch).
- **GATED on user review** of ADR-0193's 2 open questions: (a) alias-vs-hard-remove `-Dcomponent`; (b) is a
  component-model-WITHOUT-WASI build a real target (yes → Option B two-axis; no → Option A single-axis, recommended).
  **Do NOT start the §4 build-flag/enum code before that nod** (user explicitly directed design-before-code).

## Active phase — doc-inventory + freshening (USER-requested 2026-06-16)

- **Goal**: walk ALL zwasm_from_scratch docs (CLAUDE.md, `.dev/`, `.claude/`, README, `docs/`) and reconcile against
  CODE TRUTH — find+fix stale claims (e.g. "100% SIMD spec" was once overstated; conversion ops were missing).
- **Phase I survey DONE** (Explore subagent): main staleness was README version-line anchors. **README FRESHENED**
  (`42441634`): retired `v0.1.0`/Phase-16 anchors (ADR-0181) → 完成形 framing + `v2.0.0-alpha.*` pre-release. VERIFIED
  the coverage claims (Wasm 2.0 `skip-impl==0`, 3.0 all-9-proposals) are ACCURATE vs current test output (the
  survey's "skip-impl 1790" finding was a Phase-9 historical false positive — always re-verify against CURRENT
  state). Other docs clean of the retired-anchor class (only CLAUDE.md:108 uses `v0.1.0` as intentional design-
  priority shorthand — left as-is).
- **Reader-facing count/coverage claims VERIFIED accurate** (vs current runners): C-API **293/293** (gap=0,
  `capi_surface_gap.sh`), component corpus **158/0/0** (README:45 + migration_v1_to_v2.md, ×2), Wasm 2.0
  `skip-impl==0` + 3.0 all-9-proposals. No Phase-16 staleness in zwasm claims (the `cw_v1_consumer_contracts.md`
  "Phase 16" refs are correctly about CW v1's own roadmap, not zwasm). **Reader-facing doc surface = clean.**
- **NEXT (lower-priority remaining)**: `.dev/ROADMAP.md` widget + working-doc count drift (e.g. handover State
  "Debt: 56" is now 61) are internal hygiene, not reader-facing — opportunistic. The high-risk surfaces (README,
  c_api.md, version anchors) are done.

## ADR-0192 wasmtime campaign — substantive work DONE; residuals debt-tracked (paused 2026-06-16)

- **Differential-coverage GOAL MET**: ran wasmtime's `tests/misc_testsuite/` through zwasm; found every gap; **fixed
  9 real engine bugs** the synthetic suite missed — array.copy self-region alias ×interp+JIT (`46c2975e`), array.new
  u32 overflow (`7e527dba`), bottom-reftype decode (`d54b789f`), C-API active-data-drop (`c1f727d4`),
  extern/any.convert in const-expr (`2daaf643`), v128-in-GC-aggregate layout+interp+const-expr (`60c54db5`), + 6 SIMD
  via D-457. Lessons: `native-sweep-instantiate-fail-not-equal-host-import` + 2 more.
- **Residuals (all exotic, debt-tracked, NOT premature-locked — discharge predicates clear)**: **`D-460`** (partial)
  v128-GC: arm64 JIT struct+array get/set EMIT DONE (`f79a3ced`/`41015a9b`, 4 runI32Export tests, arm64-gated via
  skip.blocker) — array.new_fixed/copy + the x86_64 mirror + array-copy-inline.6 are all blocked on **`D-461`** (a
  PRE-EXISTING broad SIMD-spill gap: lane ops can't read a spilled v128 — x86_64 `resolveXmm` rejects `.spill`,
  arm64 lane-op GPR paths SPILL-EXEMPT; staging XMMs xmm14/15 + V29/30 exist, so it's per-op wiring across many SIMD
  ops × 2 arches). **`D-209`** memory64 >4 GiB memarg offset (10.M-4b multi-arch). **Parked = D-456** host-import
  fixtures. Harness: `scripts/wasmtime_misc_{sweep,native_sweep}.sh`. Re-open D-461 as its own bundle if a real
  high-v128-pressure program (not just this fixture) needs it, or to finish v128-GC.

**Closed campaigns (detail in git/lessons)**: prior 4-front async-maturity (2026-06-16) — ② wasmtime async .wast
TIER-1 (`afcf889a`/`05b35c28`; D-446/447 deferred), ① wasip3 conformance (7 real-rust fixtures, `.#gen-wasip3`),
④ perf (ROI-rejected single-pass ceiling, D-450), ③ real-world GC corpus (6 engine bugs FIXED: D-451-453/9064faa5/
480809af/9ec68a75/79742cb4; 4 GC edge fixtures; real Hoot execution → D-454). **WASI 0.3/Preview-3 core DONE**
(D-335; ADR-0187-0191). validator.zig at 3449/3450 cap — NEXT validator edit MUST extract per the file's marker plan.

## Long-tail (debt-tracked / parked — NOT active; see debt.yaml)

- **JIT-correctness** (front B / parked): D-330 c_sha256 `\n` (parked — conflicting-constraint; do NOT re-run the
  blanket fix) · D-331(A) go runtime-corruption (infra-blocked) · D-331(B)/D-289 go_regex emit (parked) · D-333
  (br_table, folds into D-330). Realworld corpus interp-green; JIT run-stage opt-in (`ZWASM_JIT_RUN=1`). Trace:
  `ZWASM_DEBUG=jit.dump` + `scripts/jit_value_trace.sh` (Recipe 18).
- **D-454** (future-bucket): real GC-language program execution fixture, blocked on Hoot reflect-ABI host port.

## State (all 3-host green @046d9c67/win @886d0667; release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip (GC 362/0). **WASI 0.1** complete; **0.2/CM** default-ON (corpus 158/0/0);
  **0.3 core** done. Sandboxing triad everywhere.
- **Surfaces**: C-API 293/293 · Zig-API complete (full WASI parity) · lean CLI · memory-safety sound · dogfooded into
  cw. Runners ReleaseSafe (ADR-0177; `check_releasesafe_runners.sh`).
- **EH**: cross-instance JIT EH on BOTH arches (arm64 `4f73d9ee` + x86_64 `c534afca`). Interp + JIT EH corpus green.
- **Debt**: 61 entries; `now`-class = D-462 (feature-separation, ADR-0193, user-gated), D-460 (v128-GC partial),
  D-461 (SIMD-spill, blocks D-460). D-335 (WASI 0.3 core) DONE. Rest front-tagged (future-bucket/parked).
- **Realworld corpus**: 56 fixtures (c/cpp/emcc/go/tinygo/rust/zig), interp 56/0; JIT run-stage opt-in.
- **Tag**: `v2.0.0-alpha.3` tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3` — fixture toolchains. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0187-0191** (CM-async) · **0185** (x86_64 EH) ·
  **0099** (file-size caps) · **0126** (iso-recursive canonical equality).
- lessons INDEX: `.dev/lessons/INDEX.md` (keyword index for Step 0.4).
