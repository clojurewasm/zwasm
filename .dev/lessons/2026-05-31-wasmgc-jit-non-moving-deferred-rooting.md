# JIT-ing WasmGC on a non-moving collector = op-emit, with rooting safely deferred

**Date**: 2026-05-31 (web research for ADR-0128; user "100%" directive)
**Citing**: `801037b3` (ADR-0128); D-211
**Keywords**: WasmGC, JIT, GC codegen, non-moving, mark-sweep, deferred rooting,
conservative stack scan, Riptide, precise stack maps, safepoint, Cohen display,
supertype vector, ref.cast, CVE-2024-4761, i31 tag, struct.new, array, spec-corpus JIT,
both-backends, V8, JSC, Wasmtime, WAMR

## Observation (the difficulty was over-stated)

Earlier framing (from close-invariant I16) treated GC-on-JIT as "regalloc 3-axis
stack-map work" — the universally-hard part of JIT-ing WasmGC. Web research against
V8/JSC/Wasmtime/WAMR shows that is the **moving-collector** path (V8, SpiderMonkey:
must FIND and RELOCATE refs at safepoints → precise stack maps + regalloc coupling).

**A non-moving collector avoids all of it.** zwasm's collector is non-moving mark-sweep
(`collector_mark_sweep.zig`; GcRef = u32 slab offset), and the β does not reclaim yet
(sweep wired; free-list/compaction → Phase 11). Two facts:

1. **Non-moving ⇒ refs never relocate** ⇒ no pointer rewriting, no relocation stack maps.
2. **No reclamation ⇒ nothing freed ⇒ a missed root cannot use-after-free.**

So GC alloc is JIT-emittable NOW with **no safepoints / stack-maps / root-spilling**.
Rooting becomes load-bearing only when reclamation lands (Phase 11) — and a non-moving
collector then needs only a **conservative native-stack scan** (JSC Riptide: suspend,
copy stack + registers, treat any word in object bounds as a root; sound because nothing
moves), which needs ZERO codegen changes. Precise stack maps (Wasmtime/Cranelift+DRC) or
WAMR shadow-stack ref-spill are heavier and only owed if zwasm goes moving.

## Takeaway (how to apply)

GC-on-JIT for Phase 10 = **emit the ops**, same shape as the landed EH/TC op files — not
a regalloc rewrite. Per-op recipes (ADR-0128 §2): struct/array = `base = heap_base + ref`
+ field/element load/store (packed i8/i16 → sign/zero-extend on `_s`/`_u`); `array.len` +
`idx u>= len → trap`; **ref.cast/test = Cohen supertype-vector display** (RTT carries
supertypes self-last; `if n1 < n2 → fail; load vec[n2-1]; compare` — the `n1 >= n2` guard
is load-bearing, omitting it = CVE-2024-4761 OOB); `i31 = (v<<1)|1`, get_s/u = ASR/LSR 1;
`ref.eq` = u32 compare (valid only because non-moving). Allocation = a runtime-call helper
(survives the Phase-11 free-list change better than inline-bump). Verify through the
**spec-corpus JIT execution mode** (ADR-0128 §1; the wasmtime `tests/wast.rs` pattern —
compile every fn, invoke via JIT entry, compare), which is what makes "both backends"
mechanically true. The general rule: a runtime's collector choice (moving vs non-moving)
decides whether JIT-GC is hard; don't import the V8 difficulty model onto a mark-sweep
heap. See [[2026-05-30-phase10-jit-coverage-partial-spec-corpus-interp]].
