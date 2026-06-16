# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17 完成形 completion-refinement (release = USER-ONLY, ADR-0156)

Project at the **完成形 plateau** (all dims confirmed): clean (C/Zig/CLI audits), full-featured (WASI complete +
now cross-component STRING composition, D-305 milestone), 100% spec (`test-spec` 25539/0), lightweight-yet-fast
(v1-JIT parity, D-265 closed). Robustness: interp+JIT fuzz 0 crashes. Closed-arc detail lives in git/ADRs/lessons.

**ADR-0195 multi-task async scheduler PARKED** (blocked-by D-305): guest↔guest async needs a subtask = cross-component
async import to a GUEST callee = the component linker. Retained the Phase II(a) `AsyncDeadlock` char test (`80ec1f63`);
design stands (ADR-0195 Rev + lesson `2026-06-17-guest-guest-async-is-downstream-of-component-linker`).

**Prior arcs**: wasi:random COMPLETE; ADR-0193 feature-separation follow-up + version SSOT; D-335 typed marshalling
DONE; C-API @b4d75506 (Windows export fix); interp+JIT fuzz 808 mods 0 crashes (robustness verified).

**D-305 component-composition first milestone DONE** (this turn, @4cceeb1e, ADR-0196 — see closed-arc below):
cross-component STRING + `list<primitive>` marshalling works (strlen + listu32 + listu64 PASS, 161/0; @689040e6).
The fully-general linker now exists; remaining
aggregate shapes are consumer-gated D-305 debt.

**NEXT (autonomous)**: the D-305 milestone is banked + x86_64-verified; the remaining aggregate shapes
(list/record/result/tuple) are **consumer-gated debt with a precise scope recorded** (D-305 row) — NOT grinding the
long-tail speculatively (each needs alignment-sensitive boundary marshalling; lands when a fixture/consumer demands,
or in a dedicated fresh-context session). Posture = **plateau maintenance** (periodic fuzz, debt sweeps, surface
micro-audits); land a remaining aggregate IF a real consumer appears. **D-305 milestone now 3-HOST-VERIFIED**
(`component_model_assert` 161/0 on ubuntu x86_64 AND windows Win64; string + list<primitive> boundary marshalling).
ADR-0193 (D-462) + D-461 (ADR-0194) CLOSED (below). **windowsmini gating RESUMED**. Version `2.0.0-alpha.3`.

## D-305 component-composition — first milestone CLOSED 2026-06-17 (@4cceeb1e, ADR-0196)

CLOSED: cross-component STRING marshalling works. New `src/api/component_graph.zig` does two-level instantiation
(outer `component_instances` × inner `core_instances` loop) + a boundary trampoline copying the string
caller-mem→callee-mem via `canon.CanonContext`; typed `UnsupportedBoundaryType` for unimpl shapes. `strlen_graph`
spec PASS (`firstbyte("Z")→0x5A`) + adder flat intact = `component_model_assert` 159/0/0; build+test+test-spec+
test-component-spec+lint green; **x86_64-VERIFIED @b4e33689 (ubuntu test-all exit 0)**, windows batched. REMAINING
D-305 (debt, consumer-gated; NOT grinding speculatively): other aggregate shapes
(list/record/result/tuple) + result-direction string + deeper graphs — reuse `BoundaryCtx`/`CanonContext`, land
when a fixture demands. (A subagent wrote the impl during an API outage; main loop verified + committed it.)

## D-461 regalloc-origin rework (ADR-0153/ADR-0194) — CLOSED Phase I-V 2026-06-16

CLOSED: x86_64 regalloc v128-spill OOB (`regalloc.zig:222`) fixed — three inconsistent spill-frame origins unified
by threading per-arch `max_reg_slots_gpr` into `computeSpillOffsets` (ADR-0194; impl `3cd2ede6`). Verified arm64
2922 green + x86_64-Rosetta rc=0. Full detail: ADR-0194 + lesson `x86_64-regalloc-fp-spill-origin-mismatch`.

## D-461 SIMD v128-spill — high-value DONE (3-host green); result-write remainder = tracked debt (exotic)

DONE both arches 3-host: origin rework + all 6 extract_lane + 4 bitmask widths. Result-write remainder
(Extend/Extadd/replace_lane/binop-dsts, x86_64-only, ~26-site thread, EXOTIC) = tracked in D-461 debt row; re-open
as a focused bundle if a real program needs it.


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
