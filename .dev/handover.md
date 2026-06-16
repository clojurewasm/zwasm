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

**NEXT (autonomous)**: the **ADR-0192 wasmtime campaign is the active frame (Phase III REOPENED — see below)**; pick
gap **A `D-460`** (v128-in-GC-aggregate) next. Secondary: ADR-0174 Phase-2 windows-suspension still eligible
(`should_gate_windows.sh --suspend` → 2-host fast-loop; resume before main-merge / Win64-risk); Phase-17 surface
audits; doc-inventory phase (USER-requested).

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
- **Real-gap triage (Phase III)**: **A `D-460` (now)** v128 in a GC aggregate field rejected by
  `type_info.fieldSlotSize` (uniform-8-byte slot vs 16-byte v128) — 4 fixtures; multi-step (slot model). **B FIXED**
  this cycle (`2daaf643`). **C `D-209`** memory64 >4 GiB memarg offset `BadMemarg` at lowering — wasmtime
  `memory64/offsets.wast` uses it in an `assert_trap` (executed), falsifying D-209's "never executed" premise; fix =
  the multi-arch 10.M-4b chunk. **Parked = D-456** host-import fixtures (UnknownImport: binary-tree/gc-pressure/
  issue-13066/13480/struct-set-gc-ref/array-copy-gc-refs/function-references-instance/multi-memory-simple) — genuine
  host funcs the native runner doesn't define; runner-extension, not engine gap.
- **NEXT (Phase III→V)**: pick A (`D-460` v128-aggregate) next — TDD struct/array v128 field. Then C (`D-209`) if
  pursuing. Then V retrospective + promote legit fixtures. Harness: `scripts/wasmtime_misc_{sweep,native_sweep}.sh`.

**The prior user-steered 4-front async-maturity campaign (2026-06-16) is COMPLETE** — all four closed (history below);
general Phase-17 completion work (debt sweep / surface audits) interleaves when the campaign pauses.

- **② wasmtime async .wast gaps — DONE (TIER-1)**: Gap A `afcf889a` (async export w/ result must `task.return` before
  EXIT), copy-IDLE `05b35c28`. Deferred design-grade: **D-446** Gap B, **D-447** TIER-2/3.
- **① wasip3 conformance — DONE**: 7 real-rust-wasip3 fixtures (cli-exit/stdout/stderr/env/args/stdin/clocks) via the
  hermetic `.#gen-wasip3` recipe. D-448 caveats. Lessons `…-wasip3-hermetic-build-recipe`, `…-wasi-cli-exit-result-channel`.
- **④ perf — DONE (ROI-rejected, accept the single-pass ceiling)**: base64 13.6× = mostly class-B (global-regalloc/LICM,
  needs the forbidden optimizing tier). zwasm is "lightweight-fast within single-pass". D-450→note. Lesson `…-base64-…-ceiling`.
- **③ real-world GC corpus — CLOSED (validator-hardening payoff banked)**: the AssemblyScript + Guile-Hoot probes found
  + FIXED **6 real engine spec bugs the synthetic spec suite missed**: D-451 jit-lenient-import instantiation (`4c8c14fe`)
  + 5 validator/decoder — return_call subtype (`9064faa5`), table.copy subtype (`480809af`), iso-recursive canonical
  equality (`9ec68a75`), **D-453** heap-type SLEB decode / concrete idx≥64 across validator+lower+interp+both-arch JIT
  (`c528c3b3`), **D-452** br_table operands subtype-not-pairwise-eql (`79742cb4`). All one exact-eql-vs-subtyping /
  decode-length class. **4 GC edge fixtures green** (`test/edge_cases/p10/gc/`: canonical_eq_call_arg,
  ref_cast_concrete_idx64, ref_test_null_idx256, br_table_reftype_subtype — real GC programs exercising
  struct.new/get + ref.cast/test + br_table at runtime). zwasm now fully validates+lowers a dense real Hoot wasm-gc
  module (correctly rejecting its 36 unsatisfied imports at instantiation, §4.5.4). RUNNING a real Hoot program to an
  observable result is **deferred → D-454** (blocked on porting Hoot's reflect host ABI — disproportionate; feasibility
  probe 2026-06-16: run-side bounded, observe-side a multi-cycle host port). Lessons
  `validator-exact-eql-where-reftype-subtyping-required` + `leb-decode-desync-manifests-far-downstream` +
  `src-signature-change-misses-test-all-only-runner-callers`.

**WASI 0.3 / Preview 3 core DONE** (D-335): CM-async runtime runs async components from `zwasm run` + embedder —
callback loop EXIT/YIELD/WAIT, both stream directions (host peers), waitable-set, return-future; 18 async e2e fixtures,
3-host (ADR-0187 stackless / 0188-0191). Hardening D-337 (future-drop-before-write trap), D-445-partial (guest-fault→trap).

**NEXT (autonomous)**: 4 fronts done → resume general Phase-17 完成形 work. Candidates: Step 0.5 debt sweep (55 entries;
discharge dissolved barriers); surface audits (C/Zig/CLI あるべき論); D-446/D-447 (async design-grade) if pursuing CM-async
depth. validator.zig at 3449/3450 cap — the NEXT validator edit MUST extract per the file's marker plan (no 3rd cap-bump).

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
