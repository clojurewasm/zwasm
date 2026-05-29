# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 116 (`092e990d`) — **cross-module EH tag import
  binding (ADR-0114)**. Mirrored the cross-module FUNC path:
  `ImportBinding.tag` + `Linker.Payload.cross_module_tag` +
  `defineCrossModuleTag` + the linker `.tag` resolve arm;
  `Instance.tag_exports` side-table (tags kept out of
  `exports_storage`/`ExternKind` — c_api clean, Option C); runner
  `.register` tag-export binding; instantiate `.tag` arm +
  `checkImportTypeMatches` (param-count); and `rt.tag_param_counts`
  now spans [imported ++ defined] (was defined-only → fixed a throwOp
  underflow, same import-offset class as cyc114). **exception-handling
  corpus 0→30/34 return, 0→2/2 trap, 0→4/4 exception** (direct-binary
  verified); no regression; no crash.
- Prior: 115 survey/plan (`1a1d3c8f`); 114 imported-tags-in-validator
  (`5fdab0bf`); 113 catch_ref matching; 112 exnref ValType.
- Mac test+lint green cyc116. ubuntu: cyc114 HEAD green
  (`OK (HEAD=b6083018)`); cyc116 kick backgrounded.

## Active bundle

- **Bundle-ID**: 10.E-eh-tail (the 4 remaining EH return fails +
  execution-identity; follows the CLOSED 10.E-xmodule-tags, exit met
  30/34 @ `092e990d`)
- **Cycles-remaining**: ~3
- **Continuity-memo**: 30/34 EH return pass. 4 fails remain (names
  unprobed — candidates: `catch-imported` / `catch-imported-alias`
  (true cross-module: imported func throws, importer catches → needs
  ADR-0114 `*TagInstance` pointer-identity, currently index-based) and
  `throw-catch_ref-param-*` (catch_ref pushes an `exnref` VALUE at
  execution — runtime exnref-value handling). Cross-module tag
  RESOLUTION works (v0.1 param-count match); the tail needs true
  per-tag identity + exnref-value execution. `TagInstance`/`rt.tags`
  still don't exist (deferred from cyc116). **VERIFY by DIRECT binary
  run** (`/tmp/c<NN>` + `/bin/ls -t`; zig-build stderr is cache/lossy
  — D-197 + cache lesson).
- **Exit-condition**: exception-handling return pass ≥ 33/34 (all
  non-text-format cases) OR the 4 fails root-caused + a clear next.

## Active task — cycle 117: probe WHICH 4 EH return asserts fail

Add an EH-gated `[eh.ret]` probe to the runner's assert_return
mismatch/invoke-catch (mvp.zig + runner ~line 472), run the BINARY
DIRECTLY, identify the 4 failing func names + the error/mismatch.
Distinguish: (a) cross-module identity (catch-imported* — index-based
tag match wrong across modules → ADR-0114 `*TagInstance`); (b)
catch_ref exnref-value execution (throw-catch_ref-param-*); (c) nested
(catch-complex). Smallest red per the localized gap; fix the first
tractable one. If (a) → that's the `*TagInstance`+`rt.tags` substrate
(multi-cycle ADR-0114; the cyc115 lesson plan covers it). Revert the
probe after.

## Larger §10 work (later bundles)

- **10.G WasmGC** — corpus baked impl=0%; 384 return-fails. D-197
  (surface validate errors) discharges here.
- **Deferred funcrefs gaps** (post-EH): engine/cli_run
  `resolveFuncrefGlobals`; externref-elem runner arg parsing.
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (cycle-116, verified by DIRECT binary run)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34(pass=30 fail=4) trap=2(pass) invalid=7(pass) exception=4(pass)
   └─ cyc116: cross-module tag binding → 0/34→30/34. 4 fails = tail.
[function-references] return=39(pass=32 fail=1) trap=4(pass) invalid=18(pass)
[gc                 ] return=407(fail) trap=100(fail) invalid=60(pass=55 fail=5)
[multi-memory       ] return=407(pass=387 fail=20) trap=238(pass=237 fail=1)
```

## Open questions / blockers

- D-197 (blocked-by 10.G): `Engine.compile`/`frontendValidate` collapse
  specific errors to ParseFailed/bool — surface via Diagnostic.
- D-192: EH cross-module RESOLUTION proven (30/34). Tail = identity.

## Key refs

- ADR-0114 (EH `*TagInstance`); ADR-0120 (EH payload); ADR-0123
  (typed-ref).
- `.dev/lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`
  (corrections + the instantiate-binding plan) +
  `2026-05-29-zig-run-step-cache-stale-diag.md`.
- ROADMAP §10; `.dev/phase_log/phase10.md`.
