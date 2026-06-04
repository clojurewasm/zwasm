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
  **D-262 DISCHARGED** (`4ec849c8` audit GREEN: ubuntu x86_64-RUN `test-all` = spec 25437+212 / facade 55 / realworld
  all MATCH, `OK (HEAD=4ec849c8)`). The D6 process fix (`5471e5fb`) + the green audit close both predicates — gate
  topology hardened, no latent x86_64 emit bug. **ZERO `now` debt rows remain.**

  **C-API funcref-from-C (D-269 DISCHARGED; bundle D-269B CLOSED).** Survey (`295bf14b`) reframed it to a
  standard-wasm-c-api behavioral gap; path A (table-slot funcref) landed (`61b606aa`); path B (call-result
  `of.ref`) fixed via the **owned-handle ref model** (`01c1d0cb`): `of.ref` is now an owned `wasm_ref_t*`
  (`marshalValOut` allocates, `marshalValIn` reads `(*Ref).ref`, `wasm_val_copy/_delete`+vec deep-clone/free,
  host-cb arg refs lent+freed). Delta: `funcref_result_call.c` RED→GREEN incl. `-Dsanitize=address` (no
  leak/UAF), double-free-safe by null-after-free. **ZERO `now` debt rows remain again.**
  - **Backlog (gated/don't-pre-build)**: **D-273** CLI flags (validated-defer, ADR-0159). **J.3** ~30 `blocked-by`
    → `suggest meta_audit` (user-gated). **15.6** (only open ROADMAP `[ ]`) blocked on cw-v1 (D-264). Next cycle:
    no clean `now` chunk — re-assess bucket-3 (the autonomous-prep-path C-API survey lever is now spent).

## Step 0.7 (next resume) — VERIFY this turn's test-all kick

The D-269B owned-handle fix (`01c1d0cb`, `src/api/{instance,vec,wasm}.zig`) → kicked the D6 `test-all`. Mac was
green pre-push (unit + conformance + `-Dsanitize=address` + lint). Next cycle: `tail -3 /tmp/ubuntu.log` → GREEN
`OK (HEAD=<sha>)` = the owned-handle ref marshalling passes on x86_64, proceed; FAIL = revert the turn's commits
to the last verified HEAD (`7fcf6d4c`).
**Gate**: Step-5 Mac = `bash scripts/mac_gate.sh`. windowsmini = manual-only (ADR-0156: no loop tag).

## Deferred / open debt (D-274/275/276/257 discharged this session — removed)

- **Memory-safety (§16.6 DONE, verified 2-host; D-276 proven by ADR-0060)** — only residual is **D-211** precise
  GcRootMap (deferred; conservative scan proven sufficient meanwhile). **D-210** cohort root fix (D-142/206/210/245).
- **Surface residuals** — (**D-269** promoted to NEXT chunk above.) **D-273** CLI flag gap vs wasmtime (validated
  defer). **D-253** ref machinery (incl. D-253-D standalone-copy; owned-handle `of.ref` model). **D-271**
  serialize=source-bytes (no AOT cache). **D-255** C-API WASI io. **D-251** WASI in AOT.
- **D-254** rust 3-OS. **D-249** win bench. **D-238** x86_64 EH thunk. **D-266/D-259** notes.

## Key refs

- ROADMAP §16 (16.1–16.4 ✅ → 16.5 dogfooding → 16.6 memory-safety → 16.7 docs; NO release gate). §1.2 (完成形
  industry-standard surfaces). ADR-0156 (endgame); **ADR-0159 (§16.4 CLI = run+compile)**; ADR-0157/0158 (C-API
  split + ref model); ADR-0109 (Zig facade); ADR-0136 (`run --engine`). `scripts/capi_surface_gap.sh` (gap=0).
