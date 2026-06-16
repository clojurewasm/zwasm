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

**NEXT (autonomous)**: the **ADR-0192 wasmtime campaign is the active frame (Phase III — see below)**. Gap B fixed
(`2daaf643`); gap A core fixed (`60c54db5`). Next candidate = JIT GC-v128 emit (D-460 residual) OR gap C (D-209
memory64) — both multi-arch codegen bundles — OR campaign V retrospective. Secondary: ADR-0174 Phase-2
windows-suspension (`--suspend` → 2-host fast-loop; resume before main-merge / Win64-risk); doc-inventory phase.

## Planned future phase (USER-requested 2026-06-16)

- **Doc inventory + freshening**: walk ALL zwasm_from_scratch docs (CLAUDE.md, .dev/, .claude/, README, docs/) and
  reconcile against CODE TRUTH — find+fix stale claims (e.g. "100% SIMD spec" was overstated; conversion ops were
  missing). Not started; queued post-campaign per user.

## Active rework campaign

- **Campaign**: wasmtime misc_testsuite full differential coverage (ADR-0192, user-directed 2026-06-16). **Phase III
  REOPENED 2026-06-16** — the prior "native sweep CLEAN" tally was WRONG (lesson
  `native-sweep-instantiate-fail-not-equal-host-import`): it folded all instantiate-FAILs into "host-import parked",
  but per-module re-triage (`zwasm run <baked> --invoke`) found **3 real DEFERRED engine gaps**, not host imports.
- **Goal**: run wasmtime's full `tests/misc_testsuite/` (312 .wast) through zwasm, fundamentally fix every real gap.
- **Tally: 8 real zwasm bugs fixed** — array.copy self-region alias ×interp+JIT (`46c2975e`), array.new u32 overflow
  (`7e527dba`), bottom-reftype 0x71-0x74 decode (`d54b789f`), C-API active-data-drop (`c1f727d4`), **extern.convert_any/
  any.convert_extern identity in const-expr (`2daaf643`, this cycle — gap B; fixture const-expr-gc returns 55)**, + 6
  SIMD via D-457. Lessons: `gc-bulk-op-memcpy-aliases-on-self-region-copy`, `wasmtime-fixtures-over-assert-exact-canonical-nan`,
  `native-sweep-instantiate-fail-not-equal-host-import`.
- **Real-gap triage (Phase III)**: **A `D-460` CORE DONE** (`60c54db5`) v128 in a GC aggregate — 16-byte slot +
  interp struct/array get/set + const-expr v128.const; alloc-v128-struct instantiates, const-expr-gc-simd
  v128-array-len→2. RESIDUAL: JIT GC-v128 emit (SIMD is JIT-only D-244, so observing a v128 field via extract_lane
  needs the JIT path — array-copy-inline.6→16 still `UnsupportedOp`); array.new_data+v128 exotic. **B FIXED**
  (`2daaf643`). **C `D-209`** memory64 >4 GiB memarg offset `BadMemarg` at lowering (assert_trap-executed; multi-arch
  10.M-4b chunk). **Parked = D-456** host-import fixtures (UnknownImport; runner-extension, not engine gap;
  v128-with-gc-ref is here too — `import "wasmtime" "gc"`).
- **NEXT (Phase IV)**: the JIT GC-v128 emit bundle (below) is the active sub-task. After it: gap C `D-209` memory64
  (multi-arch 10.M-4b) then campaign V retrospective. Harness: `scripts/wasmtime_misc_{sweep,native_sweep}.sh`.

## Active bundle

- **Bundle-ID**: D-460-jit-v128-gc-emit (campaign Phase IV continuity)
- **Cycles-remaining**: ~3 (architectural; 7 op files × 2 arches + v128 vreg result class)
- **Continuity-memo**: JIT GC ops hardcode an 8-byte slot. Extend struct_get/set/new + array_get/set/new_fixed/copy
  on BOTH arches to v128: index×16 stride (x86_64 uses Lsl3=×8 in `encMovR64FromBaseIdxLsl3`; arm64 mirror) + a
  16-byte XMM load/store (movdqu) + a NEW v128 result-class arm (def = XMM vreg, not GPR). Width from
  `FieldInfo.size` / `arrayElemValType==0x7B`. Full Phase-I scope in debt D-460. NOT a wrapper-thunk issue (func
  returns i32 via extract_lane).
- **Test vehicle**: `engine/runner_gc_test.zig` `runI32Export(alloc,&bytes,"f")`. First red→green:
  `struct.new $s (i32x4.splat 5); struct.get $s 0; i32x4.extract_lane 0` → 5. `zwasm run --engine jit` does NOT
  print export results — use runI32Export / native runner.
- **Exit-condition**: struct + array v128 round-trip via runI32Export green on BOTH arches AND wasmtime
  gc/array-copy-inline.6 returns 16 under the native runner; e2e edge fixture under test/edge_cases/p10/gc/.

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
- **Debt**: 56 entries; D-335 (WASI 0.3) the main `now`-class. Rest front-tagged (A/B/C/D-wasi03/future-bucket/parked).
- **Realworld corpus**: 56 fixtures (c/cpp/emcc/go/tinygo/rust/zig), interp 56/0; JIT run-stage opt-in.
- **Tag**: `v2.0.0-alpha.3` tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3` — fixture toolchains. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0187-0191** (CM-async) · **0185** (x86_64 EH) ·
  **0099** (file-size caps) · **0126** (iso-recursive canonical equality).
- lessons INDEX: `.dev/lessons/INDEX.md` (keyword index for Step 0.4).
