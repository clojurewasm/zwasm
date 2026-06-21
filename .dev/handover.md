# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17, ACTIVE CAMPAIGN: JIT-C-API surface → `.auto`→JIT flip → tag alpha.3 (user chose C)

**USER DECISION 2026-06-22: option C** — run the FULL JIT-C-API flip CAMPAIGN (ADR-0153 five-phase), THEN `.auto`→JIT,
THEN tag `v2.0.0-alpha.3`. Multi-cycle (overnight+). Drive autonomously. cljw confirmed the green baseline `8a4a01905`
is CLEAN (from_cljw_06 LOAD-regression alarm RETRACTED = false alarm; their wasm e2e all green) — no blocker. cljw
stays in WAIT for the tag (end of campaign).

## Active rework campaign

- **Campaign-ID**: jit-capi-surface-flip (D-496)
- **Goal**: a JIT-backed instance exposes the FULL embedding C-API surface (memory/table/global externs via
  `wasm_instance_exports`; `wasm_extern_as_memory|table|global`; `zwasm_instance_get_func`; introspection
  `wasm_extern_type`/`wasm_memory_type`/`wasm_table_type`/`wasm_global_type`) — so `.auto`→JIT can be the default with
  ZERO C-API regressions. Then flip `.auto`→JIT (keep the LINKER `.interp` for now — it caused ~36 of the 69) + re-land
  the CLI `--fuel`/`--timeout` JIT-arm. Exit = full `zig build test` + 3-host green WITH `.auto`=JIT, then tag.
- **Phase**: I DONE (findings below). NEXT = Phase IV impl on `.jit`-PINNED tests (keep `.auto`=interp GREEN throughout;
  flip LAST). Strategy: build the JIT C-API surface red→green via `.jit`-pinned accessor tests, NOT by flipping `.auto`
  (which reds 69 until done). When the JIT surface is complete → flip `.auto`→JIT + re-land run.zig fuel-arm + keep
  LINKER `.interp` → full test + 3-host green → tag.
- **Phase I FINDINGS (agent a91c8f4a)**: (1) HIGHEST-LEVERAGE chunk = extend `instantiateJit` (instance.zig ~791-842)
  to populate `.memory`/`.table`/`.global` into exports_storage+export_types (mirror interp `buildExportTypes`
  instantiate.zig:685; source = `jit.exportGlobal`/`exportTable` (runner.zig:1118/1159) + module memory section). That
  alone builds all 4 handle kinds in `wasm_instance_exports` (already kind-generic, instance.zig:1785) → unblocks every
  `wasm_extern_as_*` (null→handle) AND ALL introspection (module_introspect reads handle fields + module bytes, NOT
  runtime — free once handles exist). (2) Per-accessor JIT arms (each is `inst.runtime orelse return` → add `if
  (inst.jit) |jit|`): MECHANICAL — global_get/set (rt.globals_base+globals_offsets), memory_data/size/grow
  (rt.vm_base/mem_limit + JitInstance.growMemory runner.zig:1095), table_size/get/set/grow (rt.tables_ptr + growTable);
  zwasm_instance_get_func (instance.zig:1206 — bound vs compiled.func_sigs-imports, not empty funcs_storage). HARDER
  edge: funcref-table get/set (no host funcptr mirror, runner.zig:1200) — handle carefully or defer w/ debt. v128
  globals already C-union-excluded (no new gap). JitRuntime fields: jit_abi.zig:151 (vm_base:154, globals_base:206,
  tables_ptr:290).
- **Phase IV chunks**: (1) instantiateJit memory/table/global exports + `.jit`-pinned exports/introspection test;
  (2) global get/set JIT arm; (3) memory data/size/grow JIT arm; (4) table size/get/set/grow JIT arm (funcref edge);
  (5) zwasm_instance_get_func JIT arm; (6) flip `.auto`→JIT + run.zig fuel-arm + linker stays interp + full+3-host;
  (7) tag alpha.3. Each chunk = `.jit`-pinned red test → impl → green.
- **Continuity-memo**: 69-failure breakdown in D-496. Full flip routing/run.zig-fuel-arm code re-implementable per D-496
  refs + git reflog. Green baseline = `8a4a01905` (regalloc fix + docs). Phase I investigation agent dispatched
  (JIT-C-API gap map). **Backstop cron = `f34c7ee2`** (every 10 min /continue) — `CronDelete` it at the FINAL stop
  (after the alpha.3 tag), with no ScheduleWakeup re-arm (clean stop). The alpha.3 tag is USER-AUTHORIZED but cut ONLY
  at campaign end (flip green + 3-host), per option C.

**DONE (committed, 3-host green @462ea1e57)**: D-489 + D-494 (the two real flip blockers) RESOLVED = regalloc LSRA dual
spill-slot mint collision, fix = unify on `n_spill_minted`. The 69-failure flip-attempt detail + reverted-flip work is
in D-496. cljw CONSUMED to_cljw_07/08 (resource pts 1-4 confirmed) + AWAITS the tag (cut at campaign end). Release notes
drafted `.dev/release_notes/v2.0.0-alpha.3.md`; last tag `v2.0.0-alpha.2`.

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
