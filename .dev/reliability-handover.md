# Reliability — Session Handover

> Plan: `@./.dev/reliability-plan.md`. Rules: `@./.claude/rules/reliability-work.md`.

## Branch
`strictly-check/reliability-003` (from main at d55a72b)

## Progress

### ✅ Completed
- A-F: Environment, compilation, compat, E2E expansion, benchmarks, analysis, W34 fix
- G.1-G.3: Ubuntu spec 62,158/62,158 (100%). Real-world: all pass without JIT, 6/9 fail with JIT → Phase J
- I.0-I.7: E2E 792/792 (100%). FP precision fix (JIT getOrLoad dirty FP cache),
  funcref validation, import type checking, memory64 bulk ops,
  GC array alloc guard, externref encoding, thread/wait sequential simulation.
- J.1-J.3: x86_64 JIT bug fixes complete. All C/C++ real-world pass with JIT.
  Fixes: division safety (SIGFPE), ABI register clobbering (global.set, mem ops),
  SCRATCH2/vreg10 alias (R11 reserved), call liveness (rd as USE for return/store).
- K.x86: x86_64 JIT trunc_sat fix. Indefinite value detection for i32 case,
  subtract-2^63-and-add-back for i64 unsigned. Interpreter: floatToIntBits (IEEE 754).
  Ubuntu spec: 62150→62158/62158 (100%).
- K.x86opt: x86_64 self-call + div-by-constant. Self-call bypasses trampoline,
  div-by-constant uses IMUL+SHR. Ubuntu recursive benchmarks much improved.

### Active / TODO

**Phase K: Performance optimization (target: all ≤1.5x wasmtime)**
- [x] K.2: JIT opcode coverage — select, br_table, trunc_sat, div-by-constant (UMULL+LSR)
- [x] K.3: FP optimization — FP-direct load/store, const-folded ADD/SUB (marginal on ARM64)
- [x] K.4: Self-call setup optimization — bypass shared prologue, skip reg_ptr memory sync
- [x] K.5: Benchmark re-recording on BOTH platforms
- [x] K.6: x86_64 self-call optimization (inline CALL to lightweight entry point)
- [x] K.7: x86_64 div-by-constant (IMUL r64 + SHR r64 for multiply-by-reciprocal)

**Mac ARM64 benchmark status (quick run, vs wasmtime 41.0.1):**
- Non-blocked gap >1.5x: st_matrix 3.14x (regalloc, 35 vregs), nbody 1.54x
- Improved to ≤1.5x: tgo_mfr 1.35x (was 1.56x), st_fib2 1.35x (was 1.51x)
- **Blocked**: rw_c_math 4.42x, rw_c_matrix 1.82x, rw_c_string 1.74x (OSR), gc_tree 3.00x (GC JIT)

**Ubuntu x86_64 benchmark status (noisy VM, compare trends not absolutes):**
- Self-call + div-by-constant ported from ARM64
- Recursive benchmarks improved: fib ~1x, tak ~1.2-1.5x, tgo_fib ~1x, st_fib2 ~2.6x
- Still slower on some: tgo_nqueens ~1.5-1.7x, tgo_mfr ~3x (regalloc), rw_c_* (OSR)

**Phase H: Documentation (LAST — requires Phase H Gate pass, see plan)**
- [ ] H.0: Phase H Gate — conditions 1-5,8 met. Conditions 6-7 (benchmarks ≤1.5x) blocked by:
  - Mac: st_matrix (regalloc), rw_c_* (OSR), gc_tree (GC JIT)
  - Ubuntu: some benchmarks still >1.5x (noisy measurements, needs quiet re-run)
- [ ] H.1: Audit README claims
- [ ] H.2: Fix discrepancies
- [ ] H.3: Update benchmark table

## Next session: start here

1. **Phase H Gate blockers**: st_matrix (regalloc), OSR for rw_c_*, GC JIT for gc_tree.
2. After gates pass: Phase H (documentation audit).

## x86_64 JIT status (Phase K complete)
All C/C++ real-world programs pass with JIT on Ubuntu x86_64.
Self-call optimization and div-by-constant ported from ARM64.
Key self-call bugs fixed:
- RAX clobber: save error code to RCX during call_depth/reg_ptr cleanup
- R12 restore: SUB R12, needed_bytes after callee returns
- Result propagation: copy callee regs[0] to caller's rd slot
- emitArgCopyDirect: always load from memory (not stale physical regs)

## Benchmark gaps (Phase K status)
**Improved**: fib ~1x (was 3x), tak ~1.2x (was 3.3x), tgo_fib ~1x (was 3.2x).
**Blocked (needs OSR/GC JIT)**: rw_c_math, rw_c_matrix, rw_c_string, gc_tree.
**Needs arch changes**: st_matrix 3.1x (regalloc), tgo_mfr ~3x (regalloc).
