# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9.9 row text (ADR-0056).

## Active state — **Phase 9 extended; D-093 (d-16) regalloc force-spill landed 2026-05-14**

### One-line state

D-093 (d-16) discharges D-095 partially via ADR-0060: regalloc
`computeWith` force-spills call-crossing vregs (def_pc <
call_pc < last_use_pc for `.call` / `.call_indirect` /
`.@"memory.grow"`) by minting slot ids ≥
`max(allocatable_gprs.len, allocatable_v_regs.len)` (arm64 = 13,
x86_64 = 6). compile.zig passes the per-arch threshold. The
existing spill emit path carries the value through the call.
Edge fixture `compose_with_call.wasm = 1` PASS validates on
both hosts. `if` deferred from NAMES until D-097 (x86_64
if-emit walkthrough) clears the 8 x86_64-specific residuals
that surfaced when `if` was briefly enabled. Mac + OrbStack
`test-all` 0 fail (test-spec-wasm-2.0-assert 12262/0/143
maintained; simd 13301/0/440 unchanged).

### Standing reminder for the autonomous loop

**Project tone is `.claude/rules/no_workaround.md`: fix root
causes, never work around.**

### Next task — D-097 x86_64 if-emit walkthrough then re-enable `if`

Clusters (a) + (b) + (c) of D-093 ALL DISCHARGED. Multi-result
func calls (d-11) DISCHARGED. D-095 regalloc call-crossing
discharged-partial via ADR-0060 (d-16). Remaining gating §9.9
close:

- **D-097 (d-17 NEXT)** — x86_64 if-emit walkthrough. Enabling
  `if` in NAMES surfaces 8 x86_64-specific fails (Mac arm64
  green at 2 fails = D-096 only): `as-select-mid/last`,
  `as-call_indirect-{first,mid,last}`, `as-compare-operand
  (0,0)`, `as-compare-operands`. Same regalloc output on both
  archs (call-crossing vregs force-spilled per d-16). Suggests
  the x86_64 emit has a parallel branch missing in
  `op_control.zig` (if-end merge MOV) or `op_call.zig`
  (post-call result-capture with force-spilled vregs).
  Bisect via single-fixture disassembly compared with arm64.
- **D-096 (d-18)** — `param-break` / `params-break` (br
  inside if-arm). No calls; pre-d-16 already failing. Suspect
  `emitBr`'s if-target merge-capture handling. ~30 LOC fix
  + edge fixture.

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
| D-093 (d-16) | [x] (this commit) | ADR-0060: regalloc `computeWith` force-spill call-crossing vregs (slot ≥ per-arch max(GPR, FP)) + compose_with_call edge fixture + D-095 partial discharge + D-096 / D-097 filed |
| **D-093 (d-17)** | **NEXT** | discharge D-097: x86_64 if-emit walkthrough (single-fixture disassembly vs arm64); re-enable `if` in NAMES when clear |
| D-093 (d-18) | queued | discharge D-096: br-inside-if-arm `param-break` / `params-break` (arm64) — ~30 LOC fix + edge fixture |

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
