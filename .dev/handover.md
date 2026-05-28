# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24).
- **HEAD**: cycle 113 (`c968689c`) — `catch_ref`/`catch_all_ref`
  structural label-type matching in `validateCatchVec` (the stale
  "tighten once exnref lands" TODO; exnref landed cyc112). Unit-tested
  + lint green + no spec-corpus regression.
- **Re-correction (cyc113)**: the EH blocker is the **VALIDATOR**, not
  parse. Direct-binary probe of `frontendValidate` shows try_table.1
  (`24 funcs,7 tags`) + try_table.2 + try_table.5 ALL **reach the
  validator** — Type(exnref)+Import(tag)+Tag-section(id 13, `decodeTags`
  already exists+wired) all decode. try_table.1 fails at
  `validate func[5]=catch-complex-1 StackTypeMismatch`. The runner's
  "ParseFailed" is a lie (`Engine.compile` collapses validate errors →
  D-197). cyc113's catch_ref fix is correct but ORTHOGONAL (catch-
  complex-1 uses plain `catch` 0x00, not catch_ref).
- Prior: 112 exnref ValType (`64315609`); 111 stale-cache correction
  (`f5884d31`); 110 ImportKind.tag.
- Mac test+lint green cyc113. ubuntu: cyc112 HEAD green
  (`OK (HEAD=7e7c51d5)`); cyc113 kick backgrounded.

## Active bundle

- **Bundle-ID**: 10.E-xmodule-tags (EH cross-module, ADR-0114)
- **Cycles-remaining**: ~5
- **Continuity-memo**: PARSE fully works for try_table.1 (exnref cyc112
  + ImportKind.tag cyc110 + decodeTags pre-existing). Blocker chain is
  now VALIDATOR → instantiate → execution. Validator: `catch-complex-1`
  (func[5]) StackTypeMismatch over nested `try_table (result i32)`/
  `block`/`if`/`throw`/`br 1` with plain `catch`(0x00) on param-carrying
  tags. Body bytes + candidate causes in
  `lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`
  (CORRECTION #2). **VERIFY by running the runner BINARY DIRECTLY**
  (`/tmp/c<NN>` cache-dir + `/bin/ls -t` binary; zig-build stderr is
  cache/lossy — D-197 + cache lesson).
- **Exit-condition**: exception-handling try_table corpus return pass
  ≥ 5/34 (currently 0/34).

## Active task — cycle 114: catch-complex-1 validator StackTypeMismatch

Decode catch-complex-1's body (bytes in the lesson) + find where the
validator's type stack diverges. Smallest red test: a hand-rolled
`validateFunctionWithTags` body mirroring the diverging fragment
(likely a plain `catch N L` whose tag has params + the label type, OR
the `try_table (result i32)` body/`br`-to-block-result flow). Confirm
red (StackTypeMismatch), fix the validator, green. Observable: rerun
the runner BINARY DIRECTLY; try_table.1 func[5] should pass (advance to
the next failing func or to instantiate). If the fix is an ADR-grade
control-frame/label-type semantics change (§4-adjacent) file ADR first;
a localized type-flow bug fix is routine. Temp-probe `frontendValidate`
(EH-gated `std.debug.print`, revert after) to re-localize as needed.

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

## Spec runner observable (cycle-113, verified by DIRECT binary run)

```
[memory64           ] return=337 trap=205 invalid=83  (all pass)
[tail-call          ] return=71  trap=7   invalid=24  (all pass)
[exception-handling ] return=34(fail34) trap=2(fail2) invalid=7(pass) exception=4(fail4)
   └─ try_table.0/.2 instantiate; .1/.5 reach validator then
      catch-complex-1 (func[5]) StackTypeMismatch → compile FAIL.
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
