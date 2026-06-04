# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 (完成形) — §16.1–16.7 task-list COMPLETE; the loop CONTINUES, no release (ADR-0156).** Phases 0–15
  + the entire §16 surface/safety/docs task-list are DONE. The v2 redesign has hit the 完成形 bar: clean design +
  lightweight-fast + full-featured + 100% spec across the runtime AND the surfaces (C/Zig/CLI). **The loop never
  tags/publishes/cuts over** (manual user-only); it now keeps refining + paying backlog debt **indefinitely**.
  Phase Status widget stays Phase-16 IN-PROGRESS (completion-finalization is open-ended, not a closeable phase).
- **§16 outcomes** (detail in the ROADMAP §16 rows + ADRs + CHANGELOG): **§16.1** migration guide (`58a483e8`);
  **§16.2** C-API **gap 0 (293/293)** (`e9367bb2`, `scripts/capi_surface_gap.sh`); **§16.3** Zig-API facade
  confirmed minimal/clean (ADR-0025→0109); **§16.4** CLI = **run+compile** + --version/--help (ADR-0159);
  **§16.5** dogfooding — external consumability fixed + Global/Table accessors (D-272 closed), full facade proven
  via `examples/zig_dep/`; **§16.6** GC-on-JIT memory-safe — collect trigger + adversarial UAF test green
  Mac+x86_64 (ADR-0160); **§16.7** docs — README/CHANGELOG/`docs/reference/`/`docs/tutorial.md` to the settled
  surface (`12390815`, `3a5e8ba0`).

## NEXT (autonomous — §16 task-list done; phase-boundary audit DONE; backlog; ADR-0156)

- **Post-§16 backlog (no release; 完成形 = keep improving, ADR-0156).** DONE this session: phase-boundary
  `audit_scaffolding` (healthy; D-258/261 discharged); **D-257** lesson-Citing backfill; **examples/ fmt-gate**;
  **D-277** §10.4/§3.1 zwasm.h reconcile; **D-275** wired `wasm_instance_new` `trap_out` → `Module.instantiate`
  returns `StartTrapped` (+ C hosts now get the start-trap via `trap_out`/`wasm_trap_message` — a C-API conformance
  fix), `d7190346`. Remaining items are involved → each a focused FRESH-CONTEXT chunk, pick one per cycle:
  - **D-273** CLI `--invoke` NAME=ARGS arg-marshalling + typed-result printing (parse CLI strings → wasm Values by
    param type; format results). Touches `src/cli/` + needs an arg'd-invoke runner path (`runWasmJit` is zero-arg).
  - **D-269** callable funcref from host (deeper, ref model). **D-276** force register-resident GC-rooting worst
    case (hard to force the regalloc shape). **D-274** zlinter lazy dep (comptime `@import` blocker).
  - **J.3** 31 active debt rows > 15; old `blocked-by` (D-007/010/020-028/074) → `suggest meta_audit` (user-gated).

## Step 0.7 (next resume)

**Verify ubuntu** — D-275 (`d7190346`) touched the c_api instantiate path (`instance.zig` `instantiateInternal`
trap_out) + the facade; this turn kicked `run_remote_ubuntu test`. Tail `/tmp/ubuntu.log` for `OK (HEAD=…)`.
Portable Zig (no per-arch emit) → `test` scope. (Everything before D-275 this session was doc/debt-only.)
**Gate**: Step-5 Mac = `bash scripts/mac_gate.sh`. windowsmini = manual-only (ADR-0156: no loop tag).

## Deferred / open debt

- **Memory-safety (§16.6 DONE, verified 2-host)** — residual **D-276** (callee-saved-register-resident worst
  case not independently forced; common case safe).
- **Surface residuals** — **D-269** funcref opaque `?u64` (not callable from a table slot). **D-273** CLI flag
  gap vs wasmtime (`--invoke` args/result-print, `--env`/`--fuel`/`--timeout`). **D-274** consuming zwasm fetches
  zlinter (make lazy). **D-275** `Module.instantiate` coarse error. **D-253** ref machinery (incl. D-253-D
  standalone-copy). **D-271** serialize=source-bytes (no AOT cache). **D-255** C-API WASI io. **D-251** WASI in AOT.
- **D-210** cohort root fix (D-142/206/210/245). **D-211** GcRootMap. **D-257** 10 lesson `Citing` backfill.
  **D-254** rust 3-OS. **D-249** win bench. **D-238** x86_64 EH thunk. **D-266/D-259** notes.

## Key refs

- ROADMAP §16 (16.1–16.4 ✅ → 16.5 dogfooding → 16.6 memory-safety → 16.7 docs; NO release gate). §1.2 (完成形
  industry-standard surfaces). ADR-0156 (endgame); **ADR-0159 (§16.4 CLI = run+compile)**; ADR-0157/0158 (C-API
  split + ref model); ADR-0109 (Zig facade); ADR-0136 (`run --engine`). `scripts/capi_surface_gap.sh` (gap=0).
