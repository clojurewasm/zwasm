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
- **Cycles-remaining**: ~4 (gap categories C/D/E/F/G; E/G are multi-cycle)
- **Continuity-memo**: §16.2 audit DONE (`.dev/c_api_surface_audit_2026-06-04.md`, D-269) — our `wasm.h` is
  byte-identical to upstream latest, but standard extern fns were unimplemented (link-error for C
  consumers). wasmtime/wasmer ship 100%; wazero ships none. Decision: implement full standard surface (not
  wasmtime's ext headers). Live count: `bash scripts/capi_surface_gap.sh` (**gap 99**, was 129).
  Sequence: ✅A type accessors (6, `c3a979fa`) → ✅B per-type vec ops (24, `2116a18b` — added `PtrVecOps`
  generic owned-ptr-vec helper in types.zig + migrated valtype/externtype/import/export to it; functype/
  globaltype/tabletype/memorytype families + the 4 `_vec_copy`) → **C config (3)** → D val_copy/delete (2)
  → E ref-cast/host_info (~71, D-253) → F tagtype/EH (12) → G module serialize/share (5, own ADR).
  (extern_vec_copy + tagtype_vec deferred to E/F: need wasm_extern_copy / TagType first.)
- **Exit-condition**: `capi_surface_gap.sh` gap → 0 (or each residual category has an ADR/debt justifying
  deferral); then close §16.2 [x].

## NEXT (autonomous — surfaces first, docs last; ADR-0156)

- **§16.2 chunk C (config) — NEXT**: implement `wasm_config_new` / `wasm_config_delete` /
  `wasm_engine_new_with_config` (wasm.h:64-66,80). Standard config is an opaque object: `wasm_config_t`
  is `WASM_DECLARE_OWN`, runtime-specific setters are extensions we don't owe; `engine_new_with_config`
  consumes (takes ownership of) the config and behaves like `engine_new` for our single-tier engine. Survey
  `src/api/instance.zig` (wasm_engine_new/delete) for the Engine wrapper. TDD. Then D (val_copy/val_delete)
  — chain. E (ref/host_info) via D-253; G (serialize) own ADR.
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
