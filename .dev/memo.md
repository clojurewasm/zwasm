# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 complete. v1.1.0 released. ~50K LOC, 521 unit tests.
- Spec: 62,263/62,263 Mac (100.0%, 0 skip). E2E: 792/792 (100.0%, 0 leak).
- Wasm 3.0: all 9 proposals. WASI: 46/46 (100%). WAT parser complete.
- JIT: Register IR + ARM64/x86_64. Size: ~1.4MB / ~3.5MB RSS.
- **main = stable**: ClojureWasm depends on main (v1.1.0 tag).

## Current Task

Gate hardening (branch: `strictly-check/gate-hardening`). Ready for merge.

**gate-hardening: Zero-skip/zero-leak + gate enforcement**
- [x] T1: nightly.yml — Debug spec test → ReleaseSafe (eliminates 11 tail-call timeouts)
- [x] T2: E2E runner memory leak fix (errdefer in void function was no-op)
- [x] T3: Fix all 87 spec validation skips (validate.zig: GC types, subtyping, tables, exceptions)
- [x] T4: Fix all 18 spec infra skips (run_spec.py: add assert_exception handler)
- [x] T5: Harden gate docs (CLAUDE.md, SKILL.md, bench/record.sh)
- [x] T6: Add --strict mode to run_spec.py, enable in CI

## Previous Task

reliability-005 (R0-R8): E2E segfault fix, Go/C++/C WASI back-edge JIT fixes,
18 new real-world tests, OSR for back-edge JIT, x86 OSR fixes, Phase H doc audit.
All merged to main at 48b3202.

## Known Bugs

None — all previously known bugs fixed (R1: E2E segfault, R2-R4: back-edge JIT restart).

## References

- `@./.dev/roadmap.md`, `@./private/roadmap-production.md` (stages)
- `@./.dev/decisions.md`, `@./.dev/checklist.md`, `@./.dev/spec-support.md`
- `@./.dev/reliability-plan.md` (plan), `@./.dev/reliability-handover.md` (progress)
- `@./.dev/jit-debugging.md`, `@./.dev/ubuntu-x86_64.md` (gitignored)
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
