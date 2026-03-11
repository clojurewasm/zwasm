# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 + Phase 1, 3, 5 complete. **v1.3.0 released** (tagged 7570170).
- Spec: 62,263/62,263 Mac+Ubuntu (100.0%, 0 skip). E2E: 792/792 (100.0%, 0 leak).
- Wasm 3.0: all 9 proposals. WASI: 46/46 (100%). WAT parser complete.
- JIT: Register IR + ARM64/x86_64. Size: 1.20MB stripped. RSS: 4.48MB.
- Module cache: `zwasm run --cache`, `zwasm compile` (D124).
- **C API**: `libzwasm.so`/`.dylib`/`.a` — 25 exported `zwasm_*` functions (D126).
- **Conditional compilation**: `-Djit=false`, `-Dcomponent=false`, `-Dwat=false` (D127).
  Minimal build: ~940KB stripped (24% reduction).
- **Phase 8 merged to main** (d770bfe). Real-world compat: 50/50 (Mac+Ubuntu).
- **Phase 11 merged to main** (49f99e5). C API allocator injection (D128).
- **main = stable**: v1.5.0 tagged (48342ab). ClojureWasm updated to v1.5.0.

## Current Task

**Fix JIT fuel bypass + PR #6 timeout merge**

Checklist: `@./.dev/checklist-jit-fuel-timeout.md`
PR review: `@./private/pr6-timeout-review.md`

### Phase A: Fix JIT fuel bypass (branch: `fix/jit-fuel-bypass`)
- [x] A1. Add `jitSuppressed()` — suppress JIT when `fuel != null` (6 locations in vm.zig)
- [x] A2. Test: infinite loop with fuel=1M terminates (`30_infinite_loop.wasm`)
- [ ] A3. Commit Gate: `zig build test` pass, spec/e2e/realworld/bench (running)
- [ ] A4. Merge Gate (Mac + Ubuntu)

### Phase B: Merge timeout support (PR #6 + additions)
- [ ] B1. Apply PR #6 changes (TimeoutExceeded, deadline, consumeInstructionBudget)
- [ ] B2. Add `--timeout <ms>` CLI option
- [ ] B3. Tests + verify with JIT enabled
- [ ] B4. Commit + Merge Gate
- [ ] B5. Comment on PR #6, credit DeanoC

## Handover Notes

### JIT fuel/timeout suppression — current fix vs proper solution
- **Current fix**: `jitSuppressed()` disables JIT entirely when `fuel != null`. Simple, correct, zero impact on normal execution.
- **Proper solution**: Emit fuel/deadline checks at JIT loop back-edges (like wasmtime). This preserves JIT performance even with fuel/timeout.
  - wasmtime uses negative-accumulation fuel (increment toward 0, sign check) + epoch-based timeout (atomic counter at loop headers).
  - zwasm JIT caches `vm_ptr` in x20 (ARM64) — inline `vm->fuel` decrement + conditional trampoline exit is feasible.
  - Separate future task. See `@./private/pr6-timeout-review.md` §Fix Options and wasmtime research in `~/Documents/OSS/wasmtime/crates/cranelift/src/func_environ.rs`.
- **Flaky compat tests**: W36 in checklist.md — `go_crypto_sha256`/`go_regex` intermittent DIFF on base code (pre-existing, likely W35-related).

## References

- `@./.dev/roadmap.md` (future phases), `@./.dev/roadmap-archive.md` (completed stages)
- `@./private/future/03_zwasm_clojurewasm_roadmap_ja.md` (integrated roadmap)
- `@./.dev/references/allocator-injection-plan.md` (Phase 11 design + tasks)
- `@./.dev/decisions.md`, `@./.dev/checklist.md`, `@./.dev/spec-support.md`
- `@./.dev/jit-debugging.md`, `@./.dev/bench-strategy.md`
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
