# u64-padded FuncRet layout aligns with the JIT epilogue's per-slot register convention

Citing: §9.9-II chunks (b)-1 .. (b)-5 (commits `c254912b` ..
`e25353ae`); ADR-0065 Cat II.

## Observation

Multi-result entry helpers (`callXXyy_<args>` → `FuncRet_<results>`)
require the Zig `extern struct` return ABI to align with the JIT
epilogue's `marshalFunctionReturn` register-assignment convention.
The two conventions are NOT identical by default — Zig follows the
host C ABI struct-return rules (AAPCS64 §6.8.2 / SysV §3.2.3) which
pack small (≤ 8-byte) structs into a single register, while the JIT
epilogue assigns sequential X-regs for GPR-class results and
sequential V-regs for FP-class results.

The (b)-2 PoC demonstrated:
- `FuncRet_i32i32 = extern struct { r0: u32, r1: u32 }` (8 bytes) →
  Zig reads ONLY X0 (packed `r0 = X0[0..32]`, `r1 = X0[32..64]`).
  JIT writes W0 = r0 (zero-ext X0, high 32 = 0), W1 = r1
  (separate X1). Zig reads `r1 = 0` ✗.
- `FuncRet_i64i32 = extern struct { r0: u64, r1: u32 }` (16 bytes
  with 4-byte tail-padding) → Zig packs into X0+X1 register pair.
  r0 in X0 (u64), r1 in X1 (low 32). Matches JIT W0/X0 + W1/X1
  convention by coincidence ✓.

The (b)-3 fix established the convention:

> **Each `FuncRet_*` field is u64-padded so the struct totals
> ≥ 16 bytes**, forcing AAPCS64 / SysV to return via the X0+X1
> (RAX+RDX on SysV) register pair instead of packing two
> fields into a single register. Each `r_i: u64` holds the
> smaller-width result zero-extended (matches W-form
> zero-extension the JIT epilogue's `MOV Wi, Wj` produces).

`FuncRet_i32i32` became `extern struct { r0: u64, r1: u64 }` and
worked across all corpus fixtures.

## HFA special case (b)-5

`FuncRet_f64f64 = extern struct { r0: f64, r1: f64 }` is a
**Homogeneous Floating-point Aggregate** (HFA<f64×2>) per AAPCS64
§6.8.2 — returned via V0+V1 register pair. JIT writes f64 results
to V0/V1 sequentially → natural match, no padding needed.

By analogy: `FuncRet_f32f32`, `FuncRet_f64f64f64`, etc. (when they
arrive) are HFAs and naturally align.

## What still doesn't work (D-137)

Mixed int+float (e.g. `(i32, f64)`): NOT HFA (different base types).
AAPCS64 packs into X0+X1 GPR pair. JIT writes i32→W0 (X0) and
f64→D0/V0 (FP register). Zig reads X1 = garbage.

Solution requires either a JIT-side ABI bridge OR an inline-asm
thunk in entry.zig that captures from X0 + V0 directly. Tracked
as D-137 mixed int+float residual.

## What still doesn't work (D-140)

`>16-byte` structs (e.g. 3-result `(i32, i32, i32)` would need
24 bytes via u64-padding). AAPCS64 transitions to indirect-result-
pointer (X8 = hidden first-arg = caller-allocated buffer pointer).
JIT epilogue doesn't emit this. Same family as D-094 x86_64
truncation.

## Reusable convention

For Cat II multi-result work, the recipe is:

| Result tuple shape | FuncRet field types | C-ABI route | Status |
|---|---|---|---|
| (int×2) | `extern struct { u64, u64 }` | X0+X1 GPR pair | ✓ working ((b)-3) |
| (int_a, int_b) with `a ≤ 64` + `b ≤ 64` | match natural width (u32, u64, etc.) — natural padding may yield 16 bytes if alignment forces | X0+X1 if ≥ 16 bytes | ✓ working ((b)-1, (b)-2, (b)-4) |
| (f64, f64) — HFA<f64×2> | `extern struct { f64, f64 }` | V0+V1 (HFA) | ✓ working ((b)-5) |
| (int, fp) — mixed-class | (no clean Zig layout) | needs ABI bridge | ✗ D-137 |
| (×3+) where total > 16 bytes | (no clean Zig layout) | needs X8 indirect-result-ptr | ✗ D-140 |
| (f32, f32) — HFA<f32×2> | `extern struct { f32, f32 }` (8 bytes!) | NOT HFA-packed; HFA only at ≥ 16 bytes? — verify before use | unverified |

## Cited from

- `src/engine/codegen/shared/entry.zig` (FuncRet_i32i32 docstring
  carries the convention statement)
- `.dev/debt.md` D-137 (mixed int+float bridge), D-094 (x86_64
  multi-result truncation), D-140 (large-sig 16-result outlier)
- ADR-0065 §"Cat II"
- ADR-0046 (AAPCS64 multi-arg/result ABI reference)
