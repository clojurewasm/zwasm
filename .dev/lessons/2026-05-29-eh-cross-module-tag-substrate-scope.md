# EH cross-module tag imports: substrate scope (D-192 EH clause)

**Date**: 2026-05-29
**Cycle**: 10.X-D192-register cycle 109 (survey)
**Citing**: `06473742` (cycle 109 chore commit)

## What was surveyed

The D-192 register substrate's EH clause: `try_table.1.wasm` imports
`test::e0` (a TAG) + `test::throw` (a func) from `try_table.0` (baked
`register test`). The funcrefs half of D-192 was a small fix
(register-manifest + ref.func global-init). The EH half is a MAJOR,
already-designed (ADR-0114) but UNIMPLEMENTED substrate.

## What was learned (current state — all single-module only)

- **ImportKind enum** (`parse/sections.zig:229`) has func/table/memory/
  global only; `0x04` (tag) is REJECTED at parse (`InvalidFunctype`).
- **Tag exports filtered out at decode** (`sections.zig:606`,
  `if (kind_byte == 4) continue;`) — tag exports never reach
  `exports_storage`, so the runner can't discover/bind them.
- **No `ImportBinding.tag`** (`runtime/instance/import.zig:34`); no
  Linker tag API (`defineTag`/`defineCrossModuleTag`) + no
  `Linker.Payload` tag variant (`zwasm/linker.zig:75`).
- **Runner `.register`** (`spec_assert_runner_wasm_3_0.zig:357`) binds
  memory+func; tag arm absent (and tags are filtered anyway).
- **Tag identity is INDEX-based** (`exception.zig:36` `tag_idx: u32`;
  matched at `interp/mvp.zig:613/733/744` by `==`). Single-module
  throw/catch works by validator-guaranteed in-range index. Cross-
  module throw/catch CANNOT match by index (try_table.0's local idx ≠
  try_table.1's import idx). ADR-0114 D1's `*TagInstance` pointer-
  identity is the designed fix — DEFERRED until now.
- Single-module EH EXECUTES (interp tests pass, `mvp.zig:1160+`); JIT
  throw/throw_ref emit incomplete (`arm64/emit.zig:1172`).

## CORRECTION (cycle 111) — the blocker is PARSE-side, not execution

Cycle 110 landed `ImportKind.tag` and the handover claimed try_table.1/.5
"→ parse+compile+INSTANTIATE". **That claim is FALSE** — it was a stale
run-step-cache misread (see `2026-05-29-zig-run-step-cache-stale-diag.md`).
Running the runner binary DIRECTLY shows try_table.1/.5 STILL
`compile FAIL: ParseFailed`; all 33 try_table.1 asserts fail `NO-CURINST`
(cur_inst_idx null). Only try_table.0 (source) + try_table.2 instantiate.

The real chain, in PARSE order (sections decode sequentially; Type=1
is first, so the earliest blocker wins):

1. **exnref `0x69` as a bare ValType** — try_table.1's Type section (id 1)
   has functype results `(i32, exnref)` = `7f 69`. `init_expr.zig:readValType`
   has arms `0x7F..0x6A` + typed-ref `0x63/0x64` but **no bare `0x69`**.
   `zir.zig:40` confirms deliberate ("0x69 exn … not yet a ValType").
   This fails FIRST, in section 1 — so cycle-110's `ImportKind.tag`
   (section 2) is currently UNREACHABLE for try_table.1 (landed correct
   but premature; exercised only by its unit tests, not the corpus).
2. **Tag SECTION (id 13) decode** — try_table.1 DEFINES 7 tags
   (`0d 0f 07 …` at byte ~0x94), distinct from the tag IMPORT. Needs a
   section decoder (cycle 110 added import + export handling only).
3. `ImportKind.tag` import — DONE cycle 110 (reached after 1+2 clear).
4. try_table / catch-clause immediate decode — `lower.zig` +
   `validator.zig` already have `0x1F`/`0x08`/`0x0A` arms; verify the
   catch-vec decode handles this module's clauses.

Only AFTER parse succeeds do the execution-side steps below apply.

## CORRECTION #2 (cycle 113) — blocker is the VALIDATOR, not parse

Direct-binary probe of `frontendValidate` proved try_table.1 (`24 funcs,
7 tags`) + try_table.2 + try_table.5 ALL **reach the validator** — so
Type(exnref, cyc112) + Import(tag, cyc110) + **Tag section (id 13)** all
decode fine. `decodeTags` ALREADY EXISTS + is wired (`instantiate.zig:218,
934`), so the cyc111 "Tag section decode" hypothesis was ALSO wrong. The
real blocker: **`validate func[5] FAIL StackTypeMismatch`** (func[5] =
`catch-complex-1`). The runner's "ParseFailed" is a lie — `Engine.compile`
collapses validate errors (D-197). The "parse-side" framing held only for
exnref (cyc112); everything else is the **EH validator**.

cyc113 fixed ONE validator bug: `validateCatchVec` blanket-rejected
`catch_ref`(0x01)/`catch_all_ref`(0x03) (stale "exnref absent" rationale);
now structural-matches `tag.params ++ [exnref]` / `[exnref]`. **But this is
ORTHOGONAL to catch-complex-1** — it uses plain `catch`(0x00) over nested
`try_table (result i32)` / `block` / `if`-`else` / `throw` / `br 1`, and
still StackTypeMismatch-es. catch-complex-1 body (type 5 = (i32)->(i32),
from the fv113 probe — record for cyc114 decode):
`02401f7f0100030002401f7f0100020020004504400802052000410146044008030508040b0b41020b0c010b41030b0f0b41040b`
Decode + find where the validator's type stack diverges (candidates: plain
`catch N L` label-type match for a param-carrying tag, try_table-result
flow, or br-to-block-result). NEXT (cyc114).

## Cycle 116 result + the 4-fail tail (cycle 117 probe)

Cycle 116 landed the instantiate-side tag binding (ImportBinding.tag +
Linker defineCrossModuleTag + Instance.tag_exports + rt.tag_param_counts
spanning imported++defined) → **EH return 0→30/34, trap 0→2/2, exception
0→4/4** (`092e990d`). The 4 remaining return fails (cyc117 direct-binary
probe — `[eh117]` on the assert_return invoke/void catch):
1. `catch-imported` — INVOKE-ERR InvokeFailed (cross-module identity)
2. `catch-imported-alias` — INVOKE-ERR InvokeFailed (cross-module identity)
3. `imported-mismatch` — INVOKE-ERR InvokeFailed (cross-module identity)
4. `try-with-param` — VOID-ERR InvokeFailed (try_table-with-PARAM
   execution trap; NOT tag-related — separate interp/codegen issue)

Classes: (1-3) **cross-module tag identity** — the exception is thrown
by the imported `throw` func running in try_table.0's runtime (its tag
index), and try_table.1's catch compares its own import index →
index-based match fails across modules → uncaught → trap. The robust
fix is ADR-0114 `*TagInstance` pointer identity (the import binding's
source `*TagInstance` shared with the catch). Multi-cycle substrate
(`TagInstance` + `rt.tags` + `Exception.tag`→`*TagInstance` + throw/catch
pointer match across the cross-module thunk). (4) try-with-param is a
standalone try_table-param execution trap — likely tractable alone.

## CLOSED (cycle 120) — EH corpus 34/34, D-192 discharged

The full EH cross-module substrate landed cyc110–120 (ADR-0114):
ImportKind.tag (110) → exnref ValType (112) → catch_ref matching (113)
→ imported tags in validator tag-space (114) → block/if param-blocktype
(118) → instantiate-side tag binding + `Instance.tag_exports` +
`rt.tag_param_counts` imported++defined (116) → `*TagInstance` identity
(119) → cross-module exc propagation + caller-frame catch (120).
Result: **exception-handling return 34/34, trap 2/2, exception 4/4,
invalid 7/7 — fully green**. D-192 (both clauses: exnref ValType +
cross-module register/tags) discharged. The two interp gaps that closed
the tail: (1) cross_module thunk moves the uncaught exc from
`source_rt.pending_exception` → caller rt; (2) `callOp` searches the
CURRENT frame's try_table on `Trap.UncaughtException` (the thunk leaves
no frame on rt, unlike a same-module ZIR callee whose frame `invoke`
pops before searching the caller). Remaining EH work = JIT throw/throw_ref
emit (interp path is complete; arm64/emit.zig:1172 stub) — not corpus-
gated (the spec runner uses the interp path).

## Instantiate-binding implementation plan (cycle 115 survey)

UnknownImport for `test::e0` comes from `linker.zig:452`
(`.tag => return error.UnknownImport` stub). The cross-module FUNC path
is the template to mirror (cite for each hop):
- decode export → `exports_storage`+`export_types` (`sections.zig`
  decodeExports; `instance.zig` ExportType; `api/instance.zig:~1291` +
  `exportDescToExternKind:959`)
- runner `.register .func` → `Linker.defineCrossModuleFunc`
  (`linker.zig:267`) → appends `Entry{module,name,Payload.cross_module_func}`
- `Linker.instantiate` import loop (`linker.zig:365` findEntry,
  `387-406` `.func` resolve) → `ImportBinding.func` (`import.zig:34`)
- `instantiate.zig` instantiateRuntime consumes bindings.

**Crux — tag-export discovery**: tag exports are FILTERED at decode
(`sections.zig:620` `if (kind_byte==4) continue`) because `ExternKind`
(c_api, `api/instance.zig:216`) has NO tag variant (ADR-0114 §8:
wasm-c-api lacks it). So tags must NOT flow through `exports_storage`/
`ExternKind` (would break `wasm_instance_exports`). **Decision: Option C
— the runner's `.register` (TEST-side) does a manual tolerant export-
section scan for kind=4 (precedent: `instantiate.zig:282-307`), gets the
tag name + index, calls `Linker.defineCrossModuleTag`.** Keeps the c_api
boundary clean; no ExternKind ABI change; no production tag-export
registry (that'd be the ADR-grade Option B — defer unless a non-test
consumer needs it).

**Substrate gaps**: `TagInstance` does NOT exist (`exception.zig:11`
"eventual *TagInstance"); no `rt.tags`; `ImportBinding` has no `.tag`;
`rt.tag_param_counts` (`instantiate.zig:960`) is DEFINED-only (same
import-offset latent bug the cyc114 validator fix addressed — fix in the
execution cycle). Per ADR-0114 identity = `*TagInstance` pointer
equality, but that's EXECUTION (throw/catch match), SEPARABLE from
instantiate-resolution.

**Cycle 116 = minimal instantiate-OK chain** (defer *TagInstance to the
execution cycle; resolution holds source (inst, tag-index) + the tag's
FuncType for type-match): (1) `ImportBinding.tag` variant
(`import.zig`); (2) `Linker.Payload.cross_module_tag` + a
`defineCrossModuleTag` mirroring `defineCrossModuleFunc` (source tag
discovered by the caller, passed in); (3) `linker.zig:452` `.tag` arm →
type-check + `ImportBinding.tag`; (4) runner `.register` tag-export scan
(Option C) → `defineCrossModuleTag`; (5) instantiate's `.tag` binding
arm (`~1284`, currently `ImportTypeMismatch`) accepts it. Observable:
try_table.1 UnknownImport → instantiate OK (DIRECT binary run). Then
execution cycle: `TagInstance`+`rt.tags`+identity match + the
tag_param_counts import-offset fix.

## How to apply (10.E-xmodule-tags bundle plan, per ADR-0114)

Multi-cycle, each cycle moving a STAGE (avoid on-branch-spike):
1. **`ValType.exnref` + readValType `0x69` arm** (+ the exhaustive-switch
   cascade, à la cycle-110 `ImportKind.tag`) → try_table.1 Type section
   PARSES. **NEXT chunk.**
2. **Tag section (id 13) decoder** → module-defined tags parse.
3. instantiate-side tag binding (`ImportBinding.tag` + instantiate arm +
   checkImportTypeMatches + Linker `defineCrossModuleTag` + runner
   `.register` tag arm) → try_table.1 INSTANTIATES.
4. Runtime `*TagInstance` (ADR-0114 `tag.zig`) + `rt.tags`; imported
   tags resolve to source instance's TagInstance.
5. `Exception.tag_idx` → `*TagInstance`; throw/catch match by pointer →
   cross-module throw/catch MATCHES → corpus asserts pass.
6. JIT throw/throw_ref emit (if corpus needs JIT path).

Steps 1-2 ARE corpus-observable: each flips a try_table.1 module from
`compile FAIL:ParseFailed` toward parse. Verify by running the runner
BINARY DIRECTLY (`zig build` run-step caches stderr — see the cache
lesson), grepping `[wasm-3.0-assert] exception-handling/.* compile FAIL`.

## Related

- ADR-0114 (Exception Handling design — `*TagInstance` D1).
- `.dev/lessons/2026-05-28-funcrefs-tail-error-classes.md` (the
  funcrefs half of D-192; register substrate proven there).
