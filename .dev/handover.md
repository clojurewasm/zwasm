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
  ✅E1+E2+E3a host_info COMPLETE — all 9 ref types (`031e1c40`/`faa03492`/`fbbcd4bf`; 27 fns) → **E3b:
  ref-cast/same/copy (~44, ref-model ADR)** → F tagtype/EH (12) → G serialize/share (5, own ADR). A–E3a DONE
  (gap 67); E3b/F/G design-gated. (extern_vec_copy + tagtype_vec also deferred: need wasm_extern_copy / TagType.)
- **Exit-condition**: `capi_surface_gap.sh` gap → 0 (or each residual category has an ADR/debt justifying
  deferral); then close §16.2 [x].

## NEXT (autonomous — surfaces first, docs last; ADR-0156)

- **✅ host_info COMPLETE** (E1 `031e1c40` func/global/table/memory/ref/extern; E2 `faa03492` module/trap;
  E3a `fbbcd4bf` instance). 27 fns, generic accessors in `host_info.zig`, finalizer fired in each `wasm_X_delete`.
  Instance field sits on `runtime.Instance` (zone-legal, import-free; chose field over side-table — simple +
  industry-std). Owned externs only fire the finalizer (borrowed cache-views don't — ref-model reconcile). Gap 67.
- **✅ E3b model decided — ADR-0158** (survey-grounded): extend the foreign/func ref-view pattern — `as_ref`
  caches a borrowed `ref_view` Ref with payload `@intFromPtr(handle)`, `ref_as_X` = `@ptrFromInt` (caller-
  guarantees-type, polymorphic payload); `same` = entity identity `(instance, idx)` not pointer (exports return
  fresh handles); `copy` = instance-backed shallow clone, standalone-owner → null + D-253-D (registry needed).
- **§16.2 chunk E3b implementation — NEXT** (guided by ADR-0158, TDD, ~44 fns): **E3b-1 `wasm_X_same`** (9 —
  entity-identity helper over (instance,idx) for func/global/table/memory + pointer for instance/module/trap/
  foreign + compound for extern; self-contained, do first) → **E3b-2 `wasm_X_as_ref`/`wasm_ref_as_X`(+const)**
  (add `ref_view` fields to global/table/memory/extern/instance/module/trap structs; round-trip tests) →
  **E3b-3 `wasm_X_copy`** (instance-backed clone / standalone-null). Then F (tagtype/EH — needs `TagType`),
  G (serialize — own ADR).
- After §16.2: §16.3 Zig-API review (reconcile D-267, ADR-0025 Revision), §16.4 CLI あるべき論 review,
  §16.5 dogfooding, §16.6 memory-safety (D-258→D-261), §16.7 docs LAST. Chain; pay debt en route.

## Step 0.7 (next resume)

**No pending ubuntu verification** — the D-265 campaign's last emit commit `e8b7ad10` is ubuntu-test-all
GREEN (`/tmp/ubuntu.log`, HEAD=33fe020a). The §16 surface-audit / docs work is mostly non-emit; if a chunk
touches per-arch emit, **D-262 rule**: `run_remote_ubuntu test-all` (NOT narrow `test`) before discharge
(cross-compile ≠ cross-run; lesson `cross-compile-is-not-cross-run`). **Gate hygiene**: Step-5 Mac =
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
