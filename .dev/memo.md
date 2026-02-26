# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 complete. v1.1.0 released. ~38K LOC, 510 unit tests.
- Spec: 62,158/62,158 Mac + Ubuntu (100.0%). E2E: 792/792 (100.0%).
- Wasm 3.0: all 9 proposals. WASI: 46/46 (100%). WAT parser complete.
- JIT: Register IR + ARM64/x86_64. Size: 1.31MB / 3.44MB RSS.
- **main = stable**: ClojureWasm depends on main (v1.1.0 tag).

## Current Task

Reliability improvement (branch: `strictly-check/reliability-003`).
Plan: `@./.dev/reliability-plan.md`. Progress: `@./.dev/reliability-handover.md`.

Phases A-K complete. E2E 792/792 (100%), x86_64 JIT fully optimized.
**Phase K** (perf): All ARM64 optimizations ported to x86_64:
self-call (inline CALL, marker-based epilogue), div-by-constant (IMUL+SHR),
trunc_sat edge cases, FP-direct, const-folded ADD/SUB.
**Phase H Gate**: conditions 1-5,8 met. Conditions 6-7 (≤1.5x) blocked:
Mac: st_matrix 3.14x (regalloc), rw_c_* (OSR), gc_tree (GC JIT), nbody 1.54x.
Next: Phase H Gate blockers, then Phase H (documentation audit).

## Previous Task

K.6-K.7: x86_64 JIT self-call + div-by-constant:
- Self-call: [RSP] marker (0=self, 1=normal), inline CALL to lightweight entry
- Bugs fixed: RAX clobber (save to RCX), R12 restore, result propagation
- Div-by-constant: computeMagicU32 + IMUL r64 + SHR r64
- Ubuntu recursive benchmarks: fib 3x→1x, tak 3.3x→1.2x, tgo_fib 3.2x→1x

## Known Bugs

- c_hello_wasi: EXIT=71 on Ubuntu (WASI issue, not JIT — same with --profile)
- Go WASI: 3 Go programs produce no output (WASI compatibility, not JIT-related)

## References

- `@./.dev/roadmap.md`, `@./private/roadmap-production.md` (stages)
- `@./.dev/decisions.md`, `@./.dev/checklist.md`, `@./.dev/spec-support.md`
- `@./.dev/reliability-plan.md` (plan), `@./.dev/reliability-handover.md` (progress)
- `@./.dev/jit-debugging.md`, `@./.dev/ubuntu-x86_64.md` (gitignored)
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
