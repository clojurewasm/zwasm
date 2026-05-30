# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — CLOSE-ELIGIBLE** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `be9fb534` (cyc230). Session (cyc213-230) delivered, ubuntu-verified: D-208 + D-209
  JIT bug fixes; 2 false-coverage caching fixes; nix **`devShells.gen`** toolchain provisioning;
  cyc224 **shadow-stack unlock**; complete real-toolchain **realworld/p10 matrix** (8); pre-close
  audit (coherent). **cyc230 = D-206 step 1**: 2-module JIT harness + baseline cross-module CALL
  (green, isolated unit-level coverage that the .wast corpus didn't give).
- **10.P: 16 PASS / 8 SKIP / 0 FAIL → close-eligible.**
- **Step 0.7 on resume**: cyc230 (`be9fb534`) is a CODE chunk → kicks ubuntu; verify
  `/tmp/ubuntu.log` next cycle (revert pair on FAIL). Prior green: `OK (HEAD=0aad48c6)`.

## Active bundle

- **Bundle-ID**: D-206-cross-module-TC. **Cycles-remaining**: ~1-2 (step 1 landed cyc230).
- **cyc229 Step-0 GROUND-TRUTH (re-scopes the wrong cyc218 survey)**: cross-module CALL via JIT
  ALREADY works natively + is spec-validated. The spec runner's `resolveCrossModuleImports`
  (`spec_assert_runner_base.zig:1476`) emits a NATIVE bridge thunk via `shared/thunk.zig:emitThunk`
  (call-and-return: save pinned reg, swap runtime_ptr→callee_rt, BLR/CALL callee_entry, restore,
  RET-to-importer) into `host_dispatch_base[import_idx]`. (The interp-routed
  `api/cross_module.zig:thunk` is the C-API *Linker* path, NOT the JIT path — cyc218 confused them.)
  So D-206 needs only: (1) a 2-module return_call TEST (no tail-call cross-module test in the
  spec corpus), (2) the tail-bridge EMIT — per ADR-0112 D4: marshal args, `frame_teardown(A)`,
  tail-jump `BR/JMP` to the callee with X0/RDI=callee_rt (so the callee's RET goes to A's caller).
  The existing `emitThunk` is CALL-shaped → return_call needs a NEW tail bridge (inline per D4,
  OR a tail-variant thunk). Reject site: `op_tail_call.emitDirectReturnCall` arm64:157 / x86_64:143
  (`if ins.payload < num_imports → UnsupportedOp`).
- **Harness LANDED (cyc230 `be9fb534`)**: `CrossModuleHarness` in `src/engine/runner.zig` test
  scope — compile A+B, `shared_thunk.emitThunk` into a JIT arena → plant into A's
  `host_dispatch_base[0]` view, `entry.callI32NoArgs(A.test)`. The dispatch-override "gap" is
  solved WITHOUT a `setupRuntime` change: overwrite `RuntimeOwned.dispatch[0]` post-setup (it
  aliases `rt.host_dispatch_base`, setup.zig:510). Baseline `call $get` → 42 green on Mac.
- **Step 2 (tail-bridge EMIT)**: reject site `op_tail_call.emitDirectReturnCall` arm64:157 /
  x86_64:143 (`ins.payload < ctx.num_imports → Error.UnsupportedOp`). `cross_module_tail_call.zig`
  does NOT exist yet (referenced in op_tail_call comments as 10.TC-3f). Per ADR-0112 D4: marshal
  args, `frame_teardown(A)`, tail-jump `BR/JMP` to the callee with X0/RDI=callee_rt. The existing
  `emitThunk` is CALL-shaped (BLR+RET-to-importer) → return_call needs a NEW tail bridge. The
  callee_rt+callee_entry are embedded in the thunk slot's literal pool; for the tail path the emit
  must reach them — either a tail-variant thunk planted alongside, or expose them at resolve time.
- **Exit-condition**: extend the harness — A's `test` does `return_call $get` (a_return_call.wat
  bytes already minted: `…0x12 0x00 0x0b`) → JIT-executes → 42, both arches, ubuntu-verified.

## Active task — D-206 step 2: cross-module return_call tail-bridge emit  **NEXT**

RED first: add the `return_call` variant to `CrossModuleHarness` (importer bytes with `0x12 0x00`
instead of `0x10 0x00`) → `compileWasm(A)` currently returns `Error.UnsupportedOp` at the reject
site. GREEN: implement the tail-bridge per ADR-0112 D4 (arm64 first, then x86_64) so A.test
`return_call $get` JIT-executes to 42. Both arches; ubuntu-verified at the cyc-after Step 0.7.
NOT close-required (interp covers it); completes the tail-call JIT arc (D-205→D-208→D-206).
**User touchpoint (held)**: Phase 10 close-eligible (10.P 0 FAIL). Formal close (→ Phase 11) is
a high-value user decision; D-206 is the loop's autonomous continuation, re-armable to the close
at any user signal. Re-arm holds.

## §10 close map + open

Spec-corpus rows mature; 10.P close-eligible (0 FAIL). realworld/p10 matrix complete (8). gc .17
funcref-RTT (D-198) deep defer; funcrefs 34/39 (5 RTT-gated); 10 SKIP-WASI → Phase 11.
D-197 (validate-error surfacing ad-hoc); D-209 residual (>4GiB memory64 offset, payload u32).

## Key refs

- ADR-0066 (cross-module bridge thunk); ADR-0112 D4 (cross-module tail-call); ADR-0111 (memory64);
  ADR-0114 (EH). `flake.nix devShells.gen` + `.dev/toolchain_provisioning.md`.
- Lessons: `2026-05-30-{jit-funcref-tail-call-codegen-recipe, clang-wasm-realworld-toolchain-recipe,
  edge-runner-fixture-cache-false-coverage}`. ROADMAP §10; `.dev/phase_log/phase10.md`.
