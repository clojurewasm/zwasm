# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase 16 = Completion finalization (完成形) IN-PROGRESS — NOT a release march (ADR-0156).** Phases 0–15
  DONE. **The loop never tags/publishes/cuts over; release is manual user-only; no release gate exists.**
  Goal = clean design + lightweight-fast + full-featured + 100% spec across the runtime AND the surfaces
  (C/Zig/CLI), to あるべき論 + industry standards, **breaking v1 allowed, v1 full-parity NOT a goal**.
- **ADR-0156 (this session, user-directed)**: redirected the endgame after the loop mis-marched toward a
  "v0.1.0 release." Reworked the steering: ROADMAP §1.1/§1.2 + Phase 16 + Phase Status widget + continue
  SKILL frozen-invariant + CLAUDE.md. Debt repaid aggressively; industry research (web search / reference
  runtimes) is part of the work.
- **Phase 15 CLOSED**: §15.P parity measured + the D-265 register-homing rework campaign (ADR-0153) DONE
  (register-homed locals both backends; arm64 `w45_addi` 2.30×→0.97×; x86_64 reload penalty eliminated;
  ubuntu x86_64-linux test-all GREEN). ADR-0149/0150 Revision landed. §15.6 ClojureWasm ⏸ DEFERRED (D-264).
- **§16.1 migration guide DONE** (`58a483e8`, grounded in the shipped `src/zwasm.zig` facade). Surfaced
  **D-267** (ROADMAP §10.A/ADR-0025 name `Runtime`/`Module.parse`; ships `Engine`/`eng.compile`/`typedFunc`
  — code correct, spec stale). Will be revised as the §16.2–4 surface audits settle.

## Active bundle

- **Bundle-ID**: 16.2-capi-completion
- **Cycles-remaining**: ~3 (gap categories E/F/G; E/G are multi-cycle / design-gated)
- **Continuity-memo**: §16.2 audit DONE (`.dev/c_api_surface_audit_2026-06-04.md`, D-269) — our `wasm.h` is
  byte-identical to upstream latest, but standard extern fns were unimplemented (link-error for C
  consumers). wasmtime/wasmer ship 100%; wazero ships none. Decision: implement full standard surface (not
  wasmtime's ext headers). Live count: `bash scripts/capi_surface_gap.sh` (**gap 76**, was 129).
  Sequence: ✅A type accessors (6, `c3a979fa`) → ✅B per-type vec ops (24, `2116a18b`, PtrVecOps unify) →
  ✅C config (3) + ✅D val_copy/delete (2, POD) → ✅instance.zig split (`092196b6`, ADR-0157 → handles.zig) →
  ✅E1+E2+E3a host_info COMPLETE (27) → E3b ref-cast/same/copy: ✅ADR-0158 + ✅E3b-1 same (9, `7236237c`) +
  ✅E3b-2/2b/2c as_ref/ref_as(+const) COMPLETE — all 9 ref types (`2474f1c2`/`ae060138`/this) → **E3b-3 copy
  (9)** → F tagtype/EH (12) → G serialize/share (5). Gap 67→28. (extern_vec_copy + tagtype_vec also deferred:
  need wasm_extern_copy / TagType — wasm_extern_copy lands in E3b-3.)
- **Exit-condition**: `capi_surface_gap.sh` gap → 0 (or each residual category has an ADR/debt justifying
  deferral); then close §16.2 [x].

## NEXT (autonomous — surfaces first, docs last; ADR-0156)

- **✅ host_info COMPLETE** (E1 `031e1c40` func/global/table/memory/ref/extern; E2 `faa03492` module/trap;
  E3a `fbbcd4bf` instance). 27 fns, generic accessors in `host_info.zig`, finalizer fired in each `wasm_X_delete`.
  Instance field sits on `runtime.Instance` (zone-legal, import-free; chose field over side-table — simple +
  industry-std). Owned externs only fire the finalizer (borrowed cache-views don't — ref-model reconcile). Gap 67.
- **✅ E3b model — ADR-0158**; **✅ E3b-1 `wasm_X_same`** (9, `7236237c`, new `src/api/ref_base.zig` — entity
  identity `(instance,idx)` for func/global/table/memory, pointer for instance/module/trap/foreign, kind-dispatch
  for extern). Gap 67→58.
- **✅ E3b-2** (global/table/memory `as_ref`/`ref_as`+const, `2474f1c2`): the `objAsRef` helper in `ref_base.zig`
  (cached `ref_view`, payload `@intFromPtr`), `ref_view` fields on the 3 structs, freed in their `_delete`;
  round-trip + lifetime test green. Gap 58→46.
- **✅ E3b-2c** (trap + instance `as_ref`/`ref_as`+const): trap uses `?*handles.Ref` (imported handles into
  trap_surface — pointer-only cycle), instance uses `?*anyopaque` ref_view on the Zone-1 `runtime.Instance`
  (`objAsRefOpaque` helper; freed cast-to-`*Ref` in `wasm_instance_delete`). Round-trip + cache + lifetime test.
  **as_ref/ref_as now COMPLETE for all 9 ref types.** Gap 36→28.
- **§16.2 chunk E3b-3 `wasm_X_copy` — NEXT** (9 fns, ADR-0158): per type — instance-backed func/global/table/
  memory/extern → fresh handle alloc copying `(instance, idx)` with cached views (extern_view/ref_view) NULLED
  (the copy gets its own lazy views; no shared ownership → no double-free); **standalone owners** (Func.host /
  Global.cell / Table.tinst / Memory.minst non-null) → **return null** (full clone needs the per-store registry,
  D-253-D — documented limit, not papered over). module/instance/trap/foreign → fresh handle copy (module: dup
  bytes? no — just the handle fields + null views; trap: dup message; foreign: new Foreign same store). Put in
  `ref_base.zig` (or extern_new for foreign). TDD per type. Then F (tagtype/EH — `TagType`), G (serialize — own ADR).
- After §16.2: §16.3 Zig-API review (reconcile D-267, ADR-0025 Revision), §16.4 CLI あるべき論 review,
  §16.5 dogfooding, §16.6 memory-safety (D-258→D-261), §16.7 docs LAST. Chain; pay debt en route.

## Step 0.7 (next resume)

**No pending ubuntu verification** — E3a code is ubuntu-test-all GREEN at `1dca63f2`; the latest commit
`716c1610` is **docs-only** (ADR-0158 + handover/debt) on top, so no code changed → no kick was issued. The
§16.2 C-API work is portable Zig (non-emit), but C-ABI differs on Linux SysV so test-all cross-run is still
worth a kick per code chunk. If a chunk touches per-arch emit, **D-262 rule**: `run_remote_ubuntu test-all`
(NOT narrow `test`) before discharge (cross-compile ≠ cross-run). **Gate hygiene**: Step-5 Mac =
`bash scripts/mac_gate.sh`. windowsmini exec = phase boundary.

## Deferred / open debt

- **Memory-safety (highest stakes; §16.6 target)** — **D-261** GC-on-JIT conservative rooting has NO
  adversarial test → latent UAF, **blocked on D-258** (JIT-trampoline GC collect trigger not wired). Close
  D-258 then D-261 before calling GC-on-JIT 完成形. Hub: lesson `session-retrospective-structural-risks`.
- **Surface-correctness** — **D-267** (Zig API `Runtime`/`Engine` doc-vs-code drift; §16.3). **D-262** rule
  (x86_64/win64 emit cross-run verification). **D-268** (note) x86_64 homing ≤2 locals — narrower
  parity than arm64=6 (from the compiler-bug-lens review this session).
- **D-210** (blocked-by) cohort root fix recurring at 4 seams (D-142/206/210/245) — root-vs-patch. **D-211**
  precise GcRootMap. **D-266/D-259** notes. **D-257** 10 lesson `Citing` backfill. **D-255** C-API WASI io.
  **D-254** rust 3-OS. **D-253** host_info. **D-251** WASI in AOT. **D-249** win bench. **D-238** x86_64 EH thunk.

## Key refs

- ROADMAP §16 (completion-finalization table: 16.2 C-API audit → 16.3 Zig-API → 16.4 CLI → 16.5 dogfooding
  → 16.6 memory-safety → 16.7 docs; NO release gate). §1.2 (完成形 line, industry-standard surfaces). Phase
  Status widget (15 DONE / 16 IN-PROGRESS). ADR-0156 (endgame redirection); ADR-0025 (Zig surface, D-267
  reconcile target); ADR-0004 (wasm-c-api pin); ADR-0153 (design priority / D-265 campaign).
