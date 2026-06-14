# LSRA boundary slot-coalescing (`<=`) requires read-before-write emit — an unenforced, fragile invariant

**Context**: D-330. emscripten `c_sha256_hash` + `emcc_fasta` miscompiled under
`--engine jit`/AOT (interp correct): plain `printf("%s")` printed empty + dropped the
trailing `\n`. Mechanism: musl `vfprintf`'s `%s` does `strnlen(s, SIZE_MAX)`; the
byte-loop null check (`i32.load8_u; i32.eqz`) miscompiled → strnlen overruns the
terminator → huge length → `if(p<0 && *z) goto overflow` → vfprintf returns -1 → no output.

**Root cause**: the LSRA free-pool expiry (`regalloc_compute.zig`) freed an active vreg's
slot when `active.last_use_pc <= new.def_pc`. The `<=` (vs `<`) coalesces a RESULT vreg
into the slot of an OPERAND the SAME instruction reads — their closed live intervals
`[def, last_use]` overlap AT that pc (op reads operand, writes result). Safe ONLY if every
op's emit reads all operands before writing its result. That invariant is **unenforced**
and was violated by some op in the byte-loop. Fix: strict `<` expiry — a result slot never
aliases an operand the defining op reads, so read-before-write emit discipline is
unnecessary. Cost: ~+1 slot on the worst realworld fn (vfprintf 12→13); negligible.

**How it was found (the method matters)**:
1. **Arch-dependence probe** (cheap, halved the space): built `-Dtarget=x86_64-macos`,
   ran the repro under **Rosetta** (same OS/stdout, only arch differs) — reproduced
   IDENTICALLY → shared codegen, not arch emit. (An x86_64-ubuntu probe gave noisy
   results — stale binary / env; Rosetta same-OS is the clean arch probe.)
2. **EXP2**: flipping expiry `<=`→`<` fixed it → localized to boundary coalescing.
3. The coalescing was **intended, test-pinned** (a test asserted `<=` gives 1 slot) — so
   the fix had to update that test + ADR, not just flip the operator.
4. **Decisive deduction over more bisecting**: a PC-window bisect "pinpointed" pc 1437,
   but the slot timeline was clean (no overlap) + the eqz emit was read-before-write
   correct → the window-bisect was perturbing GLOBAL slot state, not a clean pinpoint.
   What settled it: an allocation-validity check showed 0 same-slot overlaps (regalloc
   valid per liveness), AND `<` *reliably* fixes repro + emcc_fasta — which RULES OUT a
   liveness under-computation (a wrong last_use wouldn't be reliably fixed by `<`). ⇒
   coalescing-triggered emit read-after-write; `<` removes the trigger for ALL ops.

**Rules**:
1. A slot-reuse "coalesce at def==last_use" optimization silently depends on read-before-
   write emit for EVERY op. Prefer the misuse-resistant invariant (strict `<`, result
   never aliases a read operand) unless the perf delta is measured and material (here +1).
2. PC-window / single-knob bisects on GLOBAL allocator state perturb downstream — a
   "pinpoint" may be a perturbation artifact. Cross-check with an invariant
   (allocation-validity) + a reliability argument before trusting it.
3. Cross-build + Rosetta is the clean same-OS arch-dependence probe; arch-INDEPENDENT ⇒
   look in shared codegen, not per-arch emit.
4. Fixing the big bug can EXPOSE a smaller one it masked (c_sha256's residual dropped `\n`
   surfaced only after the hash output stopped being garbage) — don't claim full closure
   on one fixture without a byte-exact check (`head -2` hid the residual for a cycle).
