# Checklist: JIT Fuel/Timeout Fix + PR #6 Timeout Merge

## Phase A: Fix JIT fuel bypass (existing bug)

- [ ] A1. Add fuel/deadline check at JIT back-edges (loop headers)
  - At OP_BR / OP_BR_IF / OP_BR_IF_NOT / OP_BR_TABLE emission:
    detect backward branch (target_pc <= current_pc)
  - Emit trampoline: spill → call consumeInstructionBudget → check error → reload
  - Or: emit inline decrement + conditional exit (cheaper, no call overhead)
  - Both ARM64 and x86_64 codegen
- [ ] A2. Tests: `--fuel 1000000 --invoke loop loop.wasm` terminates with JIT enabled
- [ ] A3. Tests: `zig build test` all pass, no leaks
- [ ] A4. Spec tests: `python3 test/spec/run_spec.py --build --summary` — fail=0, skip=0
- [ ] A5. E2E tests: `bash test/e2e/run_e2e.sh --convert --summary` — fail=0, leak=0
- [ ] A6. Real-world: `bash test/realworld/run_compat.sh` — PASS=50, FAIL=0
- [ ] A7. Benchmarks: `bash bench/run_bench.sh --quick` — no regression
  - Record: `bash bench/record.sh --id=jit-fuel-check --reason="back-edge fuel/deadline"`
- [ ] A8. Commit + Merge Gate (Mac + Ubuntu)

## Phase B: Merge timeout support (PR #6 + our additions)

- [ ] B1. Apply PR #6 essential changes (TimeoutExceeded, deadline fields, consumeInstructionBudget, setDeadlineTimeoutMs)
- [ ] B2. Add `--timeout <ms>` CLI option
- [ ] B3. Add tests (expired, infinite loop, API)
- [ ] B4. Verify: `--timeout 50 --invoke loop loop.wasm` terminates (JIT enabled)
- [ ] B5. All gates pass (test, spec, e2e, realworld, bench)
- [ ] B6. Commit + Merge Gate (Mac + Ubuntu)
- [ ] B7. Comment on PR #6 with results, credit DeanoC
- [ ] B8. Close PR #6 (or merge if DeanoC rebases)
