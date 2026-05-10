# regalloc LIFO slot-reuse + in-place V-reg modify ops require alias-safety

> Lesson surfaced 2026-05-11 in §9.9 / 9.9-g-9 D-066 discharge.
> Citing: commit `<pending-sha>`.

## Observation

NEON (and x86 SSE) op-handlers that follow the shape

```
MOV V<result>.16B, V<src>.16B          ; copy src into result
INPLACE V<result>.<lane>, V<other>     ; modify result in place reading other
```

silently miscompile when regalloc's LIFO slot-reuse assigns
`V<result> == V<other>`. The MOV clobbers V<other>'s contents
before the in-place op reads it. The first INPLACE op then
operates on stale data.

Concrete trigger: `simd_lane.137`'s
`(v128, v128) → v128` `f64x2.extract_lane → f64x2.replace_lane`
chain. At the replace_lane site, the extracted-lane vreg dies
and its V-reg is the LIFO-top free slot, which is then handed
back to the new replace_lane result vreg. The two coincide; the
copy MOV erases the new-lane content; INS reads zero (the src's
content). Symptom: `f64x2_extract_lane(<v128>) → got
00…00, expected a0c8eb85f3cce17f0000000000000000`.

## Why this is re-derivable but worth remembering

`bug_fix_survey.md` requires grepping for "the shape" before
fixing. The shape here is **two-step "copy-then-in-place-modify
that reads a third V-reg"**. Once you see one (replace_lane_fp),
two more sites in the same file have the identical risk:

- `emitV128Bitselect` (op_simd.zig:622): MOV mask_v ← c_v then
  BSL mask_v, v1_v, v2_v. Bug if `mask_v == v1_v` or `v2_v`.
- `emitV128Select` (op_simd.zig:542): DUP mask_v from cond_w then
  BSL mask_v, val1_v, val2_v. Same bug shape.

Neither site currently fails any test because the `simd_bitwise`
+ `select` corpora's only result-comparing bitselect/select
assertions either (a) are SKIP'd with `v128-param-pending`
(awaiting 3-v128-param runner dispatch) or (b) source v128 inputs
via `v128.const` const-pool which produces a different vreg
liveness shape.

Status: tracked separately as a debt entry once the runner
exercises the alias case; the discharge is the same scratch-V31
stash pattern applied here to `emitV128ReplaceLaneFp`.

## The fix pattern

```zig
var ins_src: u5 = new_lane_v;
if (src_v != result_v and new_lane_v == result_v) {
    try gpr.writeU32(..., inst_neon.encMovV16B(simd_scratch_v, new_lane_v));
    ins_src = simd_scratch_v;
}
if (src_v != result_v) {
    try gpr.writeU32(..., inst_neon.encMovV16B(result_v, src_v));
}
try gpr.writeU32(..., encoder(result_v, lane, ins_src));
```

`simd_scratch_v` (V31 — popcnt scratch outside any popcnt
sequence) is the canonical project escape used for similar
3-source synthesis idioms (pmin/pmax, ne).

## Future-self checklist

When writing or reviewing a NEON / SSE handler that does

1. `MOV result, src` (copy-then-modify), AND
2. The next op writes `result` while reading another live V-reg,

ask: **can regalloc assign result the same physical V-reg as the
other-read V-reg?** The answer is YES whenever (a) the other-read
vreg dies at the def site of result (typical for stack-pop +
push patterns) AND (b) regalloc's free-pool ordering puts it at
the LIFO top. If both hold, add the V31-stash alias-safety shim.
