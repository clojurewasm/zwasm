# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17, STOPPED for USER DECISION: `.auto`→JIT flip = a CAMPAIGN, not overnight (D-496)

**STOPPED 2026-06-22 (bucket-2/3, surfaced to user).** The overnight directive was: complete `.auto`→JIT flip → cljw
coordinate → tag `v2.0.0-alpha.3` → stop. Reality: the FULL `.auto`→JIT flip is a **multi-cycle JIT-C-API campaign**,
NOT an overnight task — so it is NOT done, and the tag (its precondition) was NOT cut. Tree restored to the GREEN
committed baseline (dbda9f873); cron `224c0c30` DELETED; loop NOT re-armed (clean stop).

**What IS done (committed, 3-host green)**: D-489 + D-494 — the two real flip blockers — RESOLVED @462ea1e57 (regalloc
LSRA dual spill-slot mint collision; fix = unify on `n_spill_minted`; ubuntu+windows test-all OK; realworld 56/56 both
arches; regverify 0). This is the substantive content of a would-be alpha.3.

**Why the flip stalled (D-496)**: implemented the routing (`.auto`→try-JIT→interp-fallback) + fixed a REAL regression
(CLI `--fuel`/`--timeout` only armed interp → .auto→JIT hung an infinite loop; fixed via jitOf().setFuel/setInterruptFlag)
+ test pins. Full `zig build test` then surfaced **69 failures**: ~36 component (via the LINKER — avoidable if the
linker stays `.interp`), ~30 genuine **JIT-C-API GAPS** (a JIT instance surfaces NO memory/table/global externs;
`zwasm_instance_get_func`/`wasm_extern_as_memory|table|global`/introspection return NULL on JIT), ~3 cli.run. CLI
`zwasm run` itself is fully JIT-correct (.auto-vs-interp 56/56). あるべき論 (don't ship a half-working default) → reverted.

**DECISION NEEDED (D-496) — three options for the user**:
- **(A)** Tag `v2.0.0-alpha.3` NOW on the green regalloc-fix baseline; defer the flip to a campaign (cljw is BLOCKED
  awaiting the tag; flip becomes alpha.4/post). Fastest unblock for cljw. *(to_cljw_07 announced the flip "landing" —
  correct via to_cljw_08 before tagging.)*
- **(B)** SCOPED flip = CLI `zwasm run`→JIT-with-interp-fallback only; C-API `.auto` stays interp (overnight-feasible;
  delivers "run defaults to JIT" without the C-API surface work) → then tag.
- **(C)** FULL flip = a JIT-C-API accessor/introspection campaign (ADR-0153 five-phase) before the tag.

cljw status: CONSUMED to_cljw_07 (resource contract pts 1-4 confirmed) + AWAITS the alpha.3 tag. Release notes drafted
`.dev/release_notes/v2.0.0-alpha.3.md`; last tag `v2.0.0-alpha.2`. Full flip work re-implementable per D-496 refs + git reflog.

Project at the **完成形 plateau** (all dims confirmed): clean (C/Zig/CLI audits), full-featured (WASI complete +
now cross-component STRING composition, D-305 milestone), 100% spec (`test-spec` 25539/0), lightweight-yet-fast
(v1-JIT parity, D-265 closed). Robustness: interp+JIT fuzz 0 crashes. Closed-arc detail lives in git/ADRs/lessons.

**Closed arcs (detail in git/ADRs/debt — do NOT re-walk)**: D-305 cross-component linker (string/list/record
marshalling both directions, ADR-0196, comp-assert 170/0); ADR-0195 guest↔guest async FUNCTIONALLY COMPLETE +
D-463 handle isolation (ADR-0197); D-034 SIMD spill-completeness CLOSED @411dd1e14; wasi:random, D-335 typed
marshalling, C-API Windows-export. Residual long-tails (debt-tracked, do NOT grind): D-464 async adversarial,
D-305 niche shapes. Version `2.0.0-alpha.3`. Low-pri follow-up: consolidate duplicated SIMD spill helpers.

## Closed bundle — D-489/D-494 regalloc fix (DONE @462ea1e57)

Exit-condition met (x86_64 jit tinygo_json = 90). Both flip blockers resolved by the unified spill-mint fix; full
story in lesson `2026-06-22-d489-capture-path-investigation.md`. No active bundle.

**WINDOWS GATE — 3-host GREEN @ed9332294** (2026-06-21): earlier host-example file-create failure was an ENV FLAKE,
cleared on re-run (Win64 spec 25539/0, simd 25075/0, wasi 3/0). Recorded via `--record`. Intermittent
host-embedding-example file-create stays debt-tracked (`windows-host-example-filecreate`), NOT a code regression.

## Closed arcs (do NOT re-walk)

v128-GC sweep (D-491/492/493 fixed, D-495 guarded); arm64 JIT-exec ZERO divergences; ADR-0200 JIT embedding API +
cljw consumed `to_cljw_06`. Tag-cut PENDED (release notes drafted `.dev/release_notes/v2.0.0-alpha.3.md`; last tag
`v2.0.0-alpha.2`). cljw dogfooding PAUSED both sides. D-489/D-494 detail → lesson `2026-06-22-d489-capture-path-investigation.md`.

**Operational notes**: a JIT-codegen fix → verify on BOTH arm64 AND `-Dtarget=x86_64-macos` (NOT interp `test-spec`).
**Rosetta x86_64-macos reproduces D-489** (the prior "Rosetta MASKS x86_64 bugs" claim is FALSE — corrected). Phase 17
完成形 plateau holds (spec 100%, fuzz 0-crash, surface audits clean 2026-06-18, realworld JIT 56/56 byte-match wasmtime
GATING via `test-realworld-diff-jit`). D-475 table64-JIT PARKED (perf, Win64-risk). The prior 2026-06-20 "correctness
sweep" standing directive is SUPERSEDED by the `.auto`→JIT flip-campaign priority (POSTURE above).

**Step-0.7 NOTE**: `failed command: test…--listen=-` is COSMETIC (exits 0); trust `[run_remote_*] OK/FAIL` + `N
passed, 0 failed`, not that line.

**PARKED / gated (do NOT speculatively grind)**: D-305 long-tail (niche, + `component_graph.zig` 1895/2000
file-split first); D-464 async; 21 `blocked-by`. **validator.zig at 3449/3450 cap — NEXT validator edit MUST
extract per the file's marker plan.** Closed-arc detail (D-305/ADR-0192/async/WASI-0.3) is in git/ADRs/debt.

## Long-tail (debt-tracked / parked — NOT active; see debt.yaml)

- **JIT-correctness** (front B): D-330/D-331/D-333 all resolved+deleted from debt. Re-verified post-462ea1e57: ALL
  go_*/c_sha256/rust_sha256 realworld fixtures content-match interp-vs-jit on BOTH arches. D-454 GC-program fixture
  future-bucket. Trace tooling: `ZWASM_DEBUG=jit.dump`/`regverify` + `scripts/jit_value_trace.sh` (Recipe 18).

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
