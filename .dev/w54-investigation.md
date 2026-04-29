# W54 — `tgo_strops` 2.1× wasmtime gap investigation

Captured: 2026-04-29 evening, ship-overnight session.
Status: investigated, no fix shipped yet.

## What zwasm already does, contrary to the initial hypothesis

The constant-divisor → multiply-high (Hacker's Delight 10-9) peephole
is **already implemented** for both ARM64 (`src/jit.zig:3582-3666`)
and x86_64 (`src/x86.zig`, `tryEmitDivByConstU32`). `known_consts`
tracking in the compile loop sets each vreg's value when an
`OP_CONST32` lands; `emitDiv32` checks the rs2 vreg for a known
constant and falls into `tryEmitDivByConstU32` for non-zero,
non-power-of-two divisors.

Confirmed empirically on `bench/wasm/tgo_string_ops.wasm`:

```
$ ./zig-out/bin/zwasm run --invoke string_ops bench/wasm/tgo_string_ops.wasm \
    --dump-jit=24 10000 | python3 ...
0x0f8: MOVZ X16, #0xCCCD                  ← magic for /10 (low half)
0x0fc: MOVK X16, #0xCCCC, lsl 16          ← magic for /10 (high half)
0x100: UMULL X8, W22, W16                 ← multiply-high
0x104: LSR  X8, X8, #35                   ← extract quotient
```

Three identical 5-instruction sequences for the three `i32.div_u 10`
sites in `string_ops`. **Zero `UDIV` instructions emitted.**

So the original W54 hypothesis ("zwasm doesn't fold constant divisors,
that's why wasmtime is 2× faster") is wrong — the fold is done.

## Where the 2× gap actually lives

### a. Magic constant re-loaded every iteration

Each `i32.div_u 10` inside `digitCount`'s loop body re-emits the full
2-instruction MOVZ+MOVK pair to materialise `0xCCCCCCCD`. Cranelift's
SSA + GVN hoist that load to before the loop, leaving only UMULL+LSR
inside the hot path. With three div sites in `tgo_strops`, the
hoistable cost is **6 instructions per loop iteration**.

### b. mov-heavy RegIR

TinyGo's `digitCount` body in RegIR (function 24, PCs 21..30):

```
[022] add  r8 = r2, r7      ; counter + 1
[023] mov  r2 = r8
[024] const32 r8 = 9
[025] gt_u r8 = r0, r8
[026] mov  r6 = r8           ← cond temp
[027] const32 r8 = 10
[028] div_u r8 = r0, r8      ← 5 instrs after const-folding
[029] mov  r0 = r8
[030] br_if r6 -> pc=21
```

Roughly 9 RegIR instructions, but the JIT emits ~17 ARM64 instructions
because each `mov` becomes an LDR/STR pair against the `regs[]`
spill area when the vreg is not currently held in a physical
register, and the const-divisor sequence is 5 instructions.

Cranelift's SSA collapses every `mov rA = rB` plus the redundant
counter/temp stores into pure register renames. zwasm's linear-scan
regalloc cannot do that without an additional pass.

### c. Single-pass constraint

Both fixes (magic-constant hoist, mov coalescing) require either
loop-aware analysis or a second pass over the RegIR — which the
project's design constraint (single-pass JIT to keep cold start
cheap) excludes by default.

## Realistic single-pass-compatible wins

Ordered by leverage and implementation risk:

1. **Loop-preheader magic hoist.** Extend the existing
   `emitLoopPreHeader` (currently SIMD-only,
   `src/jit.zig:4604`) to scan the loop body for
   `OP_CONST32 K` instructions whose `rd` is later consumed by an
   `OP_DIV_U` / `OP_REM_U`. Allocate a callee-saved register, emit
   the magic constant once before the loop, and have the in-loop
   `emitDiv32` skip its MOVZ+MOVK if the magic is already live.
   Saves ~6 instructions per iteration on `tgo_strops`. Risk:
   medium — needs careful tracking of which scratch register holds
   which magic across the loop body, and the back-edge logic must
   not invalidate the cache.

   **Register layout interaction (caught during the abandoned
   experimental attempt on `develop/w54-magic-hoist-attempt`).**
   The obvious choice for the magic register is `x21`, which is
   only handed out by `vregToPhys` when `reg_count >= 14`. But
   `x21` is *also* the dedicated `inst_ptr` cache slot whenever
   `reg_count <= 13 && has_self_calls` (see `src/jit.zig:1129`,
   field `inst_ptr_cached`). Both states overlap on a real slice
   of the corpus, so the hoist needs to either
   (a) skip the optimisation whenever `inst_ptr_cached` is true
       (smallest, safest patch — gives up the optimisation on
       self-calling functions with ≤13 vregs);
   (b) extend the prologue to reserve an additional callee-saved
       slot (e.g. push `x23` or pick from the unused tail of the
       STP-pair set when `reg_count` is small) and thread that
       through the existing layout machinery (more invasive).
   x86_64 has its own version of this dance (`r13`/`r14` are the
   common candidates); a clean implementation should keep the
   register choice in an arch-specific helper rather than a
   shared constant.

   Tonight's experimental branch was abandoned at this point
   because picking the right safety boundary for the register
   choice is itself a design call worth daylight, not a
   tail-end commit.

2. **`OP_CONST32` reuse across loop back-edges.** Today
   `known_consts` is wiped at every loop header and back-edge.
   For consts whose `rd` is rewritten consistently to the same
   value on every iteration, we could keep the entry alive: emit
   only the first iteration's MOVZ+MOVK, then `nop` (or branch
   over) the const-load on subsequent iterations. Less leverage
   than (1) because OP_CONST32 itself is only 1 instruction —
   what (1) saves is the magic computation that hangs off the
   const, not the const itself. Skip unless (1) lands.

3. **`OP_MOV` coalescing in regalloc.** When a `mov rd = rs1` has
   `rs1` dead-after-this-point, rewrite the producer of `rs1` to
   write directly into `rd`. Needs liveness, which today is
   computed only as `written_vregs`. Substantial regalloc surgery
   — likely a separate W## item, not in scope for tonight.

## What was attempted in this session

- Confirmed the const-divisor fold triggers (above).
- Decoded the JIT'd bytes for func#24 to see the actual emitted
  ARM64. Identified MOVZ+MOVK+UMULL+LSR as the 5-instruction
  per-div-site cost.
- Did **not** attempt the loop-preheader magic hoist or mov
  coalescing — both warrant their own design pass with the
  spec/regalloc tests as the safety net, not an overnight commit.

## Recommended next step

Open a separate `develop/w54-loop-magic-hoist` branch and
prototype the preheader hoist (item 1 above) against a minimal
JIT regression suite first. If `bench/run_bench.sh --quick` shows
≥15 % improvement on `tgo_strops` with no regression elsewhere,
land it. Otherwise revert and capture the dead-end here.

Re-record `bench/runtime_comparison.yaml` at 5 runs / 3 warmup
before claiming a number — the current single-sample values are
useful for ordering but not for absolute targets.
