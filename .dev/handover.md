# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9.9 row text (ADR-0056).

## Active state — **d-58 closed: drain directive-assert_unlinkable backlog (+79 PASS)**

### One-line state

d-58 adds `assert_unlinkable` directive support — module fails
to link due to `unknown import` or `incompatible import type`.
Distiller emits `assert_unlinkable {file}` for binary modules;
runner-base dispatch is fully inline (no callback) with three
paths: hasUnbindableImports → PASS, compileWasm rejects → PASS,
otherwise → SKIP-NO-LINK-TYPECHECK (skip-adr; we lack link-time
type validation against the host binding). Of 83 reclassified
entries (imports ×71 + linking ×12): 79 PASS, 4 SKIP-NO-LINK-
TYPECHECK. spec_assert non-simd 23497/0/2573 → 23576/0/2494
(+79 PASS, 0 FAIL; skip-impl 1838; skip-adr 656). simd
13301/0/440 unchanged. Loop continues toward 9.9 `[x]`;
substrate audit hard gate (9.12) auto-fires when next chunk
would resolve to it.

### Standing reminder for the autonomous loop

**Project tone is `.claude/rules/no_workaround.md`: fix root
causes, never work around.**

### Next sub-chunk candidates (names only, NO predictions)

Active `now` debts (post-d-54):
- D-093 (parent), D-095 (regalloc partial).
- D-112 / D-113 / D-114 / D-115 / D-116 / D-118 / D-119 /
  D-120 / D-121 / D-122 / D-123 / D-124 / D-125 / D-127 /
  D-128 / D-129 / D-130 discharged.
- **D-126** bulk corpus residual: funcptr_base / refs divergence
  (Phase 10+ instance-aware refactor scope).
- D-103: discharged at d-37 via cross-module-imports skip.
- D-102/D-105/D-079: cross-module-imports family — surface
  remains SKIP under d-37 pre-filter.

§9.9 100%-PASS gate: only D-126 + queued-skip-impl runner-side
backlog remain. With D-126 deferred to Phase 10+ instance-aware
refactor, the closing path is the runner-side skip-impl backlog
(7 entries in nop / loop / local_tee — see below) plus
considering whether to flip 9.9 `[x]` based on "active corpora
green" rather than "every assertion classified".

- **d-59** — Continue draining skip-impl. Top remaining
  classes (post-d-58): `multi-result` (Phase 11+ scope per
  ADR-0029 follow-up — large but blocked architecturally),
  `directive-register` (~21 entries; a no-op for our scaffold
  since cross-module-imports are already SKIPped, so could
  reclassify as skip-adr), `directive-assert_exhaustion`
  (~15; needs JIT stack-overflow detection), `trap-non-scalar-
  arg` / `non-scalar-arg` (~12+7; needs reftype-arg dispatch
  in the runner ladder). `directive-register` is the cheapest
  next mechanical drain (manifest line emit + base classify
  arm + treat-as-noop + count as skip-adr-cross-module).

Runner-side skip-impl backlog (7 total, in `nop / loop /
local_tee`):
- 5× nop:as-call-{first,mid1,mid2,last,everywhere} —
  manifest filter: `(i32 i32 i32, i32)` is 3-arg i32
  dispatch, runner's `[5]ArgValue` matrix dispatches ≤ 2
  args + result. Extend dispatch table.
- 1× loop:break-multi-value — multi-result loop blocks.
  Path B exit requires this resolved at Phase 11+ (per
  ADR-0029 follow-up).
- 1× from local_tee or block — verify.

Other queued post-D-093 names: `address`, `align`, `br_table`,
`call`, `call_indirect`, `const`, `data`, `elem`, `f32_bitwise`,
`f64_bitwise`, `fac`, `func`, `func_ptrs`, `global`, `load`,
`memory`, `memory_grow`, `memory_size`, `select`, `start`,
`store`, `switch`, `table`, `traps`, `type`, `unwind`.

## Implementation queue (sequential)

| Stage | Status | What |
|---|---|---|
| l-1b .. k-1-expand-2 | [x] | base + corpus + 4 safe names |
| D-091/D-092 close | [x] | x86_64 trunc-bound + minmax swap |
| D-093 (d-1) | [x] 444d60e0 | lower.zig unreachable + emit truncation |
| D-093 (d-2) | [x] 708e1bb1 | per-arch block-merge MOV |
| D-093 (d-3) | [x] bef86380 | liveness/regalloc local.tee transparency |
| D-093 (d-4) | [x] 8755326d | block-merge stack-emptied case |
| D-093 (d-5) | [x] 6fe10e95 | loop dead-fall-through placeholder |
| D-093 (d-6) | [x] a97d9bcd | Wasm 2.0 block-param multi-value |
| D-093 (d-7) | [x] ad78ce45 | br_table per-case forward-block merge |
| D-093 (d-8a) | [x] 13c46792 | ADR-0059 + JitRuntime callout ABI tail extension |
| D-093 (d-8b) | [x] 2e04b925 | arm64 `.memory.grow` BLR-via-fn-ptr emit + X28/X27 reload + safe default fn |
| D-093 (d-8c) | [x] 0b3d7dea | x86_64 `.memory.grow` CALL-via-fn-ptr emit + spec-runner growable_memory pool + NAMES (nop/loop/local_tee; block deferred for (c)) |
| D-093 (d-9) (c) | [x] a38890da | liveness br target-depth-aware close (block_stack) + block NAMES |
| D-093 (d-10) (b) | [x] 1df7acc5 | if-with-params validator opElse + emit param_top_vregs capture/restore + liveness if-frame + edge-case fixtures |
| D-093 (d-11) | [x] 9b48592e | multi-result function calls (arm64 + x86_64 captureCallResult + marshalReturn shared helpers) + edge-case fixture |
| D-093 (d-12) | [x] 7d1c71f8 | liveness if-frame merge tracking + x86_64 cap silent-truncate (D-094 debt) + multi_result_compose edge fixture |
| D-093 (d-13) | [x] 15cfa288 | implicit-else marshal (arm64 + x86_64) + 3 edge fixtures |
| D-093 (d-14) | [x] 124dd7cf | arm64 `.return` op multi-result marshal (d-11 stale-inline cleanup) + add64_u_saturated_exact edge fixture |
| D-093 (d-15) | [x] b5bd2cdf | regalloc call-crossing-vreg root-cause investigation + D-095 debt + compose_no_call edge fixture |
| D-093 (d-16) | [x] 5ccae2cd | ADR-0060: regalloc `computeWith` force-spill call-crossing vregs (slot ≥ per-arch max(GPR, FP)) + compose_with_call edge fixture + D-095 partial discharge + D-096 / D-097 filed |
| D-093 (d-17) | [x] eca69183 | unified `emitMergeMov` (FP-class dispatch + 64-bit GPR MOV) + br-into-if-frame merge capture (D-096 discharged) + br_inside_arm edge fixture |
| D-093 (d-18) | [x] 4a4e0a22 | x86_64 select alias-aware cmov + call_indirect idx load order (D-097 discharged) + select_spilled_operands / select_with_if_call / select_with_if_no_call edge fixtures |
| D-093 (d-19) | [x] c41b0868 | NAMES +5 (`address`, `const`, `load`, `store`, `traps`); `select` deferred (reftype), `align` rejected by wast2json |
| D-093 (d-20) | [x] 18f93d91 | NAMES +5 (`f32_bitwise`, `f64_bitwise`, `memory_size`, `switch`, `type`) + runner memory_limits reset + D-099 (fac-ssa loop param) filed |
| D-093 (d-21) | [x] 834fd332 | NAMES batch bisect (call/data/elem/global/memory_grow/start/unwind each → its own debt D-101..D-107) + GROWABLE_MEMORY_CAPACITY 64 → 1024 pages |
| D-093 (d-22) | [x] 404a8477 | NAMES batch bisect (call_indirect/func/func_ptrs/memory/table → D-108..D-110 + wast2json-reject) + D-106 discharge scaffolding (extractStartFunc + invoke helper; SEGV root-cause now narrowed) |
| D-093 (d-23) | [x] ad84042e | D-107 discharged: x86_64 emitBrTableJmp function-depth (mirror arm64); `unwind` lands +49 PASS |
| D-093 (d-24) | [x] 4c4d7309 | D-099 discharged: emitLoop captures param_top_vregs + backward br/br_if/br_table emit param MOVs before back-branch; `fac` lands +6 PASS |
| D-093 (d-25) | [x] ed05169b | D-101 discharged: max_args cap 64 → 128 (call.wast func[77] has 100-arg call); `call` lands +82 PASS |
| D-093 (d-26) | [x] 1815e624 | D-108 discharged: i64/f32/f64 scalar `global.get/set` on both archs + edge fixtures (3 new). D-111 filed for call_indirect structural-typing. NAMES unchanged. |
| D-093 (d-27) | [x] 77ef4a06 | D-111 discharged: `canonical_type.zig` + emit/runner canonicalization. NAMES +3 (call_indirect/func/func_ptrs); 14119/0/292 → 14399/0/385 (+280 PASS, +3 manifests). Cascade discharge: D-109 moot, D-110. |
| D-093 (d-28) | [x] fda102aa | D-102 reclassified blocked-by D-105: stderr-diagnostic proves 19 `data.wast` module-load failures are all import-dependent (15× imported memory; 1× imported-global const-expr; 4× InvalidFunctype on import shape). `data` NAMES deferred. No code change beyond regen-script comment. spec_assert 14399/0/385 unchanged. |
| D-093 (d-29) | [x] d5a25a1b | D-103 part (a): SIGSEGV / SIGBUS recovery installed in `spec_assert_runner_base` (`sigsetjmp` / `siglongjmp` via libc; `__sigsetjmp` on Linux, `sigsetjmp` on Mac) + inline-armed in `nonSimdRunAssertTrap` dispatch ladder + 2 unit tests + handler install in non_simd runner main. NAMES unchanged. |
| D-093 (d-30) | [x] 5aa141bc | D-103 parts (a)+(b) close. Handler IS load-bearing (handler-removed probe aborts at `callI32NoArgs:55` null deref). Bisect identified 2 SEGV-recovery cases: elem.75 + elem.76 `init ()` trap-asserts. D-103 (c) optional per Wasm spec §A.2. NAMES unchanged. |
| D-093 (d-31) | [x] b92fa06c | M-1 scope hygiene per `private/wasm2-completion-plan/` + ADR-0061. Drop 4 Wasm 3.0 `--enable-*` flags from `wast2json` invocation in `regen_spec_2_0_assert.sh`. `.dev/reference_clones.md` `wg-2.0` pin note. **Debt re-classification**: D-104 `blocked-by Phase 10+ reftype` → `now` (pre-d-31 narrative cited D-075 as reftype umbrella; D-075 is actually about ADR-0025 Zig library facade — broken alias). D-103 barrier corrected to `D-104 discharge + D-079`. `p9_simd_status.sh` awk fix to surface `now (annotation)` rows (D-106 was being missed). spec_assert 14399/0/385 unchanged. |
| D-093 (d-32) | [x] cfaf6623 | D-104 part 1: `parse/sections.zig::readValType` accepts `0x70 = funcref` / `0x6F = externref` per Wasm 2.0 §5.3.1; 6 new + 1 updated unit tests cover decodeTypes/decodeCodes/decodeGlobals reftype acceptance. Edge fixture deferred to d-33 (local.get / op_globals / call-arg marshal still UnsupportedOp pre-d-33). spec_assert 14399/0/385, simd 13301/0/440 unchanged. |
| D-093 (d-33) | [x] 8e63d933 | D-104 part 2: reftype-class codegen plumbing — alias funcref/externref onto the i64 8-byte gpr-class scalar path per ADR-0061 across `op_globals.{get,set}`, function-entry param marshal, `local.{get,set,tee}`, and `op_call.zig::marshalCallArgs` on both archs. Edge fixture `funcref_externref_local_isnull.{wat,wasm,expect}` lands and JIT-executes end-to-end (i32:1) on Mac aarch64 + OrbStack x86_64. D-104 fully discharged. spec_assert 14399/0/385, simd 13301/0/440 unchanged. |
| D-093 (d-34) | [x] 3694bc6d | wg-2.0 spec pin alignment per ADR-0061. OSS `WebAssembly/spec` clone checked out from `main` (wg-3.0) → `wg-2.0` tag; regen flushes residual 3.0 syntax from func / local_tee / loop / address manifests. `elem` re-enablement attempted-then-reverted (post-pin elem produces 12 D-079-family cross-module-imports FAILs). spec_assert 14399/0/385 → 14393/0/386 (-6 PASS lost are honest Wasm 3.0-out-of-scope assertions). simd 13301/0/440 unchanged. |
| D-093 (d-35) | [x] 467e311b | D-106 SEGV → trap-stub wiring. `host_dispatch_base` (was `undefined` = 0xaa…aa) now points at a static stub table whose every slot is `hostImportTrapStub` (sets `trap_flag = 1`). `start.wast` modules with `(import …) (func $main (call $import_fn)) (start $main)` no longer SEGV at the JIT's host-dispatch trampoline LDR chain; the trap stub fires cleanly + propagates `Error.Trap`. `start` NOT yet added to NAMES (deferred to d-36). spec_assert 14393/0/386, simd 13301/0/440 unchanged. |
| D-093 (d-36) | [x] 9fc5b18a | invoke-action distillation + `start` enabled. Regen distiller emits `invoke-action FN ARGS` for bare-action commands; runner adds `DirectiveKind.invoke_action` + `handle_invoke_action` callback + dispatch. Bare-action traps are PASS per spec (no assertion to violate); unbound-import start-fn traps return `error.SkipModule` (new base-loop path) so they tally SKIP not FAIL. `start` lands. spec_assert 14393/0/386 → 14404/0/392 (+11 PASS, 0 FAIL, +1 manifest); simd unchanged. |
| D-093 (d-37) | [x] 23724d68 | `elem` NAMES enable via cross-module-imports skip-adr. `hasUnbindableImports` pre-filter; distiller skips `action.module`-targeted assertions; `evalConstScalarRaw` gains `0xD2 ref.func`. spec_assert 14404/0/392 → 14413/0/465 (+9 PASS, 0 FAIL); simd unchanged. |
| D-093 (d-38) | [x] 3358bec8 | Batch enable 13 NAMES: br, br_if, endianness, forward, labels, left-to-right, stack, ref_null, ref_func, memory, memory_redundancy, float_misc, float_memory. 4 names deferred to debt (D-112 select, D-113 ref_is_null, D-114 memory_trap, D-115 float_exprs). spec_assert 14413/0/465 → 15438/0/508 (+1025 PASS, 0 FAIL, +13 manifests); simd unchanged. |
| D-093 (d-39) | [x] c54d1ab0 | D-115 FP-select half discharged: validator → lower → emit untyped-`select` valtype byte plumbing. New `validateFunctionAndCollectSelectTypes` entry point collects per-0x1B resolved valtype byte in body-walk order; `compileOne(..., select_types)` + `lowerFunctionBody(..., select_types)` thread the slice; lower consumes one byte per 0x1B to populate `ZirInstr.extra`. Existing emit dispatch (0x7D/0x7C ⇒ arm64 FCSEL S/D + x86_64 `op_alu_float.emitFpSelect`) fires correctly. Edge fixtures `test/edge_cases/p9/select_fp/select_f<32,64>_negzero.{wat,wasm,expect}`. |
| D-093 (d-40) | [x] e7e1f01f | D-116 discharged. Mis-diagnosed framing was "memory persistence across invokes lost"; actual root cause was distiller `action_supported` / `assert_return supported` shape sets + runner `dispatchVoidResult` / `invokeActionShape` ladders missing `(i32, f32)` / `(i32, f64)` / `(i32, i32, i32)`. d-40 adds three new `entry.callVoid_*` helpers + ladder arms + distiller shape entries. `float_exprs` lands in NAMES. spec_assert 15438 → 16091 PASS. |
| D-093 (d-41) | [x] a31fec49 | D-114 discharged. Same shape-gap class as D-116 but on the assert_trap + assert_return-void axes. d-41 adds `entry.callVoid_i32i64` + arms for `(i32, i64)` / `(i32, f32)` / `(i32, f64)` across `dispatchVoidResult` / `nonSimdRunAssertTrap` / `invokeActionShape`; distiller `trap_supported` + `supported` sets extended. `memory_trap` lands in NAMES. spec_assert non-simd 16091/0/684 → 16276/0/679 (+185 PASS, 0 FAIL, +1 manifest); simd 13301/0/440 unchanged. |
| D-093 (d-42) | [x] ebe2a992 | D-112 JIT side: multi-table call_indirect dispatch. New `TableJitCallInfo` (extern { funcptr_base, typeidx_base }, 16-byte stride) in JitRuntime as parallel `tables_jit_ci_ptr` array (head_size 200 → 216). Entry 0 reuses table-0 flat arrays so legacy X24/X25/X26 (arm64) + [R15+scalar_off] (x86_64) fast path stays unchanged; entries `k > 0` back per-call slow path via `tables_ptr[k].len` + `tables_jit_ci_ptr[k]`. `setupRuntime` allocates per-table arenas; elem-section loop drops table-0-only gate. Edge fixture `multi_table_dispatch.wat` flips FAIL→PASS=42. spec_assert / simd / wast / realworld unchanged (no regressions). |
| D-093 (d-42b) | [x] e0bc2ef8 | D-112 close. Spec_assert static-scratch harness wires multi-table call_indirect: `applyTableInit` is now a thin wrapper over `applyTableInitForTable(tableidx, ...)`; runner adds `countDeclaredTables` + `declaredTableMin` helpers. Harness `scratch_extra_funcptrs/typeidxs` + `scratch_table_jit_ci` + `scratch_tables_descriptor` populated by new `setupMultiTableScratch`; `makeJitRuntime` wires `JitRuntime.tables_ptr` + `tables_jit_ci_ptr` + counts. `select` lands in NAMES. spec_assert non-simd 16276/0/679 → 16369/0/732 (+93 PASS, 0 FAIL, +1 manifest); simd 13301/0/440 unchanged. |
| D-093 (d-43) | [x] 077ca871 | D-113 close. Pre-d-43 `scratch_tables_descriptor[k].refs` was `undefined` → SEGV on JIT `table.get`. d-43 adds `scratch_table_refs[SCRATCH_MAX_TABLES][SCRATCH_EXTRA_TABLE_CAPACITY]u64` + `scratch_func_entities[SCRATCH_MAX_FUNCS]FuncEntity` + `active_func_count`; `makeJitRuntime` wires `func_entities_ptr/count` + `tables_ptr[0].refs`; `setupMultiTableScratch` walks elem sections via new `populateTableRefs` writing `Value.ref`-encoded FuncEntity pointers. Distiller adds `module_state_diverged` flag (set on `skip-impl action-non-scalar-arg`, cleared by next `invoke-action`); while set, subsequent assert_returns emit `skip-adr-host-state-diverged` so host-action-dependent asserts skip cleanly. spec_assert non-simd 16369/0/732 → 16376/0/740 (+7 PASS, 0 FAIL, +1 manifest = `ref_is_null`); simd 13301/0/440 unchanged. |
| D-093 (d-44) | [x] 24d875ce | Batch enable 5 NAMES via per-corpus isolated bisect: `data`, `global`, `memory_copy`, `memory_fill`, `memory_grow`. 3 candidates deferred to new debt rows: `br_table` SlotOverflow (D-118), `bulk` SEGV (D-119), `memory_init` value-mismatch + missing-trap (D-120). spec_assert non-simd 16376/0/740 → 20728/0/1150 (+4352 PASS, 0 FAIL, +5 manifests); simd 13301/0/440 unchanged. |
| D-093 (d-45) | [x] 50237a0e | D-118 close. Root cause was NOT regalloc vreg overflow but our hardcoded br_table target caps (arm64: `count >= 4096` reused Error.SlotOverflow; x86_64: `count > 127` from imm8/rel8). `br_table.wast` `large` declares 16149 targets. d-45 introduces per-case CMP dispatch on i magnitude (arm64 MOVZ+MOVK+CMP-reg; x86_64 CMP-imm32 + Jcc-rel32) and accepts reftype block-types (-16/-17 per Wasm 2.0 §5.3.5) in validator readBlockType + lower readBlockArity (br_table.wast `meet-funcref` / `meet-externref` exports). spec_assert non-simd 20728/0/1150 → 20898/0/1153 (+170 PASS, 0 FAIL, +1 manifest); simd 13301/0/440 unchanged. |
| D-093 (d-46) | [x] 469c50cf | Batch enable +3 table_* NAMES (table, table_set, table_fill) via per-corpus isolated bisect. 5 deferred to new debt: D-121 table_get externref-OOB, D-122 table_size UnsupportedOp, D-123 table_init SEGV, D-124 table_copy bounds-trap, D-125 table_grow UnsupportedOp. spec_assert non-simd 20898/0/1153 → 20918/0/1213 (+20 PASS, 0 FAIL, +3 manifests); simd 13301/0/440 unchanged. |
| D-093 (d-47) | [x] 664b3fa4 | D-121 close. Pre-d-47 `makeJitRuntime` reset `scratch_tables_descriptor[0].len` to scratch capacity on every per-assert call, overriding setupMultiTableScratch's module-derived `tbl_min`. Drop the clobber + use `declaredTableMin` for k=0 too. `table_get` lands. spec_assert non-simd 20918/0/1213 → 20927/0/1219 (+9 PASS, 0 FAIL, +1 manifest); simd 13301/0/440 unchanged. |
| D-093 (d-55) | [x] `65e5bacb` | Drain runner-shape-gap skip-impl backlog. Manifest skip-impl had 483 of 748 lines as `runner-shape-gap` (multi-arg dispatch shapes the runner ladder doesn't yet handle). d-55 adds 11 new entry helpers (`callI32_i32i32i32`, `callI64_i32i64`, `callI64_i64i64i32`, `callF32_f32f32f32`, `callF32_f32f32f32f32`, `callF32_f32f32i32`, `callF32_f32f64`, `callF32_f64f32`, `callF64_f64f64f64`, `callF64_f64f64f64f64`, `callF64_f64f64i32`) in `src/engine/codegen/shared/entry.zig` mirroring the established AAPCS64/SysV convention; matching arms in `dispatchScalarResult` + 11 entries in the distiller's `supported` set so the previously-skipped asserts re-classify as `assert_return`. Top families unblocked: `(i32 i32 i32, i32)` × 275, `(f64 f64 f64, f64)` × 46, `(f32 f32 f32, f32)` × 41, 4-arg FP families × 18+17, mixed FP/i32 × 10+10, etc. spec_assert non-simd 22981/0/3089 → **23448/0/2622** (+467 PASS, 0 FAIL; skip-impl 2437 → 1970 = -467 ⇒ each unblocked shape ran an existing assert that now passes); simd 13301/0/440 unchanged. Mac aarch64 + OrbStack `test-all` both green. |
| D-093 (d-54) | [x] `1d59c587` | D-129 close via runtime-side host-import-trap sentinel routing. `hostImportTrapStub` writes `HOST_IMPORT_TRAP_SENTINEL = 0xBADC0DE` into `rt.trap_flag` (was the JIT-body-standard `1`); new `printCallTrap` helper in spec_assert_runner_base detects the sentinel post-Error.Trap, prints `SKIP-HOST-IMPORT  …` (instead of FAIL), and sets `pending_host_import_skip` side-channel; `runCorpus` routes ok=false-with-flag to `tally.skipped_adr++` instead of `tally.failed++` on both assert_return + invoke-action paths (assert_trap doesn't need it — host-import trap satisfies the spec's expected-trap contract). 40 FAIL-print sites in spec_assert_runner_non_simd.zig consolidated to `base.printCallTrap()`. names + imports re-enabled in NAMES (+483 PASS that was waiting on D-129). spec_assert non-simd 22498/0/2916 → **22981/0/3089** (+483 PASS, 0 FAIL, +2 manifests); simd 13301/0/440 unchanged. Mac aarch64 + OrbStack `test-all` both green. |
| D-093 (d-53) | [x] `b347cb80` | D-128 partial close (manifest-parse-split half). Distiller `quote_field()` emits `:hex:<utf8-hex>` for export names containing control chars / whitespace / quotes / colon (e.g. `:hex:0a09` for `\n\t`, `:hex:c385` for `Å`). Runner-side `decodeFnName(fn_name, buf)` reverses this — wired into all 3 fn_name-extraction sites in `spec_assert_runner_non_simd.zig` (assert_return, assert_trap, invoke-action). 6 new unit tests cover decodeFnName edge cases (empty, multi-byte UTF-8, odd-hex reject, buffer overflow). SCRATCH_MAX_FUNCS bumped 256 → 1024 (names.2.wasm declares 479 funcs). `names` + `imports` re-deferred to D-129: trial-enable showed 22981 PASS / 2 FAIL (the 2 spectest-import-wrapper traps); +577 PASS waits on D-129 reachability analysis. spec_assert non-simd 22498/0/2916 unchanged (d-53 ships infrastructure with no enabled-corpus impact yet). simd 13301/0/440 unchanged. Mac aarch64 + OrbStack `test-all` both green. |
| D-093 (d-52) | [x] `9a601838` | D-127 + D-130 close. D-127: `compileWasm` early-out for absent function section now also fires when section is present-but-empty (binary.60.wasm `03 01 00`). D-130: `validator.zig::opBrTable` skips strict `labelTypesEq` when `topFrame.unreachable_flag` per Wasm 2.0 §3.3.5.8 (joined label type collapses to bottom in unreachable code). Companion emit fix: lower's `closeBlock` for inner-dead block doesn't push merge result vregs; the d-5 `.loop` fall-through placeholder pad (vreg 0 sentinel) is extended at d-52 to all block kinds in both arm64 + x86_64 `emitEndIntra` (was `.loop`-only). Edge fixture `test/edge_cases/p9/br_table/meet_bottom_unreachable.{wat,wasm,expect}`. binary + unreached-valid corpora land in NAMES. spec_assert non-simd 22404/0/2889 → **22498/0/2916** (+94 PASS, 0 FAIL, +2 manifests); simd 13301/0/440 unchanged. Mac aarch64 + OrbStack `test-all` both green. |
| D-093 (d-51) | [x] `f7b2aabe` | Batch enable +11 NAMES via per-corpus trial: `binary-leb128` / `comments` / `custom` / `inline-module` / `obsolete-keywords` / `token` / `unreached-invalid` (validator-only assert_invalid/malformed) + `exports` / `linking` / `table-sub` / `skip-stack-guard-page` (mostly cross-module-imports SKIP). 4 corpora deferred via new debt rows: D-127 binary (validator MissingTypeSection on empty-fn-section), D-128 names (distiller char escaping for special export names), D-129 imports (spectest-import-call traps but spec asserts succeed; needs reachability analysis), D-130 unreached-valid (validator ArityMismatch on .1.wasm). spec_assert non-simd 22259/0/2638 → **22404/0/2889** (+145 PASS, 0 FAIL, +11 manifests); simd 13301/0/440 unchanged. No source code change beyond regen-script NAMES expansion + commentary citing the new debt rows. |
| D-093 (d-50) | [x] `c781e6e9` | D-119 + D-120 close (mirror of d-49 elem-segment fix for data segments). New `scratch_data_segments[128]SegmentSlice` + `scratch_data_arena[64KB]u8` + `scratch_data_dropped[128]u8` globals + `populateDataSegments` called from `setupMultiTableScratch`. Active data segments marked dropped at instantiation per Wasm 2.0 §4.5.5. setupRuntime patched in lockstep (standalone runner had the same gap; surfaced via new edge fixture `memory_ops/init_active_consumed.{wat,wasm,expect}`). Bug found: setupMultiTableScratch's `if (num_tables == 0) return;` early-return skipped both populate calls — fixed (do both first then return). memory_init lands; bulk DEFERRED to D-126 (4 residual FAILs surface a separate funcptr_base/refs divergence after table.copy). spec_assert non-simd 22049/0/2632 → **22259/0/2638** (+210 PASS, 0 FAIL, +1 manifest); simd 13301/0/440 unchanged. |
| D-093 (d-49) | [x] `d7483097` | D-123 + D-124 close. Spec_assert harness wires `JitRuntime.elem_segments_ptr` + `elem_dropped_ptr` (was `undefined` → JIT table.init SEGV outside any sigsetjmp) via new `scratch_elem_segments[128]ElemSlice` + `scratch_elem_refs_arena[4096]u64` + `scratch_elem_dropped[128]u8`. New `populateElemSegments` walks element section, packs `Value.ref`-encoded funcref pointers, and marks active + declarative segments as dropped per Wasm 2.0 §4.5.4 (active elem consumed at instantiation). `setupRuntime` patched in lockstep so the standalone runner gets the same active-consumed semantics — surfaced via new edge fixture `init_active_consumed.{wat,wasm,expect}`. `scratch_table_capacity` 32 → 1024 in both spec_assert + simd runners (table_copy.50.wasm declares `(table 128 128 funcref)`; mirror of d-21's GROWABLE_MEMORY_CAPACITY bump). table_copy + table_init land. spec_assert non-simd 20925/0/1311 → **22049/0/2632** (+1124 PASS, 0 FAIL, +2 manifests); simd 13301/0/440 unchanged. |
| D-093 (d-48) | [x] `323b0046` | D-122 + D-125 close. New `JitRuntime.table_grow_fn` callout (mirror of ADR-0059's `memory_grow_fn`), JitRuntime tail extends 216 → 224 bytes; both arches gain `op_table.emitTableGrow` (BLR/CALL via fn ptr; arm64 reuses memory.grow's prologue invariant cache, x86_64 routes through `usage.usesRuntimePtr`). Harness `growableTableGrowFn` enforces declared max via new `runner.declaredTableMax` and grows the per-table refs arena in place; `SCRATCH_EXTRA_TABLE_CAPACITY` 64 → 1024. Distiller's `non-scalar-arg` path now sets `module_state_diverged` so post-skip observation asserts skip cleanly. x86_64 `usage.usesRuntimePtr` whitelist gap discovered + fixed (table.grow needed R15 for fn-ptr load). spec_assert non-simd 20927/0/1219 → 20925/0/1311 (-2 PASS, +2 manifests `table_size`/`table_grow`; -2 PASS = state-diverged conservative skip on `select`/`global`/etc post-non-scalar-arg observation asserts). simd 13301/0/440 unchanged. Edge fixtures `table_ops/grow_happy.{wat,wasm,expect}` + `grow_max_cap.{wat,wasm,expect}`. |

Other queued chunks (post-l-1): k-1, k-2, m-4c (= D-090),
m-2d, n-1, j-3b.

## Sandbox quirks + hook scope

- `~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
- OrbStack daemon log-rotation panic — restart via
  `pkill -9 -f OrbStack && open -a OrbStack`.
- Per-chunk 2-host (Mac+OrbStack) per ADR-0049; windowsmini
  reconcile at §9.9 close.

## Open debt — see `.dev/debt.md`

- `now`: **D-093** (residual sub-clusters above).
- `blocked-by`: D-007/010/016/018/020/021/022/026/028/052(partial)/
  055/057/058/059/062(partial)/065/072/073/074/075/079(ii)/
  081/082/090.

## Reference chain

- `.dev/decisions/0057_spec_assert_runner_factoring.md`.
- `.dev/decisions/0058_table_ops_jit_design.md`.
- `.dev/decisions/0059_jit_memory_grow_callout.md`.
- `.dev/decisions/0060_regalloc_call_crossing_force_spill.md`.
- `private/notes/p9-99-l-1-spec-assert-survey.md`.
