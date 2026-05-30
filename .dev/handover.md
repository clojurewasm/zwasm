# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — autonomous CORRECTNESS substantially COMPLETE**
  (Phase 9 = DONE 2026-05-24). All 4 proposals verified green except deep/deferred
  residuals (see Active bundle + §10 map).
- **HEAD**: `38bb0e0e` (cyc236, **D-202 PHASE A landed**). Session: cyc232
  cross-module `return_call`; cyc233 EH×TC; cyc234-235 stale-debt correction (ADRs
  0115/0116/0123/0126 Accepted, D-195 discharged, fn-references + gc corpora GREEN);
  **cyc236 D-202 PHASE A** — C-API Linker cross-module func import now uses
  `funcTypeImportCompatible` (subtyping) not exact `sigEqual`; `.30/.48/.50`
  instantiate-FAIL → OK (verified, no regression).
- **10.P: 16 PASS / 8 SKIP / 0 FAIL → close-eligible.**
- **nix**: dev shell active (zig 0.16.0 / wabt / wasmtime).

## Step 0.7 (next resume)

- cyc236 (`38bb0e0e`, D-202 PHASE A) is **ubuntu-verified `OK (HEAD=ebca32b0)`** —
  `.30/.48/.50` instantiate + no regression on x86_64, both arches green. cyc237 =
  docs-only scope-correction → no ubuntu kick. No pending gate, no revert.

## Active bundle

- **Bundle-ID**: D-202-xmodule-finality
- **Cycles-remaining**: ~1-2 (PHASE B is plumbing, not ADR)
- **Continuity-memo**: PHASE A LANDED + ubuntu-verified (`38bb0e0e`) —
  `linker.zig` cross_module_func arm uses `validator.funcTypeImportCompatible`;
  `.30/.48/.50` now instantiate. **PHASE B = the COUNTED RED** (`assert_unlinkable
  pass=3 fail=5`, verified live): `.35/.36/.42/.52/.54` WRONGLY LINK — importer
  declares a FINAL `(func)`, exporter provides an open `(sub (func))` (structurally
  identical `()->()` so subtyping passes; only type-definition FINALITY differs).
  **CORRECTION (cyc237): PHASE B is PLUMBING, NOT §4 ADR-grade.** Finality IS
  retained — `sections.Types` carries `finals: []bool` + `supertypes` (`sections.zig:138-143`);
  zir.FuncType drops it but it need not live there. Recipe: (1) `defineCrossModuleFunc`
  (`linker.zig:309`) — capture the exporter func's typeidx + finality from
  `source_inst` next to `exportFuncSig`; (2) store `source_typeidx`/`source_final`
  in `CrossModuleFuncEntry` (`linker.zig:129`); (3) at the resolve check
  (cross_module_func arm), after `funcTypeImportCompatible`, if the importer's
  declared type is final (`module_types.finals[typeidx]`) require the exporter's
  type to be canonically equal (finality + structure). **OPEN QUESTION (resolve
  FIRST)**: does `source_inst` (exporter Instance) RETAIN its func→typeidx mapping
  + type-section `finals`? `exportFuncSig` returns only the flat sig. If retained →
  straight plumbing; if not → retain/re-decode the exporter's type section.
- **Exit-condition**: `assert_unlinkable fail 5 → 0` (`.35/etc.` rejected), no
  regression to the now-OK `.30/.48/.50`. Both arches, ubuntu-verified.

## Active task — D-202 cross-module type-identity (finality) check  **NEXT**

**cyc234-235 CORRECTION — the debt ledger is STALE and mis-routed the loop 3×
this session.** Ground-truth verification (ADR Status + live corpus, NOT debt
prose):
- ADR-0115 / 0116 / **0123 / 0126 are all ACCEPTED** (0123 "user-delegated
  autonomous flip" 2026-05-28). There is NO pending user ADR flip. Debt rows
  D-195 / D-198 saying "gated on ADR-XXXX Accept" are STALE.
- **function-references corpus GREEN** (ubuntu `return 39/0, trap 4/0,
  invalid 18/0, skip 1`) — **D-195 is DISCHARGED** (typed-funcref ValType
  `0x63/0x64` parser landed, `zir.zig:191`). Debt row stale.
- **GC corpus** GREEN except: `.17` (deferred multi-mechanism rabbit hole) +
  the **D-202 cross-module negatives** (`gc/type-subtyping.30/.48/.50`
  instantiate `SignatureMismatch`, `.35/.36/.42/.52/.54` assert_unlinkable
  wrongly-link).
- Lesson to write: *verify ADR Status + live corpus before trusting a debt
  row's "blocked-by ADR flip" framing* — three candidate chunks this session
  (D-195, the GC ADRs, the gc per-op "migration") were stale/misread.

So Phase 10 is NOT at a bucket-3 user-touchpoint — **D-202 is genuine open
AUTONOMOUS correctness work** (ADRs accepted; impl-only).

Resume Step 1b routes to the Active bundle above for the next step + discharge
D-195 (stale) / reconcile D-198 alongside. NOTE smell: `runner.zig` 1168 lines
(soft WARN) — future test sibling extraction.
**Formal Phase 10 close** (→ Phase 11) is a separate high-value user decision
(close-eligible, 0 FAIL); re-armable at any user signal. NOT a blocker on D-202.

## §10 close map + open

10.P close-eligible (0 FAIL). realworld/p10 matrix 45/55 (0 FAIL, 10 WASI-skip).
10.TC row `[ ]` (emit + spec + realworld clang_musttail + cross-module + EH×TC
all DONE; sole residual = `wasm_of_ocaml` triple-crown capstone, deferred to GC+EH
+toolchain — flip 10.TC `[x]` then). 10.E (EH) + 10.G (GC) are the large open
Phase-10 areas (GC has ADR-gated residuals D-195/D-198/D-202; D-179 wabt bake). gc
.17 funcref-RTT (D-198) deep defer; funcrefs 34/39 (5 RTT-gated); 10 SKIP-WASI →
Phase 11. D-197 (validate-error surfacing); D-209 (>4GiB memory64 offset, payload
u32); D-210 (cross-module proper-tail-call defer — arm64 prologue cohort-save).

## Key refs

- ADR-0066 (cross-module bridge thunk; cohort save/restore); ADR-0112 + Amendment
  2026-05-30 (cross-module tail-call = call-and-return); ADR-0111 (memory64);
  ADR-0114 (EH). `abi_callee_saved_pinning.md` (pinned cohort discipline).
- Lessons: `2026-05-30-{cross-module-tail-call-cohort-asymmetry,
  jit-funcref-tail-call-codegen-recipe, clang-wasm-realworld-toolchain-recipe}`.
  ROADMAP §10; `.dev/phase_log/phase10.md`.
