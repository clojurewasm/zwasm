# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD**: `fb991029` — 10.G **x86_64 struct mirror**: SysV `struct.new_default`
  (jitGcAlloc trampoline call; rt→RDI, typeidx→ESI, &fn→R10, CALL, EAX→result) +
  `struct.get` (null-trap TEST+JE→bounds_fixups; slab base R15→gc_heap→Heap.bytes;
  R11 slab scratch; 8-byte field load). The two `runI32Export` struct round-trips are
  UNGATED for x86_64. Verified: `zig build test` (native arm64, full) EXIT=0/0-err — both
  struct tests now RUN on arm64; `zig build -Dtarget=x86_64-linux-gnu` EXIT=0. x86_64
  RUNTIME exec = pending ubuntu gate (kicked against fb991029).
- **Two execution paths (CODE-verified)**: spec corpus runs **interp-only**
  (`instance.invoke`→`_dispatch.run`, `instance.zig:169`). JIT emits 1.0/2.0 + tail-call +
  function-references + EH + i31 (both arches) + **struct.new_default/get (both arches)**;
  remaining GC (struct.new variadic / struct.set / array / ref.cast / ref.eq) interp-only
  (D-211). Green gc/EH corpus = INTERP coverage; JIT corpus run = §1 workstream.
- **ADR-0128 + ADR-0127 both Accepted** — no remaining user gate; loop runs autonomously.

## Active task — Phase 10 → 100% (ADR-0128)  **NEXT**

Six workstreams (ADR-0128), value-prioritized (NOT §10 table-first):

1. **Spec-corpus JIT execution mode** (§1) — verification backbone: run the official
   testsuite through the JIT (compile-every-fn → JIT-entry invoke → compare; wasmtime
   `tests/wast.rs` pattern) so every JIT gap shows up RED. Host-call thunking + typed trap
   mapping + multi-value + NaN; `assert_invalid` stays on validator path.
2. **GC-on-JIT op emit** (D-211 bundle; §2) — see Active bundle below.
3. **ADR-0127 PHASE C** — cross-`Types` `canonicalEqual`; `gc/type-subtyping`
   assert_unlinkable 5→0.
4. Quick wins: **D-209** (lift leftover `>u32` offset check, `lower.zig:864-867` +
   `lower_simd.zig:372`; payload already u64), **D-198** (rec-group subtype), **D-210**
   (cross-module proper-tail-call — arm64 prologue cohort-save).
5. **Realworld GC/EH/TC producers** (§5; flake.nix `#gen`): `wasm_of_ocaml` / `emcc
   -fwasm-exceptions` / `guile-hoot`. Updates `toolchain_provisioning.md`.

## Active bundle

- **Bundle-ID**: `10.G-gc-on-jit-IT-1..N`
- **Cycles-remaining**: ~4-5
- **Continuity-memo**: PROVEN per-GC-op recipe + full struct design in
  **`.dev/phase10_g_op_bundle_plan.md`** §"GC-on-JIT emit design" (single source — do NOT
  re-derive). Verified x86_64 facts: pinned rt = R15; SysV args RDI/RSI, ret EAX; emit
  scratch = `spill_stage_gprs` = {R10(stage0), R11(stage1)} — NOT in regalloc pool
  (`allocatable_gprs` = {RBX,R12,R13,R14}; do NOT use R13/R14 as ad-hoc scratch); struct.get
  slab base uses R11 (stage1) so it can't alias the popped ref / result in stage0=R10;
  result via gprDefSpilled/gprStoreSpilled; encoders encMovRR/encMovImm32W/encMovImm64Q/
  encCallReg/encTestRR/encJccRel32/encMovR64FromMemDisp32/encAddRR (.slice()). x86_64
  ctx-op count test in dispatch_collector.zig is a LITERAL (`expectEqual(406, ...)`) — bump
  it per added op. struct offsets UNIFORM `8+idx*8` (ADR-0116 §3a); rooting DEFERRED.
- **First-op order**: i31 both arches DONE (`97658b5d`). struct.new_default/struct.get:
  arm64 DONE (A-2b-1 `68a2dbf0` / A-2b-2 `81bd0312`), x86_64 DONE (`fb991029`). **NEXT = A-3**:
  `struct.new` (variadic) — needs ADR-0060 amendment (force-spill alloc-op operands: fields
  read AFTER the alloc CALL) + variadic liveness (mirror `call` arm) + inline field-stores;
  both arches. Then `struct.set` (2→0). Then array.* / ref.cast / ref.eq.
- **Exit-condition**: all GC ops emit on both arches + spec corpus green via JIT mode (§1).

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 STALE (payload u64; lift leftover u32 check).
- **10.R** function-references — JIT emit present, corpus green; residual = D-198.
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = eh_frequency runner (I20), c_api tag
  accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit PARTIAL (D-211): i31 + struct.new_default/get DONE both arches;
  remaining = struct.new variadic / struct.set / array / ref.cast / ref.eq + ADR-0127
  PHASE C + D-198 + gc_stress (I19) + dart/hoot realworld (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

cyc251 (`68a2dbf0`) + cyc252 (`6d795cb5`) ubuntu-verified green `OK (HEAD=6d795cb5)`.
This cycle's x86_64 struct mirror (`fb991029`) verified locally by full `zig build test`
(arm64, EXIT=0, 0 errors, struct tests RUN not skipped) + `zig build -Dtarget=x86_64-linux-gnu`
(EXIT=0). x86_64 RUNTIME exec of the (now-ungated) struct round-trips verified by the ubuntu
kick launched against `fb991029` — verify `tail -3 /tmp/ubuntu.log` next resume; revert on FAIL.

**Session note (env instability + lesson)**: 2026-05-31 had real harness degradation
(status.claude.com: "Opus 4.7 elevated errors" unresolved; GitHub Task-hang bugs #49150/#43866)
— tool results arrived delayed/batched and two subagent delegations failed (false Usage-Policy
error; a `--fast`-only gate shipped a non-compiling runner.zig, reverted at `408e0a36`). The
x86_64 mirror was REDONE in MAIN with full `zig build test`. **Lesson**: `gate_commit.sh --fast`
DEFERS `zig build test`/`lint`; a worker gated only on `--fast` can ship red code — the parent's
independent full `zig build test` before push is the real gate. Prefer MAIN over subagents when
the harness is degraded.

## Key refs

- **ADR-0128** (Phase 10 100% both-backends — master plan); ADR-0127 (cross-module func
  type-identity); ADR-0115 §10 (non-moving β collector); ADR-0066 / ADR-0112+Amendment (TC).
- Debt: **D-211** (GC-on-JIT), D-209 (stale), D-202 / D-198 / D-210.
- Lessons `2026-05-31-wasmgc-jit-non-moving-deferred-rooting`,
  `2026-05-30-phase10-jit-coverage-partial-spec-corpus-interp`. ROADMAP §10.
