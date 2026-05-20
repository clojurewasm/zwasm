---
name: Multi-result return ABI — u64-padded register pair + indirect-result-pointer for >2 / mixed-class / >16-byte
description: Codify the contract between Zig entry helpers and JIT epilogue for multi-result function returns; specify the discharge path for D-094 / D-137 / D-140
status: Accepted
date: 2026-05-18
---

# ADR-0069: Multi-result return ABI

## Status

Accepted (2026-05-18). Promoted from lesson
`2026-05-17-funcret-u64-padding-aligns-jit-epilogue.md` (deleted
in the same commit per `lessons_vs_adr.md` promotion procedure).

## Context

Wasm 2.0 multi-result function returns (per Wasm spec §3.4.5
"multi-value") require the Zig entry helper layer (`callXX_yy(...)
Error!FuncRet_<types>`) to interoperate with the JIT epilogue's
result-marshal convention (`marshalFunctionReturn` on both
arches). The two are NOT identical by default:

- **Zig `extern struct` return** follows the host C ABI struct-
  return rules (AAPCS64 §6.8.2 / SysV §3.2.3 / Win64
  §"Parameter passing — return values"): structs ≤ 8 bytes pack
  into a single register; structs ≤ 16 bytes spread across a
  register pair; structs > 16 bytes return via the caller-
  allocated indirect-result-pointer (X8 hidden first-arg on
  AAPCS64; RDI hidden first-arg on SysV; RCX hidden first-arg
  on Win64). HFAs (Homogeneous Floating-point Aggregate) bypass
  the integer-register packing and use the FP-class register
  pair (V0+V1 / XMM0+XMM1).

- **JIT epilogue** (per `marshalFunctionReturn` in both arches'
  `op_control.zig`) assigns sequential X-regs for GPR-class
  results and sequential V-regs / XMM-regs for FP-class results,
  one register per result slot, capped at 8 per class.

For Cat II close (§9.9-II per ADR-0065), the spec corpus
exercises shapes that cross these conventions' boundaries. This
ADR codifies which shapes work today, which are blocked, and
the implementation contract for unblocking the residual.

## Decision

The multi-result return ABI consists of **three classes**:

### Class A — 2-result fits in C-ABI register pair (working today)

For result tuples ≤ 16 bytes total with all-int OR HFA-uniform
fields:

| Result tuple shape | Zig FuncRet layout | C-ABI route | Status |
|---|---|---|---|
| `(int×2)` | `extern struct { r0: u64, r1: u64 }` (16 B; u64-padded) | X0+X1 / RAX+RDX | ✓ working |
| `(int_a, int_b)` natural widths summing ≥ 16 B | match natural widths | X0+X1 / RAX+RDX | ✓ working |
| `(f64, f64)` HFA<f64×2> | `extern struct { f64, f64 }` (16 B) | V0+V1 / XMM0+XMM1 | ✓ working |

**Convention**: each `FuncRet_*` field is u64-padded so the
struct totals ≥ 16 bytes, forcing the C-ABI to return via the
register pair instead of packing two fields into a single
register. Each `r_i: u64` holds the smaller-width result
zero-extended (matches W-form zero-extension the JIT epilogue
emits).

`FuncRet_i32i32 = extern struct { r0: u64, r1: u64 }` is the
canonical example documented in `src/engine/codegen/shared/
entry.zig`. The convention extends to all 2-result same-class
shapes.

### Class B — 2-result mixed int+float (D-137, blocked)

Shapes like `(i32, f64)` are NOT HFA (different base types)
and NOT pure-int. Both AAPCS64 and SysV pack into the int
register pair (X0+X1 / RAX+RDX), but the JIT epilogue writes
i32 → W0 / X0 (GPR class) and f64 → D0 / V0 (FP class). Zig
reads X1 = garbage.

**Discharge requires**: either (a) a JIT-side ABI bridge that
detects mixed-class returns and copies V0 → X1 before RET
(callee-side fix); OR (b) an inline-asm thunk in `entry.zig`
that captures X0 (int) + V0 (fp) directly via `callconv(.naked)`
or asm volatile blocks (caller-side fix). Option (b) is
preferred for v2 (smaller blast radius — no JIT codegen change;
the thunk overhead matters only for entry-point calls, which
are the host→guest boundary, not the guest→guest hot path).

### Class C — >2-same-class OR >16-byte struct (D-094 / D-140, blocked)

Shapes like `(i32, i32, i32)` (24 B) or `(i64, i64, i64)` (24 B)
exceed the 16-byte register-pair budget. AAPCS64 routes via X8
(hidden first-arg = caller-allocated buffer pointer); SysV
routes via RDI; Win64 routes via RCX (hidden first-arg shifts
all other args by one slot).

**Discharge requires** (the indirect-result-pointer ABI):

1. **JIT-side function-signature detection** (`compile_func.zig`
   or `op_control.zig`): when a function's return tuple's
   GPR-class count > 2 OR FP-class count > 2 OR total struct
   size > 16 B, classify as MEMORY-class return.
2. **Callee prologue** (`prologue.zig` per arch): for
   MEMORY-class returns, capture the hidden indirect-result-ptr
   from the platform-specified register (X8 on AAPCS64; RDI on
   SysV; RCX on Win64) and store to a frame slot for the
   epilogue to read.
3. **Callee epilogue** (`marshalFunctionReturn`): for
   MEMORY-class returns, write each result to `*(buf + i*8)`
   instead of to sequential X/V regs.
4. **Caller-side `op_call.captureCallResult` + `op_call.marshalCallArgs`**:
   pre-allocate a 16-byte-aligned scratch buffer in the
   outgoing-args region; LEA pointer to X8/RDI/RCX before the
   CALL; read results back from the buffer post-CALL.
5. **`entry.zig` helpers**: declare `FuncRet_<shape>` `extern
   struct` with natural u64-padded fields summing > 16 B; Zig
   automatically uses the host C-ABI indirect-result-pointer
   path (X8/RDI/RCX), matching the JIT's emit. Caller-side
   buffer allocation happens transparently in the JIT-emit
   layer (step 4).

The asymmetry vs `marshalCallArgs`'s v128 hidden-pointer path
(landed at chunk 9.9-i-1 per ADR-0055 for D-084 Win64 v128
marshal): the v128 case was per-ARGUMENT hidden pointer (caller
allocates buffer for the v128 arg); the D-094/D-140 case is
per-RETURN hidden pointer (caller allocates buffer for the
result struct). Both share the LEA + ABI-reg-store pattern but
on different ABI slots.

## Alternatives considered

### Alt 1 — Register overflow into X2/RCX (rejected)

Could the JIT epilogue write the 3rd result to X2 (arm64) /
RCX (SysV)? On arm64 X2 is a fine choice (still a caller-
saved arg/return reg). On SysV RCX is also caller-saved. But
Zig's `extern struct` return ABI doesn't match — Zig would
still try to read from X8 / hidden-ptr buffer, not X2 / RCX.
The asymmetry between JIT-emit and Zig-read defeats the
purpose; the bridge becomes brittle.

Rejected: non-standard ABI; doesn't compose with Zig's
`extern struct` return.

### Alt 2 — Inline-asm thunk in entry.zig for arm64 only (rejected for >2-result)

Could `entry.zig`'s `callI32i32i32NoArgs` use a `callconv(.naked)`
or `asm volatile` block to call the JIT function and capture
X0/X1/X2 directly into the struct fields? Works on AAPCS64
(X0/X1/X2 are real arg/return regs), but:

- SysV has no 3rd int-return reg (RAX/RDX is the limit). No
  symmetric x86_64 implementation.
- Inline asm bypasses Zig's type system and is platform-
  brittle.
- For shapes with > 3 int results (D-140's 16-result `large-
  sig`), the per-result manual capture becomes unwieldy.

Rejected as a structural solution. Acceptable as a per-shape
workaround for narrow cases if D-094 implementation is
deferred (none currently planned).

### Alt 3 — Defer Cat II close until v0.1.0 RC (rejected per ADR-0065)

Per ADR-0065 §"Cat II", multi-result entry helpers are in-scope
for Phase 9 close (not Phase 10+). The §9.9-II row's exit
predicate is `skip-impl == 0` literally on multi-result
directives. Without discharging the D-094 / D-137 / D-140
cohort, 17 manifest-level skip-impl lines persist.

Rejected: ADR-0065 already absorbed this into Phase 9 scope;
moving it back to Phase 10+ would require re-amending
ADR-0065.

## Consequences

### Positive

- Class A working today covers the highest-impact shapes (~1383
  of 1400 multi-result directives drained pre-cycle-4).
- Indirect-result-pointer ABI (Class C) mirrors the v128 hidden-
  pointer pattern from ADR-0055 — same LEA + reg-store recipe,
  same alignment discipline (16-byte buffer alignment in caller's
  outgoing-args region).
- Once Class C lands, `entry.zig` helpers fall out naturally
  — no per-shape inline asm needed.

### Negative

- Class C implementation is 4 sub-chunks per arch × 2 arches = ~8
  commits, plus 1 ADR amendment to ADR-0017 (arm64 prologue) /
  ADR-0026 (x86_64 prologue) for the hidden-ptr capture.
- Class B (mixed int+float) needs its own bridge sub-chunk
  (Option (b) inline-asm thunk in entry.zig, ~3 helpers covering
  the corpus's `(i32, f64)` / `(f64, i32)` / `(f32, f64)` shapes).
- Caller-side buffer pre-allocation grows the outgoing-args
  region for any caller invoking a MEMORY-class return; ≤ 24
  bytes per call site for Class C 3-result. Real cost is
  negligible (caller frame already pads to 16-byte alignment).

### Neutral

- The u64-padded `extern struct` convention from Class A stays.
  Class C adds a NEW convention (natural-width fields summing >
  16 B → automatic indirect-result-ptr); the two coexist.
- HFA<f32×2> (8 bytes total) status remains UNVERIFIED — likely
  packs into a single register (not HFA-routed for sub-16-byte
  structs). Worked example in the corpus doesn't exist; resolve
  if/when a real fixture needs it.

## Implementation chunked plan

Implementation lands across follow-on chunks, NOT in this ADR's
commit. Refined 2026-05-18 to make the dependency chain explicit:

```
D-135 (entry.zig comptime-gen)     ← Phase 0 prerequisite
  ↓
D-146 (x86_64 inline-asm thunk)    ← Phase 1.5 (small, unlocked by D-135 cap relief)
  ↓
Phase 2 — Class C indirect-result-pointer (D-094 + D-140)
  ↓
Phase 3 — D-140 large-sig (16-result; trivial extension)
```

**Phase 0 — D-135 prerequisite (entry.zig comptime-gen)** (NEW —
not previously in this ADR):
- entry.zig currently sits at ~2473 LOC with the ADR-0063
  `FILE-SIZE-EXEMPT` marker raising the cap to 2500. Each new
  Class B / Class C helper adds ~30 LOC; the cap is already
  ~25 LOC away from violating. ANY further multi-result chunk
  blocks on D-135's comptime-loop refactor reducing the
  ~84 helpers (~12-20 LOC each) to a generator + table.
- Acceptance: entry.zig ≤ 1500 LOC after the refactor; all
  84 helpers still callable with identical signatures; spec
  PASS count unchanged on Mac + ubuntunote.
- Estimate: 1 ADR-grade chunk (touches every existing
  call site indirectly through the comptime expansion).

**Phase 1 — Class B mixed int+float (D-137)** — partially landed
(chunks (b)-d-1 + (b)-d-2 closed cycle 9; cycle 11 (b)-d-2 reverted
to D-146 due to Zig 0.16 `splitType` TODO):
- (b)-d-1: arm64 entry.zig helpers for `(i32, f64)` / `(i64,
  f64)` / `(f64, i32)` via inline-asm thunk capturing X0 + V0.
  ✓ LANDED cycle 9 (commit `d6982a3e`).
- (b)-d-2: heterogeneous-FP `(f64, f32)` shape. ✗ REVERTED
  cycle 11; deferred to D-146 (blocked on D-135 cap relief
  OR Zig upstream `splitType`).

**Phase 1.5 — D-146 close (`(f64, f32)` shape + Win64 thunk)**:
After D-135 lands, entry.zig has room for the x86_64 SysV
inline-asm thunk (`call *fn ; movq xmm0,r0 ; movq xmm1,r1`).
Add the same shape to arm64 (already prototyped cycle 11) +
x86_64 + (optionally) Win64. Re-bake manifests; the 1
remaining Class B `type-all-f32-f64` line drains.
- (b)-d-3: x86_64 SysV inline-asm thunk for `(f64, f32)`.
- (b)-d-4: re-land cycle-11 arm64 thunk + struct definition.
- (b)-d-5: distiller `supported_multi` + runner dispatch arm.
- (b)-d-6: re-bake manifests; verify PASS-count gain = 1.
- (b)-d-7 (optional): Win64 thunk (deferred to §9.13-0 per
  ADR-0049 + ADR-0056 + ADR-0065 2026-05-18 amendments if
  schedule pressure).

**Phase 2 — Class C indirect-result-pointer (D-094 + D-140)**:
PREREQUISITES: D-135 (cap relief), D-146 close. Once
prerequisites are green:
- (b)-e-1: arm64 callee prologue capture of X8 hidden-ptr +
  epilogue write via `*(buf + i*8)`. **ADR-0017 amendment
  required** noting the new prologue slot.
- (b)-e-2: arm64 caller-side allocate + LEA + capture.
- (b)-e-3: x86_64 mirror (RDI on SysV, RCX on Win64). **ADR-
  0026 amendment required**.
- (b)-e-4: entry.zig `FuncRet_i32i32i32` / `FuncRet_i32i32i64`
  / etc. declarations; distiller `supported_multi` + runner
  dispatch.
- (b)-e-5: re-bake; verify PASS-count gain ≥ 7 (3-int-result
  lines: 3 `*-i32-i32-i32` + 4 `break-multi-value`).

**Phase 3 — D-140 large-sig (16-result)** — trivial extension
of Class C ABI to >8 same-class result slots. 1 spec line
(`large-sig`); thin scope; same `*(buf + i*8)` mechanism.
- (b)-f-1: bump per-class cap from 8 → 16+ (or arbitrary)
  in `marshalFunctionReturn` + caller-side buffer sizing
  threading.

**After all phases**: `§9.9-II [x]` cleanly. The §9.9 umbrella
row's remaining sub-row is then just §9.9-II (since §9.9-III
closed cycle 5, §9.9-IV moved to §9.13-0 per ADR-0049 + ADR-
0056 + ADR-0065 2026-05-18 amendments). `§9.9 [x]` flip
unblocks the §9.12 substrate audit hard-gate.

## References

### Promoted-from lesson

- `.dev/lessons/2026-05-17-funcret-u64-padding-aligns-jit-epilogue.md`
  (deleted in the same commit as this ADR per
  `lessons_vs_adr.md` promotion procedure).

### Related ADRs

- ADR-0017 (arm64 JIT runtime ABI) — prologue layout that Class
  C amends.
- ADR-0026 (x86_64 R15 Cc-pivot) — x86_64 prologue ABI for
  Class C amendment.
- ADR-0046 (v128 calling convention) — single-result v128 marshal
  precedent.
- ADR-0055 (Win64 v128 hidden-pointer marshal) — closest pattern
  match for caller-side LEA + buffer-alloc.
- ADR-0065 (Phase 9 Cat III absorption) — §"Cat II" anchor.

### Debt cohort

- D-094 (x86_64 >2-GPR multi-result truncation).
- D-137 (mixed int+float 2-result bridge).
- D-140 (large-sig 16-result indirect-result-ptr outlier).

### Spec

- AAPCS64 (Arm IHI 0055) §6.8.2 "Functions returning a struct
  type" + §6.8.3 "Homogeneous Floating-point Aggregates".
- SysV AMD64 ABI §3.2.3 "Parameter Passing" — MEMORY class /
  hidden first-arg.
- Microsoft x64 ABI §"Parameter passing" — return values via
  RCX hidden arg for > 8-byte structs.

## Revision history

| Date       | SHA          | Note                                                                                                                                                                                |
|------------|--------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-05-18 | `fff51d03` | Initial Accepted version, promoted from lesson `2026-05-17-funcret-u64-padding-aligns-jit-epilogue.md`. Codifies Class A (working), Class B (D-137 deferred), Class C (D-094 / D-140 plan).                                                                                                                                                                                                                                                                                                          |
| 2026-05-18 | `86fad986` | **Implementation chunked plan refined** — dependency chain made explicit: D-135 (entry.zig comptime-gen) is Phase 0 prerequisite gating ALL subsequent multi-result helper additions due to ADR-0063 exempt-cap pressure (cycle-11 D-146 surfaced this empirically). D-146 close moved to new Phase 1.5 between Class B residual and Class C. Phase 2/3 unchanged. Status of cycle-9 (b)-d-1 (LANDED) + cycle-11 (b)-d-2 (REVERTED to D-146) annotated inline. |
