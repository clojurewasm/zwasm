# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 complete. v1.1.0 released. ~38K LOC, 510 unit tests.
- Spec: 62,158/62,158 Mac + Ubuntu (100.0%). E2E: 792/792 (100.0%).
- Wasm 3.0: all 9 proposals. WASI: 46/46 (100%). WAT parser complete.
- JIT: Register IR + ARM64/x86_64. Size: 1.31MB / 3.44MB RSS.
- **main = stable**: ClojureWasm depends on main (v1.1.0 tag).

## Current Task

Reliability improvement (branch: `strictly-check/reliability-004`).
P1+P2 merged to main. Now on P3-P5.
Plan: `@./.dev/reliability-plan.md`. Progress: `@./.dev/reliability-handover.md`.

**Plan A: Incremental regression fix + feature implementation**
- [x] P1: rw_c_string hang fix — skip back-edge JIT for reentry guard (20.2ms)
- [x] P2: nbody FP cache fix — expand D-reg cache D2-D15, FP-aware MOV (23.1ms, 0.97x wasmtime)
- [x] P3: rw_c_math — accepted as regalloc limit (58ms, 4.92x, 136 regs)
- [x] P4: GC JIT — predecode+regalloc+JIT for struct ops (gc_alloc 0.50x, gc_tree 0.73x wasmtime)
- P5: st_matrix accept as exception (Priority C)

**Active: P5 (st_matrix accept as exception)**
st_matrix: 296.4ms, 3.23x wasmtime. Regalloc limit (too many regs for single-pass).
Accept ≤3.5x as exception.

## Previous Task

P4: GC JIT — predecode→regalloc→JIT pipeline for struct.new/get/set/new_default,
ref.null/is_null. BLR trampoline to unified jitGcTrampoline. Fix: emitPrologue must load
cached vm/inst ptrs BEFORE emitLoadRegPtrAddr. gc_alloc 19.2→5.4ms, gc_tree 138→22.8ms.

## Known Bugs

- c_hello_wasi: EXIT=71 on Ubuntu (WASI issue, not JIT — same with --profile)
- Go WASI: 3 Go programs produce no output (WASI compatibility, not JIT-related)

## References

- `@./.dev/roadmap.md`, `@./private/roadmap-production.md` (stages)
- `@./.dev/decisions.md`, `@./.dev/checklist.md`, `@./.dev/spec-support.md`
- `@./.dev/reliability-plan.md` (plan), `@./.dev/reliability-handover.md` (progress)
- `@./.dev/jit-debugging.md`, `@./.dev/ubuntu-x86_64.md` (gitignored)
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
