# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 = Completion finalization (完成形) IN-PROGRESS — NOT a release march (ADR-0156).** Phases 0–15
  DONE. **The loop never tags/publishes/cuts over; release is manual user-only; no release gate exists.**
  Goal = clean design + lightweight-fast + full-featured + 100% spec across the runtime AND the surfaces
  (C/Zig/CLI), to あるべき論 + industry standards, **breaking v1 allowed, v1 full-parity NOT a goal**.
- **✅ §16.2 C-API surface audit + completion DONE** (`e9367bb2`): audit found `include/wasm.h` byte-identical
  to upstream wasm-c-api but **129/293 extern fns unimplemented** (link errors); implemented ALL → **gap 0
  (293/293)**, live-checked by `scripts/capi_surface_gap.sh`. Path: A type-accessors → B vec-ops (PtrVecOps) →
  C config → D val(POD) → instance.zig split (ADR-0157 → handles.zig) → host_info (27) → ref-cast same/as_ref/
  copy all 9 types (ADR-0158, new ref_base.zig) → tagtype/EH (TagType) → module serialize/share (byte-model,
  module_serialize.zig). Residual SEMANTIC limits debt-noted (functions exist + honest): val `of.ref`=raw
  payload (D-269), standalone/instance/foreign `_copy`→null (D-253-D), serialize=source-bytes/no-AOT (D-271).
- **✅ §16.1 migration guide** (`58a483e8`). **Phase 15 CLOSED** (D-265 register-homing campaign, ADR-0153).

## NEXT (autonomous — surfaces first, docs last; ADR-0156)

- **§16.3 — Zig-API surface review (あるべき論) — NEXT.** Confirm the `Engine`/`Module`/`Instance`/`Trap`/
  `Value`/`TypedFunc`/`Linker`/`Caller`/`Memory` surface (`src/zwasm.zig` facade) is the minimal, clean,
  idiomatic shape. **Reconcile D-267**: ROADMAP §10.A + ADR-0025 D-7 name the stable surface `Runtime` /
  `Module.parse(&rt,bytes)` / `getTyped`, but the SHIPPED + tested API is `Engine` / `engine.compile` /
  `instance.typedFunc` — code is correct (3-host green), spec wording is stale. DISCHARGE: update §10.A +
  ADR-0025 D-7 to the shipped names (Revision on ADR-0025, code-as-truth) OR add a `Runtime` alias if intended.
  Breaking-allowed. Step 0: survey `src/zwasm.zig` (exports + the 13 facade tests). TDD where behaviour changes.
- After §16.3: **§16.4** CLI あるべき論 review (kept surface; v1 sprawl not owed) → **§16.5** minimal-wrapper
  dogfooding (local build.zig.zon consumer; API/CLI-gap hunt — likely re-surfaces D-269 of.ref) → **§16.6**
  memory-safety (D-258 wire JIT-trampoline GC collect → D-261 GC-on-JIT adversarial test; highest stakes) →
  **§16.7** docs LAST (README/reference/tutorial/CHANGELOG, match the settled surface). Chain; pay debt en route.

## Step 0.7 (next resume)

**Verify ubuntu** — §16.2 G (`e9367bb2`) pushed + `run_remote_ubuntu test` kicked this turn; tail
`/tmp/ubuntu.log` for `OK (HEAD=…)`. §16.2 C-API work is portable Zig (non-emit) but the C-ABI differs on
Linux SysV, so a per-code-chunk test kick is worthwhile. If a chunk touches per-arch emit, **D-262 rule**:
`run_remote_ubuntu test-all` before discharge (cross-compile ≠ cross-run). **Gate**: Step-5 Mac =
`bash scripts/mac_gate.sh`. windowsmini exec = phase boundary.

## Deferred / open debt

- **Memory-safety (highest stakes; §16.6)** — **D-261** GC-on-JIT conservative rooting has NO adversarial test
  → latent UAF, **blocked on D-258** (JIT-trampoline GC collect trigger). Close D-258 → D-261 before 完成形.
- **C-API residuals (note)** — **D-269** val `of.ref`=raw-payload (reconcile in ref-model). **D-253** ref
  machinery remainder incl. D-253-D standalone-copy/registry. **D-271** serialize=source-bytes (no AOT cache).
- **Surface** — **D-267** Zig API doc-vs-code drift (§16.3 reconcile target, ADR-0025 Revision). **D-268** note
  x86_64 homing ≤2 locals. **D-255** C-API WASI io. **D-251** WASI in AOT.
- **D-210** cohort root fix (D-142/206/210/245). **D-211** GcRootMap. **D-257** 10 lesson `Citing` backfill.
  **D-254** rust 3-OS. **D-249** win bench. **D-238** x86_64 EH thunk. **D-266/D-259** notes.

## Key refs

- ROADMAP §16 (16.2 ✅ → 16.3 Zig-API → 16.4 CLI → 16.5 dogfooding → 16.6 memory-safety → 16.7 docs; NO
  release gate). §1.2 (完成形 industry-standard surfaces). ADR-0156 (endgame); ADR-0157 (instance.zig split);
  ADR-0158 (wasm_ref_t model); ADR-0025 (Zig surface, D-267 target); ADR-0004 (wasm-c-api pin).
  `.dev/c_api_surface_audit_2026-06-04.md` (the §16.2 audit). `scripts/capi_surface_gap.sh` (live gap=0 check).
