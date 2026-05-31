# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD**: `dc5869ca` — 10.G **array A-3** (`array.get` + `array.set` emit both arches).
  Both: null-trap ref, reload slab, ADD ref→base, load length `[base+8]`, UNSIGNED bounds-check
  (`index >= length` → trap; covers negative idx), base += 12, **register-offset** element
  access `[base + index*8]` (runtime + 4-mod-8 offset → arm64 LDR/STR `[Xn,Xm,LSL#3]`, x86_64
  SIB `[base+idx*8]`; x86_64 needs RAX as 3rd scratch). e2e set-then-get `elem[1]=55 → 55`
  ungated both arches. (array A-1 trampoline `06ebc165` + A-2 new_default/len `d6dea34d` DONE.)
  Verified: arm64 `zig build test` EXIT=0 + lint 0 + x86_64 cross-compile EXIT=0; x86_64 RUNTIME
  = ubuntu gate. Recipe: bundle plan §"array.* sub-bundle".
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
  register-offset + bounds-check) `dc5869ca` DONE both arches. **NEXT = array A-4 = `array.new`
  (variadic-ish) emit, both arches** (recipe in bundle plan §"array.* sub-bundle"): pop init +
  length (2→1); length → arg2, CALL `jitGcAllocArray` → ref; then a **runtime fill loop** stores
  the init value to all `length` elements (`[base+12+i*8]` for i=0..length-1) — NEW vs struct
  (struct.new's field count is compile-time; array length is runtime → emit a counted loop:
  init a counter, CMP vs length, store, increment, B.cond back). init value read AFTER the alloc
  CALL → **inclusive force-spill** (add `array.new` to regalloc_compute.zig `is_call` as
  inclusive, like struct.new). Then A-5 `array.new_fixed` (variadic, mirror struct.new extra=N).
  get_s/get_u (packed) + bulk fill/copy = defer. Then ref.cast / ref.test / ref.eq.
- **Exit-condition**: all GC ops emit on both arches + spec corpus green via JIT mode (§1).

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 STALE (payload u64; lift leftover u32 check).
- **10.R** function-references — JIT emit present, corpus green; residual = D-198.
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = eh_frequency runner (I20), c_api tag
  accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit PARTIAL (D-211): i31 + **full struct family** + **array.{new_default,
  len,get,set}** DONE both arches; remaining = array.new/new_fixed (A-4/A-5) + get_s/get_u + bulk
  / ref.cast / ref.eq + ADR-0127 PHASE C + D-198 + gc_stress (I19) + dart/hoot realworld (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

Prior `16ea1272` (array A-2) ubuntu-verified green `OK (HEAD=16ea1272)` this session. (The
`failed command:` line in `/tmp/ubuntu.log` is **benign** negative-test stderr — reproduces
locally with EXIT=0.) This turn = array A-3 `dc5869ca` (array.get + array.set emit both arches).
Verified locally: full `zig build test` (arm64) EXIT=0 + lint 0 + `zig build
-Dtarget=x86_64-linux-gnu` EXIT=0. The A-3 e2e is **ungated** — x86_64 RUNTIME exec of
array.get/set is verified ONLY by the ubuntu kick (Mac runs arm64). Verify
`tail -3 /tmp/ubuntu.log` next resume; revert the turn's commits to the last ubuntu-green HEAD
(`16ea1272`) on FAIL.

**Lesson (still live)**: `gate_commit.sh --fast` DEFERS `zig build test`/`lint` (Step 4/5 own
them); the parent's independent full `zig build test` before push is the real gate.

## Key refs

- **ADR-0128** (Phase 10 100% master plan); ADR-0127 (cross-module func type-identity);
  ADR-0115 §10 (non-moving β collector); ADR-0060 (force-spill + A-3 amend). ROADMAP §10.
- Debt: **D-211** (GC-on-JIT), D-209 (stale), D-202 / D-198 / D-210. Lessons
  `2026-05-31-wasmgc-jit-non-moving-deferred-rooting` + `...-partial-spec-corpus-interp`.
