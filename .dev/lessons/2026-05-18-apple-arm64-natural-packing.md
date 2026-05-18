# Apple arm64 ABI variant: natural-size stack-arg packing

**Citing**: D-140 large-sig close (`func.wast::large-sig` 17 params /
16 results).

## Trigger

Functions with > 7 user int args OR > 8 fp args on Mac arm64
generate stack overflow args at OFFSETS DIFFERENT from standard
AAPCS64. Standard AAPCS64 (Arm IHI 0055 §6.4.2 stage C.16/C.17):
every overflowed scalar advances NSAA by **8 bytes**, regardless
of natural size. Apple's variant (per "Writing ARM64 Code for
Apple Platforms"): each arg consumes its **natural size** with
**natural alignment**, so consecutive `i32 + f32` pack into 4+4
= 8 bytes rather than 8+8 = 16.

The two ABIs diverge specifically for overflow scalars narrower
than 8 bytes (i32, f32, i8, i16). Register-passed args are the
same. f64 / i64 / v128 overflow is identical (natural size already
≥ 8).

## Concrete case — `func.wast::large-sig`

```
(func (export "large-sig")
  (param i32 i64 f32 f32 i32 f64 f32 i32 i32 i32 f32 f64 f64 f64 i32 i32 f32)
  (result f64 f32 i32 i32 i32 i64 f32 i32 i32 f32 f64 f64 i32 f32 i32 f64)
  ;; body: 16 × local.get, forwarding params to results.
)
```

Per AAPCS64, X1..X7 + V0..V7 absorb the first 7 int + 8 fp args.
Overflow on Mac arm64:
- a15 (i32) at outgoing_SP + 0 (4 bytes).
- a16 (f32) at outgoing_SP + 4 (4 bytes).

Standard AAPCS64 would place them at +0 and +8.

The pre-fix JIT prologue read a16 from `[X29 + 16 + 1*8] = [X29+24]`
(uniform 8-byte stride). On Mac arm64 the correct address is
`[X29 + 16 + 4] = [X29+20]`. The 4-byte mismatch surfaced as
spec_assert FAIL with `r13 = local.get 16 = garbage` while every
register-passed result matched.

## Verification (byte-dump)

```
[ 116] 0xbd401bb0  - LDR S V16, [X29, #24]   (WRONG: pre-fix)
[ 116] 0xbd4017b0  - LDR S V16, [X29, #20]   (CORRECT: post-fix on Apple ABI)
```

The fix lands in `arm64/emit.zig` prologue + `arm64/op_call.zig::
marshalCallArgs` + `arm64/emit.zig::computeOutgoingMaxBytes`:
replace the uniform `stack_arg_idx * 8` formula with a cursor
that advances by natural size + alignment when
`apple_natural_packing == true`, by 8 otherwise.

## Why prior tests missed this

Pre-D-140, no Wasm spec fixture under our 2-host gate exercised
arm64 stack overflow with narrower-than-8-byte scalars. The
`call.wast::long-argument-list` family uses i64-only args, which
naturally take 8 bytes on both ABIs. `fac.wast` etc. stay within
the 7-int-reg + 8-fp-reg pool. D-140's large-sig was the first
fixture to mix i32 + f32 overflow on arm64.

## Discharge

Implement a per-OS-tag cursor:

```zig
const apple_natural_packing: bool = builtin.target.os.tag == .macos or
    builtin.target.os.tag == .ios or
    builtin.target.os.tag == .watchos or
    builtin.target.os.tag == .tvos;
var stack_byte_off: u32 = 0;
// For i32 / f32 overflow:
const slot_size: u32 = if (apple_natural_packing) 4 else 8;
stack_byte_off = (stack_byte_off + slot_size - 1) & ~(slot_size - 1);
// emit LDR/STR at byte_off; advance cursor by slot_size.
stack_byte_off += slot_size;
```

i64 / f64 / v128 unchanged (already 8 / 8 / 16-byte natural
sizes; both ABIs agree).

## Stale-ness

If Apple changes its arm64 variant (unlikely — the spec has been
stable since the first arm64 Macs), this lesson + the
`apple_natural_packing` flag's per-OS list need re-validation.
The flag's truth domain should match Zig's own SysV / Apple
arm64 ABI selector for callconv(.c).

## Related

- ADR-0017 2026-05-18 amend — arm64 X8 indirect-result-ptr
  (separate axis; both apply to MEMORY-class returns).
- ADR-0026 2026-05-18 amend (Convention Swap) — x86_64 SysV
  side of the same D-140 work.
- ADR-0069 §Phase 3 — D-140 large-sig.
- Apple — "Writing ARM64 Code for Apple Platforms"
  (https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms).
