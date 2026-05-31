# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD**: `690bcf0d` — 10.G **array A-4** (`array.new` emit both arches). 2→1: pop init +
  length, marshal rt+typeidx+length+init → CALL **`jitGcAllocArrayFill`** trampoline (alloc +
  fill all elements with init INSIDE the trampoline — element count is runtime, mirrors interp
  arrayNew; no emitted loop). Both operands consumed into args before CALL → strict `is_call`.
  e2e `i32.const 7; i32.const 3; array.new 0; i32.const 1; array.get 0 → 7` ungated both arches.
  (array A-1 trampoline `06ebc165` + A-2 new_default/len `d6dea34d` + A-3 get/set `dc5869ca`
  DONE.) **D-212 filed**: init/field marshaling GPR-only (struct.new + array.new) — f32/f64
  element/field types deferred (latent until §1 JIT-corpus mode). Verified: arm64 `zig build
  test` EXIT=0 + lint 0 + x86_64 cross-compile EXIT=0; x86_64 RUNTIME = ubuntu gate.
- **Two execution paths (CODE-verified)**: spec corpus runs **interp-only**
  (`instance.invoke`→`_dispatch.run`, `instance.zig:169`); JIT corpus run = §1. JIT emits
  1.0/2.0 + TC + func-refs + EH + i31 + full struct family (both arches); remaining GC
  (array.* / ref.cast / ref.eq) interp-only (D-211). Green gc/EH corpus = INTERP.
- **ADR-0128 + ADR-0127 both Accepted** — no remaining user gate; loop runs autonomously.

## Active task — Phase 10 → 100% (ADR-0128)  **NEXT**

Six workstreams (ADR-0128), value-prioritized (NOT §10 table-first):

1. **Spec-corpus JIT execution mode** (§1) — verification backbone: run the official
   testsuite through the JIT (compile-every-fn → JIT-entry invoke → compare; wasmtime
   `tests/wast.rs` pattern) so every JIT gap shows up RED.
2. **GC-on-JIT op emit** (D-211 bundle; §2) — see Active bundle below.
3. **ADR-0127 PHASE C** — cross-`Types` `canonicalEqual`; `gc/type-subtyping` 5→0.
4. Quick wins: **D-209** (lift leftover `>u32` offset check; payload already u64), **D-198**
   (rec-group subtype), **D-210** (cross-module proper-tail-call — arm64 prologue cohort-save).
5. **Realworld GC/EH/TC producers** (§5; flake.nix `#gen`): `wasm_of_ocaml` / `emcc
   -fwasm-exceptions` / `guile-hoot`.

## Active bundle

- **Bundle-ID**: `10.G-gc-on-jit-IT-1..N`
- **Cycles-remaining**: ~4-5
- **Continuity-memo**: PROVEN per-GC-op recipe + full struct design in
  **`.dev/phase10_g_op_bundle_plan.md`** §"GC-on-JIT emit design" (single source — do NOT
  re-derive) + §"array.* sub-bundle". Verified x86_64 facts: pinned rt = R15; SysV args
  RDI/RSI(/EDX), ret EAX; emit scratch = `spill_stage_gprs` {R10=stage0, R11=stage1} — NOT in
  regalloc pool (`allocatable_gprs` {RBX,R12,R13,R14}; don't use R13/R14 ad-hoc); result via
  gprDefSpilled/gprStoreSpilled (encoders: read existing x86_64 struct files). x86_64 ctx-op
  count test in dispatch_collector.zig is a LITERAL — bump per added op. struct offsets UNIFORM
  `8+idx*8` (ADR-0116 §3a); array offsets `12+i*8` (4-mod-8, register-offset); rooting DEFERRED.
- **First-op order**: i31 + **struct.{new_default,get,new,set}** all DONE both arches. Per-GC-op
  touch-points (REUSE for array; full list in bundle plan §"array.* sub-bundle"): op-file +
  register in `collected_{arm64_ops,x86_64_ctx_ops}` + bump dispatch_collector.zig count LITERALS
  + `stackEffect` (or liveness special-case if variadic) + x86_64 `usesRuntimePtr` (R15 ops) +
  ungated `runI32Export` e2e (**hand-encode: i32.const ≥ 64 needs multi-byte signed LEB128** —
  bit 6 sign-extends; keep test values < 64) + ADR-0060 force-spill for alloc ops (is_call).
  array A-1 (trampoline) `06ebc165` + A-2 (new_default + len) `d6dea34d` + A-3 (get + set,
  register-offset + bounds-check) `dc5869ca` + A-4 (array.new via `jitGcAllocArrayFill`
  trampoline-fill, NOT an emitted loop) `690bcf0d` DONE both arches. **NEXT = array A-5 =
  `array.new_fixed` emit, both arches** (variadic, mirror struct.new): N = `ins.extra`
  (compile-time element count); alloc length-N array via `jitGcAllocArray(rt, typeidx, N)`;
  reload slab base AFTER the CALL; store the N popped element values inline at `[base+12+i*8]`
  (i=0..N-1, reverse-pop like struct.new). **Inclusive force-spill** for array.new_fixed (values
  read AFTER the alloc CALL → add to regalloc_compute.zig `is_call` as `true`, like struct.new).
  No bounds-check (length=N fixed). Then `array.get_s`/`array.get_u` (packed; needs valtype_byte
  — see D-212 FP gap too), bulk `array.fill`/`copy`/`init_*`. Then ref.cast / ref.test / ref.eq.
- **Exit-condition**: all GC ops emit on both arches + spec corpus green via JIT mode (§1).

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 STALE (payload u64; lift leftover u32 check).
- **10.R** function-references — JIT emit present, corpus green; residual = D-198.
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = eh_frequency runner (I20), c_api tag
  accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit PARTIAL (D-211): i31 + **full struct family** + **array.{new_default,
  len,get,set,new}** DONE both arches; remaining = array.new_fixed (A-5) + get_s/get_u + bulk /
  ref.cast / ref.eq + ADR-0127 PHASE C + D-198 + gc_stress (I19) + dart/hoot realworld (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

Prior `6dccd1b5` (array A-3) ubuntu-verified green `OK (HEAD=6dccd1b5)` this session. (The
`failed command:` line in `/tmp/ubuntu.log` is **benign** negative-test stderr — reproduces
locally with EXIT=0.) This turn = array A-4 `690bcf0d` (array.new emit both arches). Verified
locally: full `zig build test` (arm64) EXIT=0 + lint 0 + `zig build -Dtarget=x86_64-linux-gnu`
EXIT=0. The A-4 e2e is **ungated** — x86_64 RUNTIME exec of array.new is verified ONLY by the
ubuntu kick (Mac runs arm64). **ubuntu kick launched against `690bcf0d`** (user-requested stop:
NO ScheduleWakeup re-arm this turn). Verify `tail -3 /tmp/ubuntu.log` on next `/continue`;
revert the turn's commits to the last ubuntu-green HEAD (`6dccd1b5`) on FAIL.

**Lesson (still live)**: `gate_commit.sh --fast` DEFERS `zig build test`/`lint` (Step 4/5 own them) — parent's full `zig build test` before push is the real gate.

## Key refs

- **ADR-0128** (Phase 10 100% master plan); ADR-0127 (cross-module func type-identity);
  ADR-0115 §10 (non-moving β collector); ADR-0060 (force-spill + A-3 amend). ROADMAP §10.
- Debt: **D-211** (GC-on-JIT), D-209 (stale), D-202 / D-198 / D-210. Lessons
  `2026-05-31-wasmgc-jit-non-moving-deferred-rooting` + `...-partial-spec-corpus-interp`.
