# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17 完成形 completion-refinement (release = USER-ONLY, ADR-0156)

## Recently closed — simd-convert-ops-e2e bundle (D-457): CLOSED @95b8eb99

D-457 discharged. The systemic audit (full-SIMD-op execution sweep) found+fixed **6 more corpus-hidden bugs**, all the
same multi-layer-wiring pattern as the convert ops. Root cause: `regen_spec_simd_assert.sh`'s `NAMES` array baked only
**33 of 59** upstream `simd_*.wast`; the 26 omitted hid whole op families. Added all 59 → surfaced 6 fails:
- demote/promote (94/95) + f32x4/f64x2 rounding (103-106/116/117/122/148): validator binop→unop arity fix (same MVP
  miscount as convert ops); i64x2.extmul (220-223): absent from validator binop list; narrow (101/102/133/134):
  lower-side wiring missing. Per-arch emit handlers were complete on both arches all along — wired validate+lower+emit.
- simd_memory-multi: multi-memory is a Phase-14 JIT deferral (compile.zig:125) → runner records SKIP-JIT-MULTI-MEMORY.
- simd_assert corpus **24805 passed / 0 failed** (was 24117 / 6 fail). +688 real assertions. Lesson
  `hardcoded-corpus-subset-hides-whole-op-families`. This substantially corrects the overstated "100% SIMD spec" claim.

**NEXT (autonomous)**: resume general Phase-17 work — Step 0.5 debt sweep (56 entries), surface audits (C/Zig/CLI), OR
the queued doc-inventory phase (below). The hardcoded-allowlist anti-pattern may also hide gaps in NON-simd corpora —
worth a future `comm -23` audit of every regen script's inclusion list vs upstream.

## Planned future phase (USER-requested 2026-06-16)

- **Doc inventory + freshening**: walk ALL zwasm_from_scratch docs (CLAUDE.md, .dev/, .claude/, README, docs/) and
  reconcile against CODE TRUTH — find+fix stale claims (e.g. "100% SIMD spec" was overstated; conversion ops were
  missing). Not started; queued post-campaign per user.

## Active rework campaign

- **Campaign**: wasmtime misc_testsuite full differential coverage (ADR-0192, user-directed 2026-06-16). Phase I DONE; Phase II in flight.
- **Goal**: run wasmtime's full `tests/misc_testsuite/` (312 .wast @897aa00d) through zwasm, fundamentally fix every real gap.
- **3 REAL zwasm bugs found+fixed (gc bucket, native sweep)**: (1) `array.copy` self-region `@memcpy` alias panic —
  interp+JIT → `copyForwards` (`46c2975e`); (2) huge `array.new*` u32 size-overflow panic → u64 + OutOfMemory trap +
  mapDispatchErr OutOfHeap wiring (`7e527dba`); (3) `readValType` rejected abbreviated bottom reftypes 0x71-0x74
  (nullref/nullexternref/nullfuncref/nullexnref) → BadValType on valid GC modules (`d54b789f`, wasmtime gc/issue-13152).
  All three the synthetic spec suite (362/0) never hit. Lesson `gc-bulk-op-memcpy-aliases-on-self-region-copy`.
- **Ref arg+result comparison wired into the native runner** (`7ae5f54c`, D-456 ref-part DONE): parsePayload null-ref
  args, runtimeToZwasm made total, assert_return compares refs by got's active tag. Committed wasm-3.0-assert corpus
  stays green (11997 directives, 0 fails).
- **CLEAN RESULT — native sweep shows 0 value/ref mismatches** across gc/memory64/tail-call/function-references/
  multi-memory: **every assert the runner can evaluate passes**. After the harness fix function-references fails 35→9,
  gc 45→42. ALL remaining fails are `FAILsetup`/`FAILtrapSetup`/`UnknownImport` (47+3+9) — fixtures that import host
  functions the runner doesn't define (+ memory64 `more-than-4gb` = environmental). NO zwasm value/behaviour bug remains
  in the native buckets beyond the 3 fixed.
- **4th real bug — C-API instantiate path didn't drop active DATA segments** (`c1f727d4`): instantiateRuntime wrote
  active data to memory but left data_dropped=false (the elem path + native setupRuntime/populateDataSegments already
  dropped) → memory.init from the dropped segment didn't trap (§4.5.4 step 15). Found via top-level memory_init.
  Coverage: `test/c_api_conformance/data_active_drop.c`. Spec suite stays green (Wasm-2.0 25437/0).
- **Top-level core triaged**: canonicalize-nan = spec-legal NaN divergence (wasmtime over-asserts exact bits; lesson
  `wasmtime-fixtures-over-assert-exact-canonical-nan`, NOT a bug). Rest (memory-combos/int-to-float-splat/issue6562/
  alias-region = ModuleAllocFailed multi-mem/SIMD/region modules the C-API rejects; embenchen = env-import; wast-syntax/
  many-results-with-exceptions = setup/EH harness). memory_init was the one real bug.
- **Campaign tally: 6 real zwasm bugs fixed** (array.copy alias ×interp+JIT, array.new overflow, bottom-reftype decode,
  active-data-drop) + harness now compares refs. Native buckets + top-level core extracted.
- **NEXT (Phase II→V)**: (a) run simd via `simd_assert_runner` (last unchecked bucket); (b) optional host-import wiring;
  then campaign retrospective (V) + consider promoting legit fixtures into the committed corpus.
- **Harness**: `scripts/wasmtime_misc_sweep.sh` (C-API) + `scripts/wasmtime_misc_native_sweep.sh` (native GC-capable) +
  distillers `scripts/wast_to_manifest.py` / `scripts/spec_distill/wast_to_native_manifest.py`. Both runners installed.

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
