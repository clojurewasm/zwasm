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

## Active bundle

- **Bundle-ID**: D-269B-owned-handle-ref (C-API `of.ref` = owned `wasm_ref_t*`, not raw payload)
- **Cycles-remaining**: ~2 (Phase II adversarial tests + III/IV impl; correctness-first per ADR-0153)
- **Continuity-memo**: (Phase I blast radius, this turn) `of.ref`'s encoding is GLOBAL — all 7 sites must agree, so
  it's all-or-nothing raw-payload→owned-`*Ref`. Sites: `marshalValOut` (3: host-cb args `instance.zig:957`,
  `wasm_global_get :1101`, `wasm_func_call` results `:1549`) gains `(alloc, inst)` + allocates a `*Ref`
  (mirror `wasm_table_get :1293`); `marshalValIn` (`:910`, callers :967/:1120/:1521 + `extern_new.zig:143`) reads
  `(*Ref).ref` not `@intFromPtr`. **Clean reuse**: `wasm_val_delete`/`wasm_val_copy` (`vec.zig:182/177`, today POD)
  → delegate to `wasm_ref_delete`(`instance.zig:1229`, recovers alloc from `Ref.instance.store`)/`wasm_ref_copy`
  (`extern_new.zig:334`); `wasm_val_vec_copy/_delete` cascade per-element for ref kinds. **OWNERSHIP MATRIX (the
  leak/double-free risk — design + adversarial-test first)**: results (call/global_get) = zwasm allocates, CALLER
  frees via val_delete; call args (marshalValIn) = BORROWED, don't free; host-cb path gains 2 NEW cleanups — free
  zwasm-marshalled arg refs AFTER the callback (:957), free the callback's result refs after marshalValIn reads
  (:967). Guest-internal funcref roundtrip already PASSES (spec `funcref_roundtrip.wasm=42`) — runtime fine, only
  C-API `of.ref` marshalling is the gap.
- **Exit-condition**: a path-B conformance test (`get`-returns-funcref → `wasm_ref_as_func(results[0].of.ref)` →
  call → 42) GREEN + `wasm_val_copy`/`_delete` deep for ref kinds + NO leak/double-free under ReleaseSafe
  (adversarial test: alloc/free a ref-result in a loop; double-delete guard) + 3-host test-all green. RED repro in
  [[D-269]].

## NEXT (autonomous — §16 task-list done; phase-boundary audit DONE; backlog; ADR-0156)

- **Post-§16 backlog — loop in refinement/maintenance mode; no release (ADR-0156).** Cleared this session
  (detail in ROADMAP §16 rows + ADRs + CHANGELOG): phase-boundary audit; **D-257** lesson backfill; examples/
  fmt-gate; **D-277** zwasm.h; **D-275** `wasm_instance_new` trap_out → `StartTrapped`; **D-276 discharged by
  PROOF** (`4accb556`, ADR-0060 force-spill); **D-274** accepted (zlinter eager fetch, dep slated for Zig-0.17
  removal, `84f8a652`).
  **D-262 DISCHARGED** (`4ec849c8` audit GREEN: ubuntu x86_64-RUN `test-all` = spec 25437+212 / facade 55 / realworld
  all MATCH, `OK (HEAD=4ec849c8)`). The D6 process fix (`5471e5fb`) + the green audit close both predicates — gate
  topology hardened, no latent x86_64 emit bug. **ZERO `now` debt rows remain.**

  **C-API funcref-from-C (D-269)**: survey (`295bf14b`) reframed it to a standard-wasm-c-api behavioral gap; the
  conformance test (`61b606aa`) proved PATH A (table-slot funcref) GREEN+guarded and isolated PATH B (call-result
  `of.ref`) as RED → now the **`## Active bundle` (D-269B)** above; Phase I (blast radius) done this turn.
  - **Other backlog (gated/external)**: **D-273** CLI flags (validated-defer, ADR-0159). **J.3** ~30 `blocked-by`
    → `suggest meta_audit` (user-gated). **15.6** (only open ROADMAP `[ ]`) blocked on cw-v1 (D-264).

## Step 0.7 (next resume) — kick verified GREEN this resume

The `61b606aa` test-all kick returned `OK (HEAD=7fcf6d4c)` (path-A conformance green on x86_64; guest
`funcref_roundtrip.wasm=42` also passes — gap is C-API-`of.ref`-only). No kick pending unless this turn touched
`src/` (it did not — bundle setup is doc-only). The bundle's impl cycle kicks the D6 `test-all` when it lands code.
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
