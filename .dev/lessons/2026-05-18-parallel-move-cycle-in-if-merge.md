# Parallel-move cycle in arm64 if-arm multi-value merge

**Citing**: `33a3eee3` (root-cause diagnosis) + `1cd516d7` (D-147 close
via parallel-move resolver)

## Trigger

Multi-value `if (result T0 T1 .. TN)` with N ≥ 3 results where
both arms end with `br 0` carrying values from `*.const`
instructions. LIFO regalloc slot reuse assigns then-arm and
else-arm vregs to overlapping register sets; the merge MOV
cascade in `op_control.zig::captureOrEmitBlockMergeMov`
emits register-to-register MOVs in pushed_vregs order, which
clobbers still-needed source values on cycles.

## Concrete case — `if.wast::break-multi-value`

```wasm
(if (result i32 i32 i64) (local.get 0)
  (then (br 0 (i32.const 18) (i32.const -18) (i64.const 18)))
  (else (br 0 (i32.const -18) (i32.const 18) (i64.const -18))))
```

Then-arm captures merge_top_vregs = (vreg1, vreg2, vreg3) at
home (X9, X10, X11). Else-arm's i32.const -18, i32.const 18,
i64.const -18 are vregs 4, 5, 6 — assigned via LIFO slot
reuse to (X10, X11, X9) (in that order; vreg-6 wraps around
to X9 because slots 0,1,2 are still live on the merge stack
but get freed in else-arm's emit pass).

Sequential merge MOVs:

| Step | MOV                | Before                      | After                         |
|------|--------------------|-----------------------------|-------------------------------|
| 1    | X9  ← X10          | X9=`...FFEE` (i64 -18)      | X9=`...FFEE` (i32 -18, **lost**) |
| 2    | X10 ← X11          | X10=`...FFEE` (i32 -18)     | X10=`...0012` (i32 18)        |
| 3    | X11 ← X9 (current) | X11=`...0012` (i32 18)      | X11=`...FFEE` (X9's _current_ value) |

After step 3, X11 holds `0x00000000FFFFFFEE` — i32 -18 zero-
extended, NOT i64 -18. The marshalReturn MEMORY-class branch
writes `STR X11, [X16, #16]` → buffer slot 2 has the
truncated value. Caller reads `i64:4294967278` instead of
`i64:18446744073709551598`.

## Verification (byte-level dump)

Added probes to `op_const.zig::emitI64Const` and
`op_control.zig::emitMergeMov` (reverted at commit close):

- `i64.const -18` emit: `d29ffdc9 f2bfffe9 f2dfffe9 f2ffffe9`
  — MOVZ Xn=#0xFFEE + 3×MOVK Xn at hw=1,2,3. All X-form.
  Encoder is CORRECT.
- Merge MOV sequence: `X9 ← X10`, `X10 ← X11`, `X11 ← X9`
  in that emit order. emitMergeMov uses X-form ORR. Per-MOV
  emit is CORRECT.
- Bug is at the algorithmic level: parallel-move ignored.

## Why prior chunks missed this

Pre-(b)-e-4, multi-value if-merge was always `skip-impl
multi-result` at the manifest level (no entry helper for
3-result returns existed). The merge MOV cascade for 3+
results was emitted but never observed end-to-end. arg=1
case (`i64.const 18`) PASSED because vreg-6's value had
high 32 bits zero — i32-truncation indistinguishable.
arg=0 case (`i64.const -18`) FAILED because high bits
matter.

## Discharge plan

Implement parallel-move algorithm in
`captureOrEmitBlockMergeMov` (and similar). Reference:
Pereira & Palsberg 2009 "Register allocation by puzzle
solving" or simpler Boissinot 2008. Minimal viable
approach for v2:

1. Pre-pass: for each (src_vreg_i, merge_vreg_i) pair,
   compute `src_phys_reg_i` + `merge_phys_reg_i`.
2. Detect cycles in the (src → merge) permutation graph.
3. For each cycle, allocate a temp scratch — spill all
   sources in the cycle to memory (use outgoing-args
   region when free, else grow frame).
4. Emit per-MOV: LDR Xn from temp slot → STR (via X-form
   MOV / STR Xt) into dest's home.

Cost: doubles MOV count for affected merges (2N MOVs
instead of N). Affected merges are rare (multi-value
if-merge only); on the cold path of cross-module dispatch
+ multi-result returns. Negligible vs correctness.

x86_64 mirror has the same bug by symmetry (regalloc LIFO
slot reuse + sequential merge MOVs in op_control.zig). Fix
parallel arm64 + x86_64 in same chunk.

## Related

- D-147 — the debt row tracking discharge.
- ADR-0069 §Phase 2 — multi-result return ABI that
  surfaced the bug.
- `.claude/rules/single_slot_dual_meaning.md` — related
  axis (LIFO slot reuse forming hazardous aliases).
- v1 (`~/Documents/MyProducts/zwasm/`) — likely has its
  own version of this code; read but don't copy.
- Cranelift `cranelift/codegen/src/regalloc2/moves.rs` —
  textbook parallel-move algorithm for reference.
