# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9.9 row text (ADR-0056).

## Active state — **Phase 9 extended; D-093 (d-4) landed 2026-05-13**

### One-line state

D-093 (d-4) landed: per-arch `emitEndIntra` for `.block`
merge now handles three operand-stack shapes — live
fall-through (MOV current top → merge regs), dead
fall-through (top == merge_top_vregs, skip MOVs), and
**stack-emptied dead fall-through** (intervening loop / if
truncate dropped pushed_vregs below entry+arity; grow with
merge_top_vregs so post-block consumers see canonical
result). Pre-d-4 the stack-emptied shape returned
`UnsupportedOp`, blocking `labels.wast:loop1` compile and
likely other multi-level br shapes. Mac + OrbStack
`test-spec-wasm-2.0-assert` unchanged at **11773 / 0 / 106
bit-identical** baseline. Out-of-band: 11 → **10 fails** (=
labels/labels.0.wasm compile UnsupportedOp resolved;
+25 PASS as labels's assert_returns now execute).

### Standing reminder for the autonomous loop

**Project tone is `.claude/rules/no_workaround.md`: fix root
causes, never work around.** See
`.dev/lessons/2026-05-12-loop-defers-over-fixes-when-cost-high.md`.

### Next task — D-093 residual sub-clusters

Residual 10 fails on deferred-name out-of-band run:

- **memory.grow JIT skeleton (cluster (a))** — 5 fails:
  nop:as-memory.grow-{first,last,everywhere}, block:as-
  memory.grow-value, local_tee:as-memory.grow-size. Current
  emit `MOV r32, -1`; needs runtime callout + page-alloc.
- **validator/lower gaps** — 2 fails: if/if.0.wasm
  StackUnderflow (cluster (c)); loop/loop.0.wasm
  AllocationMissing (cluster (b)).
- **br_table forward merge** — 2 fails: br_if:nested-br_
  table-value{,-index}. emitBrTable cases need the same
  capture-or-MOV before each per-case JMP; CMP+JNE-skip's
  disp must extend over per-case MOVs (variable-disp emit
  refactor). Separate chunk.
- **block:break-inner off-by-one** — 1 fail. Root cause
  unlocalised; the d-3-style lower.zig dead-region fix for
  `br N>0` would correct dead-code emission but regressed
  12+ realworld fixtures via the dead-code → emit-pass
  interaction (commit bef86380's prior reverted attempt).

Other queued post-D-093 names: `address`, `align`, `br_table`,
`call`, `call_indirect`, `const`, `data`, `elem`, `f32_bitwise`,
`f64_bitwise`, `fac`, `func`, `func_ptrs`, `global`, `load`,
`memory`, `memory_grow`, `memory_size`, `select`, `start`,
`store`, `switch`, `table`, `traps`, `type`, `unwind`.

## Implementation queue (sequential)

| Stage | Status | What |
|---|---|---|
| l-1b ..  k-1-expand-2 | [x] | base + corpus + 4 safe names |
| D-091/D-092 close | [x] | x86_64 trunc-bound + minmax swap |
| D-093 (d-1) | [x] 444d60e0 | lower.zig unreachable + emit truncation |
| D-093 (d-2) | [x] 708e1bb1 | per-arch block-merge MOV |
| D-093 (d-3) | [x] bef86380 | liveness/regalloc local.tee transparency |
| D-093 (d-4) | [x] (this commit) | block-merge stack-emptied case (labels.0.wasm) |
| **D-093 residual** | **NEXT** | pick from sub-clusters above |

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
- `private/notes/p9-99-l-1-spec-assert-survey.md`.
