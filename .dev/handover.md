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

- **✅ Phase-boundary `audit_scaffolding` DONE** (`1fa6c951`; report `private/audit-2026-06-05.md`): scaffolding
  healthy — schema/skip-taxonomy/skip-ADRs/zone green, no file-size hard-cap, no dead §16-doc refs, no §14 cross.
  One block (stale D-258/261 — closed §16.6 but status `now`) FIXED inline (discharged). `soon` queued below.
- **Backlog debt + refinement** (no release; 完成形 reached = keep improving, ADR-0156). Pick
  highest-value-per-risk each cycle:
  - **D-257** lesson-Citing backfill — 10 lessons with unfilled `<backfill>` Citing; `check_lesson_citing.sh` WARN
    persisting > 2 phase boundaries (F.3a escalating → block). Phase-boundary §3 action: backfill each lesson's
    citing SHA (per-lesson investigation) OR make D-257 a concrete one-shot. **Top soon.**
  - **D-274** make zlinter a lazy dep (consumers shouldn't fetch the lint tool — clean, scoped consumability win).
  - **F.6** 1 ADR pending `<backfill>` revision SHA (`check_adr_history.sh`; cohort backfill).
  - **J.3** 34 active debt rows > 15 — many old `blocked-by` (D-007/010/020-028/074) due for F.2a re-walk →
    `suggest meta_audit` (user-gated; note for the user, not autonomous).
  - Then: **D-273** CLI `--invoke` args+result-print; **D-277** §10.4↔zwasm.h reconcile; **D-269** callable
    funcref; **D-276** register-resident GC-rooting; **D-275** richer `Module.instantiate` error; `examples/` fmt-gate.

## Step 0.7 (next resume)

**No ubuntu kick pending** — §16.6 was verified GREEN at `cf21b11c`; everything since (§16.7 docs + §16.7-close +
the phase-boundary audit + the D-258/261 discharge `1fa6c951`) is **doc/debt-only** (no `src/` change → ubuntu
unaffected). Next backlog item determines the next kick (D-274 = build.zig, no test impact; D-257 = lessons,
doc-only). **Gate**: Step-5 Mac = `bash scripts/mac_gate.sh`. windowsmini = manual-only (ADR-0156: no loop tag).

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
