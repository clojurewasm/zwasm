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

- **Post-§16 backlog — loop in refinement/maintenance mode; no release (ADR-0156).** Cleared this session
  (detail in ROADMAP §16 rows + ADRs + CHANGELOG): phase-boundary audit; **D-257** lesson backfill; examples/
  fmt-gate; **D-277** zwasm.h; **D-275** `wasm_instance_new` trap_out → `StartTrapped`; **D-276 discharged by
  PROOF** (`4accb556`, ADR-0060 force-spill); **D-274** accepted (zlinter eager fetch, dep slated for Zig-0.17
  removal, `84f8a652`).
  **Remaining backlog:**
  - **D-262 (b) PROCESS FIX LANDED this turn** (`5471e5fb`, ADR-0076 **D6**): the background ubuntu gate is now
    unconditionally `test-all` (classifier drives the foreground Mac gate ONLY) — the eyeballed per-turn ubuntu
    scope (the D-260 foot-gun) is gone. D6's root insight: D5-b made ubuntu no-wait, so narrow scope there saved
    zero loop wall-clock while staying a coverage foot-gun. **D-262 stays `now` one more cycle**: its discharge
    needs the (a) audit RUN — the first D6 `test-all` kick is in-flight this turn; discharge at Step 0.7 GREEN.
  - **D-273** CLI `--invoke` args + **D-269** callable funcref — wasmtime-parity, **no demonstrated need** (§16.5
    dogfooding). Per ADR-0159 (evaluate against real need; don't pre-build) → wait for a real consumer need.
  - **J.3** ~30 `blocked-by` rows (D-007/010/020-028/074, all external/later-blocked) → `suggest meta_audit`
    (user-gated re-walk). **15.6** (only open ROADMAP `[ ]`) externally blocked on cw-v1 landing (D-264).

## Step 0.7 (next resume) — VERIFY THE D6 AUDIT KICK

**ubuntu kick PENDING this turn = `test-all` against `<this turn's HEAD>` (D-262(a) audit + FIRST D6 always-test-all
kick).** Next cycle: `tail -3 /tmp/ubuntu.log` →
- **GREEN `OK (HEAD=<sha>)`** → x86_64-RUN of all committed emit passed → **discharge D-262** (`del` the row; both
  (a)+(b) met) + drop this Step-0.7 note.
- **FAIL** → a real latent x86_64 emit bug surfaced (exactly D-262's fear) → fix it as a NEW finding; do NOT revert
  the D6 commit (the topology fix is correct — it's what caught the bug).
**Gate**: Step-5 Mac = `bash scripts/mac_gate.sh`. windowsmini = manual-only (ADR-0156: no loop tag).

## Deferred / open debt (D-274/275/276/257 discharged this session — removed)

- **Memory-safety (§16.6 DONE, verified 2-host; D-276 proven by ADR-0060)** — only residual is **D-211** precise
  GcRootMap (deferred; conservative scan proven sufficient meanwhile). **D-210** cohort root fix (D-142/206/210/245).
- **Surface residuals** — **D-269** funcref opaque `?u64` (not callable from a table slot). **D-273** CLI flag
  gap vs wasmtime (`--invoke` args/result-print, `--env`/`--fuel`/`--timeout`). **D-253** ref machinery (incl.
  D-253-D standalone-copy). **D-271** serialize=source-bytes (no AOT cache). **D-255** C-API WASI io. **D-251** WASI in AOT.
- **D-254** rust 3-OS. **D-249** win bench. **D-238** x86_64 EH thunk. **D-266/D-259** notes.

## Key refs

- ROADMAP §16 (16.1–16.4 ✅ → 16.5 dogfooding → 16.6 memory-safety → 16.7 docs; NO release gate). §1.2 (完成形
  industry-standard surfaces). ADR-0156 (endgame); **ADR-0159 (§16.4 CLI = run+compile)**; ADR-0157/0158 (C-API
  split + ref model); ADR-0109 (Zig facade); ADR-0136 (`run --engine`). `scripts/capi_surface_gap.sh` (gap=0).
