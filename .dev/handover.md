# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9.9 row text (ADR-0056).

## Active state — **Phase 9 extended; D-093 (d-8b) landed 2026-05-13**

### One-line state

D-093 (d-8b) landed: arm64 `.memory.grow` emit rewritten to call
through `JitRuntime.memory_grow_fn` per ADR-0059 — marshal delta
into W1, restore X0 = X19, `LDR X16, [X19, #memory_grow_fn_off];
BLR X16`, then reload X28/X27 (vm_base, mem_limit) from the
JitRuntime tail. Result captured from W0 via slot-aware dispatch
(mirror of `op_call.captureCallResult.i32`). Field default is
`defaultMemoryGrowReject` (returns -1 unconditionally — matches
the pre-ADR-0059 skeleton's spec-conformant "host refuses growth"
behaviour) so all existing JitRuntime constructors are SEGV-safe
without explicit wiring. Mac + OrbStack `test-spec-wasm-2.0-assert`
bit-identical at **11773 / 0 / 106** baseline. d-8c (x86_64 emit
+ growable spec-runner host_state impl + NAMES expansion to
nop/block/loop/local_tee) NEXT.

### Standing reminder for the autonomous loop

**Project tone is `.claude/rules/no_workaround.md`: fix root
causes, never work around.**

### Next task — D-093 residual sub-clusters

Residual 8 fails on deferred-name out-of-band run:

- **memory.grow JIT skeleton (cluster (a))** — 6 fails:
  nop:as-memory.grow-{first,last,everywhere},
  block:as-memory.grow-value, loop:as-memory.grow-value,
  local_tee:as-memory.grow-size. Needs runtime callout.
- **if-with-params validator + emit gap** — 1 fail:
  if/if.0.wasm StackUnderflow. `if.wast:param` (func[42])
  is `(if (param i32) (result i32) ...)` — validator's
  `opElse` doesn't re-push params for else-arm (Wasm spec
  §3.4.4 mandate). Fixing validator alone surfaces an
  emit-side gap: liveness treats `.else` as transparent,
  so the param vreg's range ends in then-arm — the else-
  arm re-read clobbers via regalloc slot reuse. Full fix
  requires (a) validator opElse re-push, (b) emit Label
  param_top_vregs capture at emitIf + restore at
  emitElse, (c) liveness if-frame stack to extend param
  vreg ranges across both arms. Multi-file chunk.
- **block:break-inner off-by-one** — 1 fail. Root cause
  unlocalised.

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
| D-093 (d-8b) | [x] (this commit) | arm64 `.memory.grow` BLR-via-fn-ptr emit + X28/X27 reload + safe default fn |
| **D-093 (d-8c)** | **NEXT** | x86_64 `.memory.grow` CALL-via-fn-ptr emit + growable spec-runner host_state + NAMES expansion (nop/block/loop/local_tee) + verify |

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
