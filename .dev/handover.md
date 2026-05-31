# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD**: GC-op JIT emit COMPLETE both arches (`c94bd04f`, ubuntu-verified `72c0c9e3`):
  i31 + full struct family + full array family + ref.eq + ref.test/test_null/cast/cast_null
  + br_on_cast/br_on_cast_fail all emit on arm64 + x86_64. The **10.G-gc-on-jit emit bundle is
  CLOSED** (exit-condition met). Pivoting to ADR-0128 §1 (spec-corpus JIT execution mode).
- **Two execution paths (CODE-verified)**: spec corpus runs **interp-only**
  (`instance.invoke`→`_dispatch.run`, `instance.zig:169`). The JIT execution path for the
  spec corpus is **NOT yet wired** — that is the new §1 bundle below. Today only `runI32Export`
  (no-arg i32-result, `src/engine/runner.zig`) exercises the JIT e2e.
- **ADR-0128 + ADR-0127 both Accepted** — no remaining user gate; loop runs autonomously.
- **Watch**: `src/engine/runner.zig` at 1894 lines (soft-cap WARN; hard cap 2000). Extract the
  accumulating `runI32Export` e2e tests to a `test/` sibling (or FILE-SIZE-EXEMPT) before the
  next chunk that would breach 2000 (gate BLOCKS at 2000).

## Active task — Phase 10 → 100% (ADR-0128)  **NEXT**

Six workstreams (ADR-0128), value-prioritized (NOT §10 table-first):

1. **Spec-corpus JIT execution mode** (§1) — verification backbone — **NOW (Active bundle)**.
2. GC-on-JIT op emit (§2) — **DONE both arches**.
3. **ADR-0127 PHASE C** — cross-`Types` `canonicalEqual`; `gc/type-subtyping` 5→0.
4. Quick wins: **D-209** (lift leftover `>u32` offset check; payload already u64), **D-198**
   (rec-group subtype), **D-210** (cross-module proper-tail-call — arm64 prologue cohort-save).
5. **Realworld GC/EH/TC producers** (§5; flake.nix `#gen`): `wasm_of_ocaml` / `emcc
   -fwasm-exceptions` / `guile-hoot`.

## Active bundle

- **Bundle-ID**: `10.G-§1-jit-corpus-mode`
- **Cycles-remaining**: ~3
- **Continuity-memo**: ADR-0128 §1 — add a JIT EXECUTION path to the wasm-3.0 spec runner
  (`test/spec/spec_assert_runner_wasm_3_0.zig`): compile every fn → instantiate → invoke the
  exported fn via the JIT entry (NOT interp `instance.invoke`→`_dispatch.run`) → compare
  assert_return / assert_trap (wasmtime `tests/wast.rs` pattern). **Incremental** (the whole
  point of the should_fail list): start with the subset `runI32Export`/`callI32NoArgs` already
  supports — **no-arg i32-result exports GREEN**; track args / i64 / f32/f64 / v128 /
  multi-value / host-imports / typed-trap as a per-backend SKIP list (enumerated, NOT silently
  dropped). The general arg/result **dispatcher is a SEPARATE downstream chunk** — do NOT block
  the backbone on it. **Calling-convention 裏取り BEFORE the dispatcher chunk**: `entry.zig` has
  monomorphized helpers (`callI32_i32`, `callI32_i32i32`, …) ⇒ JIT'd Wasm fns receive params via
  the C ABI (X1.. / RSI..), NOT the operand stack (operand-stack push/pop is the host-call
  dispatch path, `instance.zig:119-137`) — CONFIRM by reading `entry.zig` + a prologue param-load
  before designing the general dispatcher (two survey subagents disagreed; resolve empirically).
  Mode toggle: env `ZWASM_SPEC_ENGINE=jit` (simplest) — `build.zig:15` documents `-Dengine
  interp/jit/both` but it is NOT yet implemented.
- **Exit-condition**: the wasm-3.0 spec runner executes ≥1 `assert_return` (no-arg i32 export)
  THROUGH the JIT (`callI32NoArgs`) and compares the result — i.e. a non-empty JIT-mode pass
  count, with the not-yet-supported set enumerated in a should_fail/skip list.
- **NEXT (this turn's chunk 2)**: JIT-mode toggle + no-arg-i32 `assert_return` path + skip-list
  in `spec_assert_runner_wasm_3_0.zig`. Then grow the dispatcher (args/i64/FP/multi-value/
  host-imports/typed-trap) chunk-by-chunk, flipping skips.

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 STALE (payload u64; lift leftover u32 check).
- **10.R** function-references — JIT emit present, corpus green; residual = D-198.
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = eh_frequency runner (I20), c_api tag
  accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit COMPLETE both arches; remaining = §1 JIT-corpus mode (this bundle)
  + ADR-0127 PHASE C + D-198 + gc_stress (I19) + dart/hoot (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

This turn pivoted from GC-emit (DONE) to §1. Whatever §1 chunk lands is kicked to ubuntu at
turn end — next `/continue`: `tail -3 /tmp/ubuntu.log`, expect `[run_remote_ubuntu] OK
(HEAD=<this turn's tip>)`. On FAIL: revert to last ubuntu-verified HEAD (`72c0c9e3`). Mac
aarch64 is primary; ubuntu confirms the x86_64 mirror.

**Lesson (still live)**: `gate_commit.sh --fast` DEFERS `zig build test`/`lint` (Step 4/5 own
them) — the parent's full `zig build test` before push is the real gate.

## Key refs

- **ADR-0128** (Phase 10 100% master plan; §1 = spec-corpus JIT execution mode); ADR-0116
  (RTT 8-deep Cohen display + subtype check); ADR-0127 (cross-module func type-identity);
  ADR-0126 (canonical type ids); ADR-0115 §10 (non-moving β collector); ADR-0060 (force-spill).
  ROADMAP §10.
- Debt: **D-211** (GC-on-JIT — emit done; §1 verifies it), D-212 (GC FP-value marshal gap —
  surfaces under §1 mode), D-209 (stale), D-202 / D-198 / D-210. Lessons
  `2026-05-31-jit-passthrough-result-clobbered-by-call` +
  `2026-05-31-wasmgc-jit-non-moving-deferred-rooting` +
  `2026-05-30-phase10-jit-coverage-partial-spec-corpus-interp`.
