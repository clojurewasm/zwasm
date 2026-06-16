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

**NEXT (autonomous)**: **ADR-0193 feature-separation migration CLOSED** (P1-P4, D-462) — one ordered `-Dwasi`
axis (default p2), `-Dcomponent` removed, p3/async comptime-fenced (`test-wasi-p3` + DCE), docs synced (WASI D+→B,
component D→B; default `p2→p3` flip tracked under D-335). Now driving the **D-461 rework campaign** (see below).
Then `D-209` memory64. **windowsmini gating RESUMED**. Version → `2.0.0-alpha.3`.

## D-461 regalloc-origin rework (ADR-0153/ADR-0194) — CLOSED Phase I-V 2026-06-16

- **CLOSED**: the x86_64 regalloc v128-spill OOB (`regalloc.zig:222`) is FIXED. Root was THREE inconsistent
  spill-frame origins (mint `max(gpr,fp)` / `spill_offsets` sizing hardcoded-8 / `slot()` resolve patched-pool).
  **Fix (ADR-0194)**: thread the per-arch `max_reg_slots_gpr` into `computeWith`→`computeSpillOffsets` so the array
  is sized+indexed from the same origin `slot()` resolves with, set at BUILD time (dropped compile.zig's GPR
  post-patch). Phases: I (`ccf49f4c` instrumented dump), II (`c4c1d567` characterization + the zero-coverage
  spill_offsets resolve path), III (`6500a611` ADR-0194 design), IV (`3cd2ede6` impl). **Verified**: arm64
  byte-identical 2922 green; x86_64-Rosetta rc=0, OOB gone; lesson `x86_64-regalloc-fp-spill-origin-mismatch`.
- **Phase V retrospective**: hit the 完成形 (one coherent origin, no arch-tuned-default trap); rejected the
  class-aware-mint over-reach + the array-elimination (scalars still pack 8-byte). New debt = none beyond the
  pre-existing D-461 continuation below.

## NEXT — D-461 SIMD v128-spill: DONE the safe single-source ops; REMAINING is exotic+fixture-gated

**DONE both arches, 3-host green** (regalloc rework ADR-0194 Win64-verified @8f4f88c5): all 6 extract_lane variants
+ bitmask i8x16/i32x4/i64x2 — backward-compatible source swap `resolveXmm→xmmLoadSpilledV128` (home XMM when not
spilled; no scratch collision). The concrete D-460 blocker (extract_lane) is CLEARED. **REMAINING (exotic,
high-v128-pressure only; each needs a force-spill FIXTURE)**: (a) i16x8 bitmask — uses XMM14(=stage 0) as PACKSSWB
scratch → load source into stage 1; (b) result-WRITE ops Extend/Extadd/replace_lane + op_simd.zig binop dsts
(:249/282/313/343/373/402) — need source-swap + dest `xmmDefSpilledV128`/`xmmStoreSpilledV128` + stage alloc.
**LANDMINE**: stage XMMs 14/15 can collide with an op's internal scratch → audit per-op + add a force-spill
fixture before each swap (silent miscompile otherwise — the i16x8 case proves it). NEXT chunk = i16x8 bitmask
(stage-1 source load) WITH a force-spill fixture, then the result-write ops one at a time (fixture each). TDD via
`zig build test -Dtarget=x86_64-macos` (Rosetta). `D-209` memory64 is the front after this bundle closes.

## Closed/paused (detail in git + debt.yaml)

- **doc-inventory freshening DONE** (`42441634` README + ADR-0193 P4 doc-sync): reader-facing surfaces clean
  (C-API 293/293, component 158/0/0, Wasm 2.0 skip-impl==0, 3.0 all-9-proposals, version anchors retired).
- **ADR-0192 wasmtime differential campaign — paused**: goal met (9 real engine bugs fixed via wasmtime
  misc_testsuite + 6 SIMD via D-457). Residuals: **`D-460`** v128-GC (arm64 struct/array get/set EMIT DONE
  `f79a3ced`/`41015a9b`; array.new_fixed/copy + x86_64 mirror unblocked NOW by the D-461 spill fixes in progress),
  **`D-209`** memory64 >4 GiB offset, **D-456** host-import fixtures (parked). Harness `scripts/wasmtime_misc_*.sh`.

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
