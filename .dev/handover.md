# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9.9 row text (ADR-0056).

## Active state — **Phase 9 extended; D-093 (d-10) landed 2026-05-13**

### One-line state

D-093 (d-10) landed: `(if (param T1..TK) (result U1..UN))`
support across validator + arm64/x86_64 emit + liveness. Per
Wasm spec §3.4.4: validator `opElse` re-pushes start (param)
types so else-arm sees the same shape as then-arm; emit
captures top param_arity vregs at `emitIf` into Label's new
`param_top_vregs[8]`; `emitElse` truncates to entry_base +
re-pushes captured params; `emitEndIntra` else_open path adds
single-arity merge for the param-bearing case (mirrors the
existing 2*arity path for param=0). Liveness `block_stack`
upgrades from u32 to Frame struct tracking `(entry_depth,
param_arity, is_if, param_vregs)`; `.else` truncates sim_stack
to entry_depth + re-pushes captured params so regalloc keeps
the param slots live across both arms. Mac + OrbStack
`test-spec-wasm-2.0-assert` 12262 / 0 / 143 unchanged
(`if` deferred from NAMES until multi-result func call support
lands — `add64_u_{with_carry,saturated}` in if.0.wasm exposes
2-result returns + 2-result captures). simd unchanged
13301/0/440. Two regression fixtures under
`test/edge_cases/p9/if/` (`param_then.wasm = 3`,
`param_else.wasm = -1`).

### Standing reminder for the autonomous loop

**Project tone is `.claude/rules/no_workaround.md`: fix root
causes, never work around.**

### Next task — D-093 multi-result func call + runner-skip-impl

Clusters (a) + (b) + (c) of D-093 ALL DISCHARGED at d-8c + d-9 +
d-10. Remaining gating §9.9 close:

- **Multi-result function calls (d-11)** — `if.wast:add64_u_*`
  funcs declare `(result i64 i32)` (Wasm 2.0 multi-value).
  Currently `op_call.captureCallResult` rejects `>1` results
  via `Error.UnsupportedOp`; function-end marshal in
  emit.zig only writes `results[0]`. Implement:
  (a) captureCallResult extends to N results: walk
  `callee_sig.results`, map each to AAPCS64 result reg
  (X0/X1/... for GPR class, V0/V1/... for FP), push N
  vregs. (b) Function-end marshal: walk `func.sig.results`,
  MOV each home reg → AAPCS64 result reg. (c) x86_64
  mirrors via SysV (RAX/RDX for GPR, XMM0/XMM1 for FP) +
  Win64. (d) Add `if` to NAMES + verify.

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
| D-093 (d-10) (b) | [x] (this commit) | if-with-params validator opElse + emit param_top_vregs capture/restore + liveness if-frame + edge-case fixtures |
| **D-093 (d-11)** | **NEXT** | multi-result function calls (captureCallResult + function-end marshal) + add `if` to NAMES |

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
- `private/notes/p9-99-l-1-spec-assert-survey.md`.
