# ADR-0200 — JIT-backed embedding API (C + Zig), opt-in engine selection

> **Doc-state**: ACTIVE
> **Status**: ACCEPTED (user directive 2026-06-20)
> **Supersedes (in part)**: the *assessment-stage* "interp-only facade"
> posture of `.dev/architecture/jit_facade_integration_scope.md` and the
> implicit reading of ADR-0109 that the public facade is interp-bound.

## Context

The public C API (`src/api/instance.zig` — `wasm_func_call` →
`dispatch.run`) and the public Zig facade (`src/zwasm/*`) are hard-wired
to the **interpreter**; there is no engine-selection point and the JIT
(`JitInstance`, `src/engine/runner.zig:819`) is reachable only via the
CLI `--engine jit`.

This interp-only state was **never a ratified/user-mandated decision**.
The only user hard-constraint from the 2026-06-08 security campaign was
*commit-message neutrality* (memory `project_security_hardening_campaign`).
"Facade/C-API is interp-only" was an **as-built state** plus an
AI/campaign decision to **defer** the JIT-facade integration (D-314 item
(d)). `jit_facade_integration_scope.md` itself labels it ASSESSMENT —
"no decision to build yet" — and names the dominant blocker as the
generic argument-ABI trampoline (#1), **not** a security veto. Per
memory `feedback_ai_invented_by_design_not_sacred`, an AI-invented
transitional "by design" is a hypothesis to re-examine, not a sacred
deferral.

Two facts make re-examination compelling now:

- **SIMD is JIT-only.** The interpreter does not execute v128
  (`src/interp/` has no SIMD; `api/instance.zig:2613` self-documents).
  So interp-only API = **modules that execute v128/SIMD cannot run
  through the public C/Zig API at all** — a full-featured gap, not just
  a speed gap.
- **The security delta is small.** The JIT already runs *untrusted*
  modules via the CLI under the full ADR-0179 sandbox triad
  (interrupt/fuel/memory/table-cap, both arches), fuzz 0-crash, realworld
  56/56 wasmtime byte-match. The D-314 sandbox triad is CLOSED. cw
  consumes the interp facade and is dogfood-complete (ADR-0168), so no
  compat lock.

## Decision

Build a **JIT-backed embedding API** for both the C and Zig surfaces,
with **selectable engine, JIT as the DEFAULT** (user directive
2026-06-20):

- Add an engine knob to `Engine.InitOpts` (Zig) and the C surface.
  **Default = JIT** (the speed + SIMD win is the whole point); **interp
  is explicitly selectable** as the conformance oracle / portability
  fallback (e.g. an arch with no JIT backend). v1 ABI compat is out of
  scope (ADR-0156), so a JIT default is free to take.
- `Module.instantiate` forks into the JIT `setupRuntime`
  (`src/engine/setup.zig`) when JIT is selected; accessors gain the
  `runtime == null` (JIT instance) branch the seam asserts currently
  forbid.
- Host imports are bridged to the JIT Linker `host_calls`.

This reverses the *assessment-stage* interp-only posture. ADR-0109's
facade design stands; this ADR adds the engine dimension to it.

### API-design phase is prioritized + research-driven + self-verified

The post-D-477 implementation is a **prioritized, first-class phase**
(wired into the bundle/handover, not a someday-debt). Within it:

- **Peer 裏取り FIRST**: study how senior runtimes expose engine choice
  through their *embedding* APIs — wasmtime `Config`/`Engine`/`Strategy`
  (Cranelift vs Winch vs interp `pulley`) + default, wasmer
  `Store`/`Engine`/compiler backends, V8/Wasmtime `Func::call` typed vs
  untyped. Feed the knob shape + default posture from that.
- **Self-verification via a mini-consumer** (NOT via cw — ClojureWasm
  validation is cw's own responsibility). Build a small first-party
  embedder under the repo (a C program against `include/zwasm.h` + a Zig
  program against `src/zwasm/*`) that instantiates a module, selects
  JIT, calls a multi-arg export AND **a v128/SIMD export**, and asserts
  the result — the test that proves the JIT-backed API actually delivers
  SIMD + speed end-to-end. Wire it into the gate.

## Sequencing (gating order)

1. **D-477** — the generic multi-arg invoke-by-name trampoline
   (arm64 ✓, x86_64 SysV ✓; Win64 + CLI arg-threading + FP + v128
   remaining). **This IS scope-doc blocker #1** — the gating
   prerequisite for any JIT-backed API call with real arguments.
2. API engine opt-in + `Module.instantiate` JIT fork (#2) + accessor
   `runtime==null` branches (#3).
3. Host-import → JIT `host_calls` bridge (#4).
4. D-314 sandbox-parity sign-off at the API entry (largely closed; verify).
5. Win64 native JIT (#6).

## Consequences

- API embedders gain JIT speed **and** SIMD execution (the headline win).
- The interp path stays the default and the correctness oracle; both
  engines remain spec-conformant (differential-fuzzed, D-469).
- The seam `assert(runtime != null)` mutators in `zwasm/instance.zig`
  are replaced by per-engine branches (tracked under D-314(d)).
- No autonomous release implication (ADR-0156): this is completion work,
  not a version gate.
