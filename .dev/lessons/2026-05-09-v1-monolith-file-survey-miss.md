# v1 monolith file survey miss — file-name vs content

> Date: 2026-05-09
> Citing: this session's user-facing v1/v2 SIMD comparison.

## What happened

During an interactive comparison of v1 vs v2 SIMD approaches, I
inspected the v1 source tree and found:

```
src/simd_arm64.zig  → 15 LOC stub (return false; "no opcodes implemented yet")
src/simd_x86.zig    → 15 LOC stub (same shape)
```

I concluded **"v1 SIMD is essentially zero implementation"** and
told the user so. The user pushed back ("マジか？simdテストとか
あったけど通したように見せかけていただけ？"). On re-investigation:

- `src/jit.zig` (8701 LOC) contains **~124 NEON encoder fns**
  (faddV4s, fsubV4s, fmulV4s, fdivV4s, addV4s, subV4s, faddV2d,
  fmulV2d, orrV16b, andV16b, eorV16b, notV16b, insVdD1, umovXdD1,
  ldrQ, strQ, …) under a `// --- NEON v128 ---` section.
- `src/x86.zig` (7555 LOC) contains **~185 SSE encoder fns**
  (paddb/w/d, pshufd, pinsr*, pextr*, pmull*, …) plus a parallel
  `simd_xreg` cache (16 entries + dirty bits + LRU).
- `src/opcode.zig` defines a complete `SimdOpcode` enum
  (0xFD-prefixed Wasm SIMD opcodes).
- `src/testdata/conformance/simd_{basic,integer,float}.wasm` are
  3 conformance fixtures invoked by `src/vm.zig` test blocks.
- `.dev/decisions.md: D122` documents the SIMD JIT strategy
  ("hybrid predecoded IR + deferred NEON") — implementation
  exists, but with a self-acknowledged 43x gap vs wasmtime.

So v1 SIMD was **substantially implemented** with conformance
tests passing for the represented ops. My "zero implementation"
claim was a misread.

## Why I missed it

`simd_arm64.zig` / `simd_x86.zig` looked like the obvious split-
file boundary for SIMD. They were 15-LOC stubs marked
"placeholder, no opcodes implemented yet". I took that statement
at face value and stopped reading. The 297 SIMD-keyword lines in
jit.zig + 256 in x86.zig were where the actual implementation
lived, but I didn't grep there until the user pushed back.

The trap: **v1's monolith file convention** (jit.zig 8.7k LOC,
x86.zig 7.5k LOC) means topic-named files like `simd_*.zig` may
be aspirational extraction stubs, not implementation. v2's split
discipline (per-op-family files, §A2 hard-cap regulated) is the
opposite — v2 file names DO reflect content. Cross-codebase
surveys must not assume v2's discipline applies to v1.

## How to avoid

When surveying v1 (or any reference codebase whose discipline
differs from v2):

1. **Always grep across the whole src/ tree** for op references
   / encoder fn names BEFORE concluding a feature is unimplemented:
   ```sh
   grep -rE "(v128\.|i8x16\.|i16x8\.|FADD|PADDD|fn enc.*Q|fn enc.*Xmm)" src/
   ```
2. **Check the topic-named file's LOC count** as a stub indicator:
   - 15 LOC + "placeholder" comment → suspect monolith location.
   - 1000+ LOC → trust the file boundary.
3. **Check test data** — `testdata/` fixture presence is a strong
   "implementation exists" signal even if the source layout
   suggests otherwise.
4. **Check `.dev/decisions.md`** (v1) / `.dev/decisions/` (v2) for
   strategy notes — D122 in v1's case named the SIMD strategy as
   "predecoded IR + deferred NEON" which would have flagged that
   real implementation existed somewhere, even if not in the
   topic-named file.

## Cross-references

- `.claude/rules/textbook_survey.md` — survey discipline for v1
  reads. Amended in same commit with a "monolith trap" caveat.
- `.dev/decisions/0041_simd_128_design.md` — already cites v1's
  W54 post-mortem as the parallel-cache anti-pattern source. The
  ADR's accuracy on v1 structure was correct; only the
  user-facing comparison messed up.
- This lesson + the textbook_survey.md amendment land together
  per `lessons_vs_adr.md` "Lesson alongside ADR amend" pattern,
  except no ADR amendment is needed (the ADR is already correct).
