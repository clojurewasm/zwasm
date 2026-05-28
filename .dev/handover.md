# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 115 (`<this commit>`) — SURVEY + plan for the
  instantiate-side cross-module tag binding (the `UnknownImport`
  blocker). Mapped the cross-module FUNC path as the template + the
  exact 7 sites; decided Option C (runner-side manual tag-export scan,
  test-side) over the ADR-grade tag-export registry — keeps the c_api
  `ExternKind` boundary clean. Full plan in the EH lesson. No code this
  cycle (complex coupled ADR-0114 substrate; planning de-risks it).
- Prior: 114 imported-tags-in-validator-tag-space (`5fdab0bf`,
  try_table.1/.5 → VALIDATE); 113 catch_ref/catch_all_ref (`c968689c`);
  112 exnref ValType (`64315609`).
- Mac green cyc114. ubuntu: cyc114 HEAD green (`OK (HEAD=b6083018)`).
  Cycle 115 = docs-only (survey/plan).

## Active bundle

- **Bundle-ID**: 10.E-xmodule-tags (EH cross-module, ADR-0114)
- **Cycles-remaining**: ~4 (parse+validate done + planned; instantiate-
  binding impl next (cyc116), then execution-identity)
- **Continuity-memo**: PARSE (cyc112) + VALIDATE (cyc114) pass for
  try_table.1/.5. Blocker chain: ~~parse~~ → ~~validate~~ →
  **INSTANTIATE (UnknownImport)** → execution. The exact 7-site
  implementation plan (mirror the cross-module FUNC path; Option C
  runner-side tag-export scan; defer `*TagInstance` to execution) is in
  the EH lesson §"Instantiate-binding implementation plan". **VERIFY by
  running the runner BINARY DIRECTLY** (`/tmp/c<NN>` cache-dir +
  `/bin/ls -t`; zig-build stderr is cache/lossy — D-197 + cache lesson).
- **Exit-condition**: exception-handling try_table corpus return pass
  ≥ 5/34 (currently 0/34).

## Active task — cycle 116: implement the minimal instantiate-OK tag chain

Pure execution of the recorded plan (EH lesson §"Instantiate-binding
implementation plan"). Mirror the cross-module FUNC path. 5 pieces,
defer `*TagInstance` identity to the execution cycle (resolution holds
source (inst, tag-index) + the tag's FuncType for type-match):
1. `ImportBinding.tag` variant (`src/runtime/instance/import.zig:34`).
2. `Linker.Payload.cross_module_tag` + `defineCrossModuleTag` mirroring
   `defineCrossModuleFunc` (`linker.zig:267`); caller passes the source
   tag (inst + index + sig).
3. `linker.zig:452` `.tag` arm → findEntry + type-check → `ImportBinding.tag`.
4. Runner `.register` tag-export scan (Option C, manual kind=4 scan like
   `instantiate.zig:282-307`) → `defineCrossModuleTag`
   (`spec_assert_runner_wasm_3_0.zig:357`).
5. instantiate's `.tag` binding arm (`instantiate.zig:~1284`, currently
   `ImportTypeMismatch`) accepts it.
Red: try_table.1 `UnknownImport` → instantiate OK (DIRECT binary run) +
a Linker unit test for `defineCrossModuleTag`/resolve. Deviation watch:
these are routine func-path mirrors under Accepted ADR-0114 — no new
ADR (Option C is test-side; Option B registry deferred). Then execution
cycle: `TagInstance`+`rt.tags`+identity + the `rt.tag_param_counts`
import-offset fix (`instantiate.zig:960`, same class as cyc114).

## Larger §10 work (later bundles)

- **10.E EH execution** (post-validate) — instantiate tag binding +
  `*TagInstance` identity (ADR-0114) + JIT throw/throw_ref emit.
- **10.G WasmGC** — corpus baked impl=0%; 384 return-fails. D-197
  (surface validate errors) discharges here (the 384-fail surface makes
  the plumbing worth it). Many gc/* still ParseFailed (shared ref/GC
  decode).
- **Deferred funcrefs gaps** (post-EH): engine/cli_run
  `resolveFuncrefGlobals`; externref-elem runner arg parsing.
- **10.P close gate** — user touchpoint by construction.

## Spec runner observable (cycle-114, verified by DIRECT binary run)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass) exception=4(fail4)
   └─ try_table.0/.2 instantiate; .1/.5 now VALIDATE (cyc114) then
      instantiate FAIL: UnknownImport (imported tag unbound).
[function-references] return=39(pass=32 fail=1) trap=4(pass) invalid=18(pass)
[gc                 ] return=407(fail) trap=100(fail) invalid=60(pass=55 fail=5)
[multi-memory       ] return=407(pass=387 fail=20) trap=238(pass=237 fail=1)
```

## Open questions / blockers

- D-197 (now-ish, blocked-by 10.G): `Engine.compile`/`frontendValidate`
  collapse specific errors to ParseFailed/bool — surface via Diagnostic.
- D-192: EH clause = active bundle 10.E (validator → instantiate → exec).

## Key refs

- ADR-0114 (EH `*TagInstance`); ADR-0120 (EH payload); ADR-0123
  (typed-ref).
- `.dev/lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`
  (3 corrections: parse→validator) + `2026-05-29-zig-run-step-cache-stale-diag.md`.
- ROADMAP §10; `.dev/phase_log/phase10.md`.
