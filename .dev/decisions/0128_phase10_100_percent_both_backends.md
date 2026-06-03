# 0128 — Phase 10 = 100% official Wasm 3.0 on BOTH backends (spec-corpus JIT execution mode + GC-on-JIT via non-moving op-emit)

- **Status**: Accepted (2026-05-31; user directive "100% にしてほしい") — **exit re-scoped by ADR-0133 (2026-06-03)**: the raw "pass=fail=skip=0 on BOTH backends" was unreachable in-phase (multi-memory→§14 / GC-rooting→§11 JIT skips); now interp 100% + JIT 0-real-fail + JIT-skip deferred-allowlist. The 100% spirit is preserved; deferred items are forward-ref'd, not dropped.
- **Date**: 2026-05-31
- **Author**: claude (with user audit + web research)
- **Tags**: Phase 10, exit criterion, JIT, GC, spec corpus, both-backends, non-moving collector, deferred rooting, memory64, realworld toolchains, D-211, D-209, D-202
- **Paired**: ADR-0127 (cross-module func type-identity — Accepted here); D-211 (GC-on-JIT); D-209 (memory64 offset, dissolved here)
- **Amends**: ROADMAP §10 exit handling (per §18 — §9/§10 phase-exit change requires an ADR FIRST)

## Context

A 2026-05-30 user audit ("does Phase 10 cover wasm-3.0 INCLUDING the JIT,
no residuals, should-be design — with evidence?") + a CODE verification
(not doc prose) established:

- The spec corpus runs via the **INTERPRETER** (`instance.invoke` →
  `_dispatch.run`, `src/zwasm/instance.zig:169`). The JIT is a SEPARATE
  surface (`runI32Export` + `test-realworld-run-jit`).
- The JIT **emits** Wasm 1.0/2.0 + tail-call + function-references + EH
  (`codegen/{arm64,x86_64}/ops/wasm_3_0/`). It does **NOT** emit **GC**
  (no `struct*`/`array*`/`ref_cast`/`ref_test`/`i31*` file) → GC is
  interp-only (D-211).
- The §10 exit criterion ALREADY requires "all proposals' spec tests
  pass=fail=skip=0 on **both backends**" — but the spec corpus never runs
  through the JIT, so "both backends" was unverified, and the close-
  invariant `I16` SKIP ("regalloc 3-axis … deferred to 10.E/G JIT")
  papered over the GC-on-JIT gap. "10.P close-eligible" counted 8 SKIPs
  as deferred, masking the gap from the exit criterion.

**User directive**: these are all official Wasm 3.0; reach **100%** — do
not close Phase 10 with the gap deferred. This ADR codifies the plan and
the (web-researched) realization of each previously-"externally-blocked"
item, so the loop can carry it to completion.

## Decision

Phase 10 closes only at **100% of the official Wasm 3.0 testsuite,
pass=fail=skip=0, on BOTH the interpreter and the JIT.** Six workstreams,
each with a researched realization:

### 1. Spec-corpus JIT execution mode (the verification mechanism)

Add a JIT execution path to the wasm-3.0 spec runner: compile every
function in each `module`, instantiate, invoke the exported function via
the **JIT entry** (not `_dispatch.run`), compare against `assert_return`
/ `assert_trap`. This is the wasmtime `tests/wast.rs` pattern (Cranelift
is JIT-only and runs the UNMODIFIED upstream testsuite). Gotchas to
handle: host/imported-func thunking from JIT'd code, typed trap mapping
(`assert_trap` incl. GC null-deref / failed `ref.cast` / array-OOB),
multi-value returns, NaN canonical/arithmetic patterns, and keeping
`assert_invalid`/`assert_malformed` on the validator path (never reach
the JIT). A per-backend `should_fail` list tracks the not-yet-green set,
flipped as features land. **This makes "both backends" mechanically
true, not aspirational**, and is reusable for every future proposal.

### 2. GC-on-JIT emit via NON-MOVING op-emit (rooting deferred — SAFE)

zwasm's collector is **non-moving mark-sweep** (`collector_mark_sweep.zig`;
`GcRef` = u32 slab offset; bump allocator; β does NOT reclaim yet — sweep
wired, free-list/compaction defer to Phase 11 per ADR-0115 §10). Two
consequences make this the easy path, NOT the regalloc-3-axis hard path
I16 implied (that is the MOVING-collector worst case — V8/SpiderMonkey):

- **Non-moving ⇒ refs never relocate** ⇒ no pointer rewriting, no precise
  stack maps for relocation.
- **No reclamation yet ⇒ nothing freed ⇒ a missed root cannot cause
  use-after-free.** So GC alloc may be JIT-emitted **with NO safepoints /
  stack-maps / root-spilling** in Phase 10. Rooting becomes load-bearing
  only when reclamation lands (Phase 11) — and even then a non-moving
  collector needs only a **conservative native-stack scan** (JSC Riptide
  style) requiring ZERO codegen changes.

So GC-on-JIT in Phase 10 = **emit the ops** (same shape as the landed
EH/TC op files), no register-allocator surgery. Per-op lowering
(`codegen/{arm64,x86_64}/ops/wasm_3_0/` new files):

- `struct.new`/`_default`: runtime-call alloc helper (bump cursor +
  header) — preferred over inline-bump so the path survives the Phase-11
  free-list change; then store fields inline.
- `struct.get`/`_s`/`_u`/`struct.set`: `base = heap_base + ref` (trap on
  null), `[base + field_off]` load/store; packed i8/i16 → sign/zero
  extend on `_s`/`_u`.
- `array.*`: layout = header + `len:u32` + inline elements; `array.len`
  loads len; `get*`/`set` do `idx u>= len → trap` then indexed access.
- `ref.cast`/`ref.test`: **Cohen display** — RTT carries a supertype
  vector (self last); test `v1 <: v2` (depth `n2` constant) = `if n1 <
  n2 → fail; load v1.vec[n2-1]; compare to v2`. The `n1 >= n2` guard is
  load-bearing (omitting it = CVE-2024-4761 OOB). `ref.test` materializes
  0/1; `ref.cast` traps on fail.
- `ref.i31`/`i31.get_s`/`_u`: tagged, non-allocating (`(v<<1)|1`;
  get_s = ASR 1, get_u = LSR 1).
- `ref.eq` (u32 compare — valid because non-moving), `ref.is_null`,
  `br_on_cast`/`br_on_cast_fail` (display check + branch).

### 3. ADR-0127 Accepted — cross-module func import type-identity

The 4 `gc/type-subtyping` `assert_unlinkable` that wrongly link must
reject. ADR-0127 (cross-`Types` `canonicalEqual` + supertype-reach) is
**Accepted** by this ADR; the loop implements PHASE C per its design.

### 4. D-209 dissolved — memory64 offset is NOT layout-blocked

`ZirInstr.payload` is already **u64** (10.Z `5d…`; `zir.zig:303,524`).
The official memory64 corpus's max **executed** offset is **2^32−1**
(`address64.wast offset=4294967295`); offsets ≥ 2^32 appear only in
`assert_malformed`/`assert_invalid` (which stay on the validator path and
never reach the lowerer), so spec-100% does NOT need the lowerer to accept
> 4 GiB. The only residual is a leftover `> maxInt(u32)` reject in
`readMemargOffset` (`lower.zig:864-867`) + `lower_simd.zig:372`; lift it
to return u64 + ensure 64-bit `base+offset` math with wrap-trap. No
ZirInstr layout change, no side-table (D-209's old discharge plan is
obsolete). Add an edge-case fixture for offset `> 2^32−1` (corpus won't).

### 5. Realworld toolchains provisioned (flake.nix `#gen`)

Per the updated [`toolchain_provisioning.md`](../toolchain_provisioning.md):
`wasm_of_ocaml` (opam; GC+EH+tail-call triple crown), `emcc
-fwasm-exceptions` (nixpkgs `emscripten`; native Wasm EH; `EM_CACHE`
gotcha), `guile-hoot` (nixpkgs; GC+tail-call; link `reflect.wasm`+
`wtf8.wasm`). **Lightest lever for per-opcode coverage no compiler
reliably emits: hand-written `.wat` + `wat2wasm --enable-all`** (WABT,
already pinned) — zero host imports, exact opcodes. Dart `dart2wasm`
(nixpkgs `dart`) is parse/validate-only (heavy JS import surface).

### 6. Close-invariant reframe

`check_phase10_close_invariants.sh`: `I16` (GC-on-JIT), `I3`/`I5`
(GC fixtures), `I20` (runner deep content) flip from permanent SKIP to
REAL targets gated on workstreams 1+2. `I21` realworld stays partially
toolchain-gated but its GC/EH/TC producers (ocaml/emcc/hoot) are now
provisioned, not "tool-gated". 100% means these PASS, not SKIP.

## Alternatives considered

- **Close Phase 10 with GC interp-only** (the prior "close-eligible"
  posture). Rejected: contradicts the §10 exit criterion ("both
  backends") and the user's 100% bar. Would ship a JIT that silently
  can't run any GC program.
- **Moving/compacting collector + precise stack maps + regalloc-3-axis**
  (the V8/SpiderMonkey model; the original I16 framing). Rejected for
  Phase 10: unnecessary for a non-moving collector; precise stack maps
  are owed only if/when zwasm goes moving. Deferring it is the correct
  surgical scope.
- **Skip the spec-corpus JIT mode; trust `runI32Export` + realworld for
  JIT coverage.** Rejected: that surface is thin + hand-curated and
  cannot prove pass=fail=skip=0 against the official testsuite. "Both
  backends" needs the official corpus driving the JIT.

## Consequences

**Positive**: Phase 10 reaches genuine 100% (both backends, official
corpus). The spec-corpus JIT mode is permanent infra reusable for all
later proposals. GC-on-JIT lands at op-emit cost (no regalloc surgery)
because the collector is non-moving. D-209 + the realworld toolchains
turn out far cheaper than "externally blocked" framing claimed.

**Negative / risk**: Phase 10 grows (the prior close-eligible verdict is
retracted). The spec-JIT-mode harness is non-trivial (host thunking, trap
mapping). GC-on-JIT is multi-cycle (a bundle). Mitigation: workstream 1
makes every gap measurable first (red), so the rest is TDD-green-driven.

**Neutral**: rooting precision is explicitly Phase-11 work (when
reclamation lands); this ADR records the deferral as deliberate + safe,
not an oversight.

## Removal condition

Retires when Phase 10 closes with the official Wasm 3.0 testsuite at
pass=fail=skip=0 on BOTH backends (spec-corpus JIT mode green for all
proposals incl. GC), ADR-0127 PHASE C landed (assert_unlinkable 5→0),
D-209 check lifted, and the realworld GC/EH/TC producers green. Status →
`Closed (Phase 10 DONE)`.

## References

- ADR-0127 (cross-module func type-identity — Accepted here); ADR-0115
  §10 (non-moving β collector; reclamation → Phase 11); ADR-0116 (GcRef
  u32 encoding); ADR-0113 (regalloc terminator/N-successor — NOT extended
  for GC here).
- D-211 (GC-on-JIT), D-209 (memory64 offset — dissolved), D-202 (cross-
  module func import / PHASE C), D-198 (rec-group subtype), D-179
  (toolchain bake).
- ROADMAP §10 exit criterion; `scripts/check_phase10_close_invariants.sh`
  (I3/I5/I16/I20/I21); `src/zwasm/instance.zig:169`; `src/ir/lower.zig`
  (readMemargOffset); `collector_mark_sweep.zig`; `heap.zig`.
- Lessons `2026-05-30-phase10-jit-coverage-partial-spec-corpus-interp`,
  `2026-05-31-wasmgc-jit-non-moving-deferred-rooting` (this ADR's research).
- WasmGC: [gc/MVP.md](https://github.com/WebAssembly/gc/blob/main/proposals/gc/MVP.md)
  (RTT supertype-vector), [V8 wasm-gc-porting](https://v8.dev/blog/wasm-gc-porting),
  [WebKit Riptide](https://webkit.org/blog/12967/understanding-gc-in-jsc-from-scratch/)
  (non-moving ⇒ conservative roots), [CVE-2024-4761](https://buptsb.github.io/blog/post/CVE-2024-4761-%20v8%20missing%20check%20of%20WasmObject%20type%20cast%20causes%20type%20confusion%20and%20OOB%20access.html)
  (cast guard). memory64: [spec memory64 Overview](https://github.com/WebAssembly/spec/blob/wasm-3.0/proposals/memory64/Overview.md)
  (`memarg ::= a:u32 o:u64`). JIT testsuite: [wasmtime testing](https://docs.wasmtime.dev/contributing-testing.html).
  Toolchains: [wasm_of_ocaml](https://ocsigen.org/js_of_ocaml/latest/manual/wasm_overview),
  [emscripten EH](https://emscripten.org/docs/porting/exceptions.html),
  [guile-hoot](https://files.spritely.institute/docs/guile-hoot/latest/Compiling-from-the-command-line.html).

## Revision history

| Date | Commit | Summary |
|------|--------|---------|
| 2026-05-31 | `801037b3` | Initial — Phase 10 100% both-backends plan; accepts ADR-0127; dissolves D-209; corrects D-211 difficulty (non-moving ⇒ op-emit, deferred rooting); provisions realworld toolchains. |
