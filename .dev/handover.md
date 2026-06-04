# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 = Completion finalization (完成形) IN-PROGRESS — NOT a release march (ADR-0156).** Phases 0–15
  DONE. **The loop never tags/publishes/cuts over; release is manual user-only; no release gate exists.**
  Goal = clean design + lightweight-fast + full-featured + 100% spec across the runtime AND the surfaces
  (C/Zig/CLI), to あるべき論 + industry standards, **breaking v1 allowed, v1 full-parity NOT a goal**.
- **🔨 §16.5 dogfooding IN-PROGRESS — chunk 1 DONE (`3bfa460a`).** Stood up a real external `build.zig.zon`
  path-dep consumer (`examples/zig_dep/`) and it surfaced a genuine gap: `build.zig` created `core` via
  `b.createModule` (private) with **no `b.addModule` anywhere**, so `dep.module("zwasm")` panicked. `zig_host`
  only worked by sharing the in-repo private module — true external consumability (ADR-0109's claim) was never
  exercised. **Fixed**: `core` is now `b.addModule("zwasm", …)` (public); consumer runs `add(2,40)==42` clean;
  repo build+test green; `scripts/check_zig_consumer.sh` guards it (manual — pulls repo+zlinter, D-274). New wart
  **D-274**: consuming zwasm transitively fetches the zlinter lint tool (eager dep + top-level `@import`).
- **✅ §16.4 CLI surface review DONE (ADR-0159).** Surface locked at **`run` + `compile`** + `--version`/`--help`/
  `help` + unknown-subcommand error (testable `cli/dispatch.zig`); 5 dead stubs removed; §10.1/§10.2/§10.3
  reconciled to code-as-truth (`--engine` per ADR-0136). Flag-parity gap debt-tracked **D-273**.
- **✅ §16.2 C-API** (`e9367bb2`): `include/wasm.h` byte-identical to upstream; implemented all 129 missing extern
  fns → **gap 0 (293/293)** (`scripts/capi_surface_gap.sh`). Residual semantic limits honest+debt-noted: val
  `of.ref`=raw (D-269), standalone `_copy`→null (D-253-D), serialize=source-bytes (D-271). **✅ §16.1** migration
  guide (`58a483e8`). **✅ §16.3** Zig-API facade confirmed minimal/clean (no code change); D-267 reconciled
  (ADR-0025→ADR-0109); Zig Global/Table accessors = optional gap D-272.

## NEXT (autonomous — §16.5 dogfood continues → memory-safety → docs; ADR-0156)

- **§16.5 chunk 2 — host-import path — NEXT.** The consumer proves exports (typedFunc) work; next exercise
  **host imports**: a guest with `(import "env" "add" (func (param i32 i32) (result i32)))` wired via
  `Linker.defineFunc`. Survey flagged `Linker.defineFunc` as INCOMPLETE — no public
  `defineFunc(comptime Sig, mod, name, fn)`; deferred to "J.5" per ADR-0109 §3.2 (`src/zwasm/linker.zig:77-110`
  has the Payload/HostFuncEntry but not the comptime host-fn wrapper). **Step 0: verify the actual state first**
  (don't assume — may be partial), then for 完成形 full-featured Zig surface decide+implement the ergonomic
  host-fn API (likely an ADR — architectural API + comptime marshalling). Add a host-import case to
  `examples/zig_dep/` or a facade test. Then: Memory read/write from a consumer, **D-272** Global/Table
  accessors, **D-269** of.ref. (cw-v1 dogfooding stays deferred — D-264.)
- After §16.5: **§16.6** memory-safety (D-258 wire JIT-trampoline GC collect → D-261 GC-on-JIT adversarial test;
  highest stakes) → **§16.7** docs LAST (README/reference/tutorial/CHANGELOG, match the settled surface).

## Step 0.7 (next resume)

**Verify ubuntu** — §16.4 verified green at `6a5dbcdd` (last cycle). This turn pushed §16.5 chunk 1 (`3bfa460a`
public-module export + `examples/zig_dep/`) and kicked `run_remote_ubuntu test`; tail `/tmp/ubuntu.log` for
`OK (HEAD=…)`. The change is build-wiring (`b.addModule`) + an example, portable + no per-arch emit, so `test`
scope suffices. **D-262 rule** still holds: a chunk touching per-arch emit needs `run_remote_ubuntu test-all`
before discharge. **Gate**: Step-5 Mac = `bash scripts/mac_gate.sh`. windowsmini exec = phase boundary.

## Deferred / open debt

- **Memory-safety (highest stakes; §16.6)** — **D-261** GC-on-JIT conservative rooting has NO adversarial test
  → latent UAF, **blocked on D-258** (JIT-trampoline GC collect trigger). Close D-258 → D-261 before 完成形.
- **Surface residuals** — **D-274** consuming zwasm transitively fetches zlinter (make lazy; §16.5). **D-273**
  CLI flag gap vs wasmtime (`--invoke` args/result-print, `--env`/`--fuel`/`--timeout`) — §16.5. **D-272** Zig
  Global/Table accessors (§16.5). **D-269** val `of.ref`=raw. **D-253** ref machinery (incl. D-253-D
  standalone-copy). **D-271** serialize=source-bytes (no AOT cache). **D-255** C-API WASI io. **D-251** WASI in AOT.
- **D-210** cohort root fix (D-142/206/210/245). **D-211** GcRootMap. **D-257** 10 lesson `Citing` backfill.
  **D-254** rust 3-OS. **D-249** win bench. **D-238** x86_64 EH thunk. **D-266/D-259** notes.

## Key refs

- ROADMAP §16 (16.1–16.4 ✅ → 16.5 dogfooding → 16.6 memory-safety → 16.7 docs; NO release gate). §1.2 (完成形
  industry-standard surfaces). ADR-0156 (endgame); **ADR-0159 (§16.4 CLI = run+compile)**; ADR-0157/0158 (C-API
  split + ref model); ADR-0109 (Zig facade); ADR-0136 (`run --engine`). `scripts/capi_surface_gap.sh` (gap=0).
