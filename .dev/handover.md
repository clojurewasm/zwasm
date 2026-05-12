# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9.9 row text (ADR-0056).

## Active state — **Phase 9 extended; k-1-expand-2 landed 2026-05-12**

### One-line state

k-1-expand-2 landed (a9b06a15): NAMES += unreachable /
local_get / local_set / return (4 safe). Mac + OrbStack
`test-spec-wasm-2.0-assert`: **11773 / 0 / 106 bit-identical**
(+233 PASS vs D-092 close). The candidate batch's other 8
names (nop / block / loop / br / br_if / if / labels /
local_tee) exposed 30+ real JIT-side correctness failures
filed as **D-093** (now) — NOT papered over with skip-ADRs.

### Standing reminder for the autonomous loop

**Project tone is `.claude/rules/no_workaround.md`: fix root
causes, never work around.** See
`.dev/lessons/2026-05-12-loop-defers-over-fixes-when-cost-high.md`.
On the next chunk's first obstacle, walk
`extended_challenge.md` Step 1 BEFORE reaching for a filter /
fallback / skip-ADR.

### Next task — D-093 (d-1) implementation: lower.zig unreachable-code tracking

Root cause re-derived this iteration: lower.zig emits dead
ZirInstrs after `br / return / unreachable / br_table`. Liveness
then closes ALL live vregs at the br (single sim_stack pop loop),
the dead i32.add etc. pop from empty + push fresh vregs, end is
liveness-transparent, so the dead-code's top vreg propagates to
post-block consumers as if it were the block's result. Combined
with regalloc reusing dead V_one's slot for the dead-code
V_add, the function returns garbage.

**Preferred fix**: close the gap at the source — `src/ir/lower.zig`
adds `unreachable_at_depth: ?u32` field, set at the br/return/
unreachable emit site, cleared at the matching `end` (when
`block_stack_len` drops below the saved depth) or `else` (else
arm is reachable). While set, `emit()` becomes a no-op AND
openBlock/closeBlock still manage block_stack normally (block
structure is parsed even in dead code per Wasm spec). The
block enter / end / else themselves emit through a dedicated
path that bypasses the unreachable skip so block-frame
bookkeeping stays consistent.

Recipe (~80 LOC in lower.zig):
1. Add `unreachable_at_depth: ?u32 = null` to Lowerer.
2. Wrap `emit()`: if `unreachable_at_depth != null`, skip
   append to `out.instrs`.
3. At dispatch of 0x0C (br) / 0x0D (br_if) — only br closes:
   set `unreachable_at_depth = block_stack_len`. br_if does not.
4. At 0x0E (br_table): set the flag (table also closes the path).
5. At 0x0F (return) / 0x00 (unreachable): set the flag.
6. `openBlock`: still emits + pushes block_stack regardless.
7. `closeBlock`: still emits end + pops block_stack. AFTER pop,
   if `unreachable_at_depth != null and block_stack_len <
   unreachable_at_depth.?`, clear flag.
8. `emitElse`: emit else op normally. Clear flag (else-arm
   reachable).

Regression fixture: add `test/edge_cases/p9/nested_block_value/
br_overshadow.{wat,wasm,expect}` exercising `block (result i32)
... br 0 (i32.const 8) ; i32.add` → expected 9. Per ADR-0020 /
`edge_case_testing.md`.

After (d-1): (d-2) re-add `nop / block / loop / br / br_if /
if / labels / local_tee` to NAMES; verify clean. Residual
fails point to cluster (a/b/c).

Other queued post-D-093 names: `address`, `align`, `br_table`,
`call`, `call_indirect`, `const`, `data`, `elem`, `f32_bitwise`,
`f64_bitwise`, `fac`, `func`, `func_ptrs`, `global`, `load`,
`memory`, `memory_grow`, `memory_size`, `select`, `start`,
`store`, `switch`, `table`, `traps`, `type`, `unwind`.

## Implementation queue (sequential)

Per-stage state of l-1 (all complete + D-092 close landed):

| Stage | Status | What |
|---|---|---|
| l-1a-1..6 | [x] | base extraction + runCorpus + arg-parser + makeJitRuntime hoists |
| l-1b-runner | [x] bff477f5 | new spec_assert_runner_non_simd.zig + test-spec-wasm-2.0-assert |
| l-1b-corpus | [x] 3b92bed6 | regen_spec_2_0_assert.sh + conversions starter |
| l-1b-widen  | [x] 774ae3c8 | 10 cross-type entry helpers + dispatch arms |
| l-1b-nan    | [x] 207330be | scalar NaN-pattern result matcher |
| l-1b-trap-widen | [x] a7bf59d8 | assert_trap f32/f64 arms + i32.wrap_i64 |
| k-1-expand-1 | [x] 894e0e00 | 6 binop helpers + 7 wasts |
| D-091-close | [x] f22acf6c | x86_64 i32.trunc_f64_s lower-bound `-(2^31+1)` + JBE |
| D-092-close | [x] 520246cd+111e232b | x86_64 emitFpMinMax dst==rhs swap; f32+f64 in NAMES |
| k-1-expand-2 | [x] a9b06a15 | 4 safe wasm-2.0 names (unreachable/local_get/local_set/return); D-093 filed for the other 8 |
| D-093 (d) root-cause | [x] this commit | lower.zig + liveness gap analysis; impl recipe filed |
| **D-093 (d-1)** | **NEXT** | lower.zig unreachable-code tracking (~80 LOC + regression fixture) |

Other queued chunks (post-l-1):
- k-1 — Wasm 2.0 non-SIMD wast vendor (~30 files).
- k-2 — SIMD wast vendor (33 files); standalone after l-1.
- m-4c (= D-090) — untyped `.select` non-i32 type inference.
- m-2d — table.grow JIT with allocator-helper infrastructure.
- n-1 — fib2 perf root cause.
- j-3b — SKIP gate real enforcement (last).

## Sandbox quirks + hook scope

- `~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
- OrbStack daemon log-rotation panic — restart via
  `pkill -9 -f OrbStack && open -a OrbStack`.
- Per-chunk 2-host (Mac+OrbStack) per ADR-0049; windowsmini
  reconcile at §9.9 close.

## Open debt — see `.dev/debt.md`

- `now`: **D-093** (wasm-2.0 spec corpus failures cluster (a)/(b)/(c)/(d) — investigation).
- `blocked-by`: D-007/010/016/018/020/021/022/026/028/052(partial)/
  055/057/058/059/062(partial)/065/072/073/074/075/079(ii)/
  081/082/090.

## Reference chain

- `.dev/decisions/0057_spec_assert_runner_factoring.md` — Option B.
- `.dev/decisions/0058_table_ops_jit_design.md` — m-2 cluster.
- `private/notes/p9-99-l-1-spec-assert-survey.md` — factoring survey.
- `private/p9-close-next-session-pickup.md` — broader queue context.
