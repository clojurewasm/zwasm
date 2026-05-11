# 0055 — Win64 v128 param marshal via hidden-pointer (Microsoft x64 ABI)

- **Status**: Accepted
- **Date**: 2026-05-12
- **Author**: zwasm v2 maintainer (autonomous `/continue` loop, Phase 9 close)
- **Tags**: phase-9, simd, x86_64, abi, windows

## Context

§9.9-e-2 (commit `6de58406`) landed v128 param marshal for x86_64
under SystemV ABI only (XMM0..XMM7 direct register passing,
mirroring the ARM64 AAPCS64 V0..V7 path). The Win64 (Microsoft
x64) branch raised `UnsupportedOp` as a Phase 9 follow-up — the
commit body documented: "Win64 v128 stays UnsupportedOp
(Microsoft x64 ABI passes v128 by hidden pointer); SysV stack-arg
overflow (fp_arg_idx ≥ 8) UnsupportedOp pending follow-up."

The §9.12 phase-boundary windowsmini reconcile (2026-05-12)
surfaced **41 FAIL** on windowsmini (Win64 x86_64) all matching
`compile: UnsupportedOp = Win64 v128 param unsupported`, against
bit-identical 13301/0/440 PASS on Mac+OrbStack. The investigation
report at `private/d084-phase10-scope.md` confirms:

1. All 41 FAIL trace to the same Win64 early-return in
   `src/engine/codegen/x86_64/emit.zig` v128 param marshal.
2. Microsoft x64 ABI spec
   (`https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention`,
   §"Parameter passing"): `__m128` (and analogous vector types
   ≥ 16 bytes) are **never passed by immediate value**. Caller
   allocates 16-byte-aligned memory, passes a pointer in the
   normal integer-arg register slot. `__vectorcall` (XMM0..XMM5
   direct) is opt-in / non-default and out of scope for the
   default-Win64 conformance target.
3. cranelift's canonical implementation is in
   `~/Documents/OSS/wasmtime/cranelift/codegen/src/isa/x64/abi.rs`
   (`ABIArg::ImplicitPtrArg` shape at lines ~218-254 and
   prologue scratch reservation at ~383-395). winch's Win64
   path is simplified and not fully conformant — cranelift is
   the reference.
4. Implementation cost estimate: ~150-220 LOC, smaller than
   9.9-e-2's ~285 LOC SysV path because `LocalLayout` /
   MOVUPS encoders / `abi.win64` namespace are already in
   place. **No regalloc touch needed** (XMM pool starts at
   XMM8 either way on Win64). Test orchestration unchanged —
   existing `simd_assert_runner` auto-picks up 41 FAIL → PASS
   once the marshal lands.

## Decision

Implement Win64 v128 param marshal in `src/engine/codegen/
x86_64/emit.zig` as a single Phase 9 sub-chunk (proposed
identifier: **9.9-i-1**, mirroring the 9.9-e family's
ABI-specific marshal pattern). The chosen recipe follows
cranelift's `ImplicitPtrArg`:

- **Caller side**: for each v128 argument, reserve a 16-byte
  aligned scratch slot in the caller's local frame (extends
  the `LocalLayout` scratch region introduced by 9.9-e-2);
  emit `MOVUPS [scratch], xmm_value` then load the scratch's
  RBP-relative address into the integer-argument register
  slot (RCX / RDX / R8 / R9 in Win64 order, falling back to
  stack overflow via `[RSP + N]` for the 5th+ vector
  argument).
- **Callee side**: receive the pointer in the integer-arg
  register, emit `MOVUPS xmm_dst, [ptr]` at the function
  prologue to load into the regalloc-assigned XMM slot.
- **SysV branch unchanged**: continues to use direct
  XMM0..XMM7 passing per 9.9-e-2.

Branch selection is driven by `abi.target_abi == .win64` at
the existing param-marshal switch site; no new ABI
introspection layer.

## Alternatives considered

### Alternative A — Bundle into Phase 10 EH/GC ABI work

- **Sketch**: Defer Win64 v128 marshal to a Phase 10 chunk
  that combines it with EH/GC frame-layout changes (which
  also touch x86_64 prologue logic).
- **Why rejected**: Per agent investigation §6 — the EH/GC
  coupling is at the **frame-layout layer** (root scan,
  pdata/xdata unwinding), not at the **param-marshal
  layer**. Bundling defers a visible 41-FAIL fix while
  muddling commit review rationale. And per the row-text
  reading of §9.9 ("fail=skip=0 across both backends
  (3-host gate)"), windowsmini is part of Phase 9's exit
  criterion — the deferral violates Phase 9 scope.

### Alternative B — Defer to Phase 15 perf-parity work

- **Why rejected**: Phase 15 is a perf-optimisation phase;
  Win64 v128 marshal is an **ABI conformance** gap, not a
  perf concern. Category mismatch. Additionally violates
  `.claude/rules/no_workaround.md` Principle 3 — a tier-1
  host (windowsmini per ROADMAP §2 P/A 3-host gate) ABI
  conformance gap cannot be deferred across multiple phases
  without explicit ADR override.

### Alternative C — Adopt `__vectorcall` and pass v128 in XMM0..XMM5

- **Sketch**: Emit `__vectorcall` annotations on exported
  functions so Win64 passes vectors directly in XMM
  registers, mirroring SysV behaviour.
- **Why rejected**: (1) `__vectorcall` is opt-in / non-
  default; default Windows tooling (Win32 host loaders,
  `wasm-c-api` consumers compiled with MSVC default
  calling convention) expects the standard MS x64 ABI;
  emitting `__vectorcall` would break ABI compatibility
  with non-zwasm callers. (2) The opt-in marker requires
  emitting calling-convention metadata into PE/COFF, which
  no other v2 code path needs — large surface for a path
  that doesn't move the conformance needle. (3) cranelift,
  which is the reference for Win64 codegen, uses
  `ImplicitPtrArg` not `__vectorcall`.

## Consequences

- **Positive**: windowsmini reaches manifest-line skip-impl=0
  parity with Mac+OrbStack; Phase 9 exit criterion ("3-host
  gate") becomes literally satisfiable; D-084 closes inline;
  zwasm v2's Win64 codegen is ABI-conformant for the v128
  type going forward (mirror-extensible to v256+ if AVX path
  lands in Phase 15).
- **Negative**: ~150-220 LOC delta in `emit.zig` / `abi.zig`
  +/- new encoders (`encMovupsXmmMemPtr` / `encLeaRMemPtr`
  type) — pushes `emit.zig` further past the 2000-LOC hard
  cap. Likely triggers an `emit.zig` source split (D-052) in
  the same chunk or immediately after.
- **Neutral / follow-ups**:
  - Win64 stack-arg overflow for v128 (Win64 spec: 5th+
    vector goes on stack via pointer-arg slot, no special
    shadow store) — handled in same chunk per cranelift
    `ABIArg::StackArg` path.
  - SysV stack-arg overflow (`fp_arg_idx ≥ 8`, mentioned in
    9.9-e-2 as Phase 9 follow-up) can be co-discharged in
    the same chunk since both code paths are in
    `x86_64/emit.zig` param-marshal layer.
  - D-052 (emit.zig source split) is likely to fire as a
    follow-up since this work expands emit.zig further past
    the soft + hard cap.

## References

- ROADMAP §9.9 — Phase 9 exit criterion text ("3-host gate")
- ADR-0041 §5 — SSE4.1 baseline (Win64-orthogonal)
- ADR-0046 — v128 param marshal foundation (SysV / AAPCS64);
  this ADR extends the same recipe to Win64
- §9.9-e-2 commit `6de58406` — SysV marshal precedent + the
  "Win64 stays UnsupportedOp" deferral that this ADR
  closes
- `.dev/debt.md` D-084 — discharged by the chunk
  implementing this ADR
- `~/Documents/OSS/wasmtime/cranelift/codegen/src/isa/x64/
  abi.rs` lines 218-254 (`ABIArg::ImplicitPtrArg`) +
  383-395 (prologue scratch reservation) — canonical
  reference (read only, no copy-paste per
  `.claude/rules/no_copy_from_v1.md` analog for OSS refs)
- Microsoft x64 calling convention (verbatim citations in
  `private/d084-phase10-scope.md` §3):
  `https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention`
  §"Parameter passing", §"Returning structs and unions of
  size 16 bytes or less"
- `.claude/rules/no_workaround.md` Principle 3 — tier-1
  host ABI conformance gaps must not be Phase-deferred
  without explicit ADR override

## Revision history

| Date       | SHA          | Note                                                                                                                                                                                                                                                                                                                                                            |
|------------|--------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-05-12 | `<backfill>` | Draft. Awaiting implementation chunk (proposed 9.9-i-1). Closes D-084 at chunk close.                                                                                                                                                                                                                                                                           |
| 2026-05-12 | `<backfill>` | Accepted at §9.9 / 9.9-i-1 land. 3-host bit-identical SIMD subset achieved on first iteration: windowsmini `simd_assert_runner: 13301 passed, 0 failed, 440 skipped (= 50 skip-impl + 390 skip-adr)` matches Mac+OrbStack exactly. D-052 partial discharge (rbp_disp.zig extract, ~90 LOC) bundled. SysV fp_arg_idx>=8 stack-overflow co-discharged in same chunk. |
