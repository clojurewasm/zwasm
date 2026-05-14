# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9.9 row text (ADR-0056).

## Active state — **Phase 9 extended; D-093 (d-33) D-104 part 2 reftype-class codegen plumbing 2026-05-14**

### One-line state

D-093 (d-33) discharges D-104 part 2 by aliasing reftype
(funcref / externref) onto the i64 8-byte gpr-class scalar
path across all codegen sites per ADR-0061. Six site
categories landed in one chunk (shared "8-byte gpr class
slot" semantic): (1) `op_globals.{get,set}` reftype routes
through `emitI64Global*` on both archs; (2) arm64 + x86_64
function-entry param-marshal accepts reftype; (3) arm64 +
x86_64 `local.{get,set,tee}` reftype shares the i64 X-form /
R64 path; (4) arm64 + x86_64 `op_call.zig::marshalCallArgs`
reftype rides the i64 marshal arm; (5) cap value for reftype
locals lifted 16380 → 32760 (X-form imm12 cap); (6) `select`
reftype was already covered (m-4a in handover history).
Edge fixture `test/edge_cases/p9/global_reftype/
funcref_externref_local_isnull.{wat,wasm,expect}` lands —
parses + JIT-executes end-to-end on Mac aarch64 and OrbStack
x86_64 (i32:1). spec_assert 14399/0/385, simd 13301/0/440 —
both unchanged (no NAMES flipped this cycle; d-34 = re-enable
`elem` in NAMES to consume the new reftype budget).

### Standing reminder for the autonomous loop

**Project tone is `.claude/rules/no_workaround.md`: fix root
causes, never work around.**

### Next task — d-34 re-enable elem in NAMES

Active `now` debts (post-d-33):
- D-093 (parent), D-095 (regalloc partial), D-106 (start-fn
  invoke SEGV).
- D-104 fully discharged (parts 1 + 2 landed).
- D-103: blocked-by D-079 (down from D-104 + D-079 pre-d-33).
- D-102/D-105/D-079: cross-module-imports family (Phase 10+
  Instance-aware refactor — REPORT d-36+).

- **d-34 NEXT** — re-enable `elem` in NAMES (was skipped at
  d-21 bisect on D-103 + D-104 grounds; both are now
  discharged or have non-elem barriers). Path: edit
  `scripts/regen_spec_2_0_assert.sh` SUPPORTED dict to flip
  `elem` from SKIP-OUT back into NAMES, re-bake the manifest,
  re-run `zig build test-spec-wasm-2.0-assert`. Expected
  outcome from handover historical narrative: 22 reftype +
  global reftype fixtures unblock; ~12 residual fails remain
  attributable to D-079 cross-module reftype-import shape.
  Surfaces real numbers — the live status script is the
  authority post-flip.
- **d-35** — D-106 start-fn invoke SEGV (0xaa…aa undefined-mem
  pattern at prologue load).
- **d-36+** — Instance-aware refactor (multi-chunk; Phase 9 ↔
  Phase 10 transition prep per ADR-0061 alternatives).
- **d-34** — re-enable `elem` in NAMES, verify post-d-32+d-33
  the FAIL count dropped from 34 (= 22 reftype-fixed + 12
  remaining D-079).
- **d-35** — D-106 start-fn invoke SEGV (0xaa…aa undefined-mem
  pattern at prologue load; ~30 LOC).
- **d-36+** — Instance-aware refactor (multi-chunk; Phase 9 ↔
  Phase 10 transition prep per ADR-0061 alternatives).

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
| D-093 (d-33) | [x] (this commit) | D-104 part 2: reftype-class codegen plumbing — alias funcref/externref onto the i64 8-byte gpr-class scalar path per ADR-0061 across `op_globals.{get,set}`, function-entry param marshal, `local.{get,set,tee}`, and `op_call.zig::marshalCallArgs` on both archs. Edge fixture `funcref_externref_local_isnull.{wat,wasm,expect}` lands and JIT-executes end-to-end (i32:1) on Mac aarch64 + OrbStack x86_64. D-104 fully discharged. spec_assert 14399/0/385, simd 13301/0/440 unchanged (d-34 = `elem` NAMES flip consumes the new budget). |
| **D-093 (d-34)** | **NEXT** | Re-enable `elem` in `regen_spec_2_0_assert.sh` SUPPORTED dict (was skipped at d-21 bisect on D-103 + D-104 grounds — both now discharged or with non-elem barriers). Re-bake manifest + re-run spec assertion gate. Surfaces real number deltas from new reftype path. |

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
