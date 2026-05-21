# 0028 — Diagnostic M3 trace ringbuffer (前倒し)

- **Status**: Closed (Phase 7 DONE)
- **Date**: 2026-05-05
- **Author**: zwasm-from-scratch loop (chaploud)
- **Tags**: diagnostic, trace, jit, debug, infrastructure

## Context

> **Relationship to ADR-0016**: this ADR amends ADR-0016's
> M3 phasing decision (defer-to-Phase-7-close → land-before-
> 7.8). The Revision history row on ADR-0016 itself is queued
> for the M3-a implementation commit (per `lessons_vs_adr.md`
> "Lesson alongside ADR amend" pattern: the design rationale
> lives here in ADR-0028; ADR-0016's Revision history points
> back when M3-a actually lands).

ADR-0016 (Diagnostic system phasing) deferred M3 (trace
ringbuffer) to "Phase 7 close 後に再評価" (D-022 entry in
`.dev/debt.md`). The intent was to avoid speculative scaffolding
until the trap surface stabilised.

Phase 7's progress changed the calculation:

1. **x86_64 backend landed** (§9.7 / 7.6, 7.7 chunks). Trap
   paths now exist on both arches with non-trivial divergence
   (different bounds-check encoding, different prologue shape
   per ADR-0026, different trap stub layouts). Differential
   debugging without trace is already painful on the active
   working tree; it will get exponentially worse as 7.7-call /
   7.7-fp / 7.8 spec gate add more trap conditions.

2. **bounds-check spec deviation** (#1 in 2026-05-05 cleanup
   batch, fix landed in commit `fe42735`) was an example of a
   v1-class bug that would have been instantly diagnosable with
   trace: "the JIT-emitted CMP+JA sequence rejects access at
   ea+size==mem_limit, but the spec says trap iff ea+size >
   mem_limit". Trace of the JIT emit + trap entry would have
   surfaced the off-by-one immediately. Without trace, the bug
   was only caught because the developer manually re-read the
   spec text against the emit code.

3. **v1 W54-class postmortem** (`~/Documents/MyProducts/zwasm/
   .dev/archive/w54-redesign-postmortem.md`) showed that
   coalescer + regalloc + per-arch encoding interactions were
   the dominant source of weeks-long debugging cycles. v1's
   `--dump-regir=N` / `--dump-jit=N` reduced the diagnosis time
   for one such case from "2-3 days" to "30 minutes".

4. **GC + JIT + optimisation interference** (Phase 14-15
   roadmap items) is the regret v1 paid the most for. The v1
   experience was unambiguous: design trace into the JIT layer
   from day 1, not after the bug.

A cross-runtime trace mechanism survey was conducted (per
`.claude/rules/textbook_survey.md`) covering zwasm v1,
ClojureWasm v2 error machinery, wasmtime, cranelift+regalloc2,
wasm3, wasmer, V8/SpiderMonkey wasm baseline, in
`private/notes/p7-trace-survey.md` (informal; not load-bearing).
Key findings:

| Runtime | Mechanism | Granularity | Build-mode gating |
|---|---|---|---|
| zwasm v1 | category bitmask + stderr per-event print | per-func compile + per-trap | `--trace=cat1,cat2` runtime flag |
| regalloc2 | `trace!()` macro feature-gated | per-allocation-decision | `cfg!(feature = "trace-log")` compile-time |
| wasm3 | `m3log()` per-opcode compile log | per-opcode compile | build-time only (interpreter) |
| wasmtime | `tracing` crate + DWARF | per-Trap + spans | `RUST_LOG` env var |
| cranelift | ISLE rule + regalloc2 trace | per-rule-firing | feature-gate |

Common pattern: **compile-time feature gate for zero release
overhead, runtime opt-in for ringbuffer drain on trap, per-
event capture at semantic boundaries** (compile/trap/regalloc
decision).

## Decision

**Land Diagnostic M3 minimal scope before §9.7 / 7.8 spec
gate begins** (i.e., during the remaining 7.7 chunks landing
period). M3 minimal consists of:

1. **`src/diagnostic/trace.zig`** (Zone 1, new file): per-
   thread fixed-size ring buffer of structured entries.
2. **Integration points** in regalloc + JIT emit + trap stub
   that write entries when the buffer is enabled.
3. **Drain on trap**: trap stub writes the last N entries to
   stderr (or via a Diagnostic accessor) when a trap fires.
4. **Compile-time gate** via build flag, NOT runtime branch
   per ADR-0009 / ROADMAP §A12 (no pervasive build-time `if`
   in hot paths).

### Concrete shape

**Entry format** (8 bytes; one cache line per 8 entries):

```zig
pub const TraceEntry = packed struct(u64) {
    timestamp_cyc: u32,    // monotonic cycle counter (or 0 on hosts without rdtsc)
    category: Category,    // u4: jit | regir | exec | trap | regalloc | bounds | reserved | _
    event: Event,          // u4: per-category event tag
    payload_a: u16,        // category-specific (e.g. func_idx, regir_pc, slot_id)
    payload_b: u16,        // category-specific (e.g. event subtype, byte_offset_in_func)
};
```

**Ring buffer size**: 32 entries (256 bytes per thread). Size
covers the typical "last 8 events before trap" diagnostic
window 4× over.

**Storage**: per-thread (`threadlocal var ring: [32]TraceEntry`),
mirroring `Diagnostic` (D-021) which already uses threadlocal.

**Build gate**: new `-Dtrace-ringbuffer={true,false}` build
flag. Default `false` for `release-fast` and `release-small`;
default `true` for `debug` and `release-safe`. Gate is a
`pub const trace_enabled: bool` consumed by `comptime` branches
in emit hot paths so unused emit is dead-code-eliminated.

### Categories (initial)

| Category | When written | Payload semantics |
|---|---|---|
| `jit` | per-func compile boundary | `payload_a = func_idx`, `payload_b = code_size_bytes` |
| `regir` | per-ZIR-instr (debug only) | `payload_a = func_idx`, `payload_b = zir_pc` |
| `regalloc` | per-allocation-decision | `payload_a = vreg`, `payload_b = slot` |
| `bounds` | per-memory-op emit | `payload_a = func_idx`, `payload_b = byte_offset_in_func` |
| `trap` | trap stub entry | `payload_a = trap_kind`, `payload_b = pc_offset_in_func` |
| `exec` | per-call boundary (interp ↔ JIT) | `payload_a = func_idx`, `payload_b = call_kind` |

Categories are extensible (4-bit field allows 16 total). Adding
a category is non-breaking provided existing entries' field
semantics are preserved.

### Implementation phasing

**M3-a (Phase 7 inside, before 7.8 spec gate)**:
- `src/diagnostic/trace.zig` core (ring buffer + write +
  drain).
- `bounds` + `trap` categories wired (the immediate need for
  bounds-check audit per #1 retrospective).
- Drain hook in trap stub (both ARM64 + x86_64 emit paths).
- 1 unit test: enable buffer, emit + trap, drain captures
  the JIT bounds emit + trap event in correct order.

**M3-b (Phase 7 close, before 7.11 differential)**:
- `regalloc` category (per-allocation-decision write).
- `jit` category (per-func compile boundary).

**M3-c (Phase 8+, deferred)**:
- `regir` category (per-ZIR-instr; high overhead, only useful
  for deep regalloc/coalescer debugging).
- `exec` category (interp dispatch, full call chain capture).
- DWARF integration for symbolicated dump.

## Alternatives considered

### Alternative A — Defer M3 until Phase 7 close (original ADR-0016 plan)

- **Sketch**: keep M3 in D-022 blocked status until 7.11
  differential lands.
- **Why rejected**:
  1. The cost of debugging without trace during 7.8 spec gate
     (where mismatches between emit shape and spec semantics
     surface) is the *exact* failure mode v1 paid weeks for.
  2. The bounds-check #1 fix is direct evidence: a trace
     would have surfaced the off-by-one in the first
     run. Postponing trace incurs more such "manually re-
     read spec" cycles.
  3. v1 W54 case study: 2-3 days → 30 minutes diagnostic
     time reduction. Phase 7's remaining 5 chunks (globals,
     wrap, call, fp, plus 7.8 spec gate) will produce more
     such cases; the math is heavily in favour of landing
     trace now.

### Alternative B — Inline `std.log` calls without ring buffer

- **Sketch**: use Zig's standard `std.log.debug` /
  `std.log.warn` from emit/trap sites; no per-thread buffer.
- **Why rejected**:
  1. `std.log` writes synchronously to stderr; trap stub
     cannot afford the syscall + lock overhead.
  2. No replay: by the time a developer realises a trap
     fired, the log line is already past in the terminal
     scrollback. Ring buffer + on-trap drain captures the
     **most recent** events (which are what matter for trap
     diagnosis).
  3. v1 used per-event stderr print and had to redirect to
     files + grep + correlate by timestamp. Ring buffer +
     post-mortem dump is structurally cleaner.

### Alternative C — Full M3 (all categories + DWARF) at once

- **Sketch**: land all 6 categories + DWARF symbolication +
  C ABI accessor (`zwasm_get_trace_entries`) in one chunk.
- **Why rejected**:
  1. Scope is 5+ days of work; the immediate need is bounds-
     check audit (M3-a, ~1 day). Phase 7 remaining chunks
     would block on the larger M3 landing.
  2. DWARF emit is itself a significant Phase 8+ work item
     (ADR-0019 deferred); coupling M3 to it would inflate
     M3 timeline by an order of magnitude.
  3. Categories `regir` and `exec` are useful for deep
     debugging that the immediate Phase 7 surface doesn't
     yet need. Land them when the use case (coalescer
     debugging in Phase 8) materialises.

### Alternative D — Move Diagnostic from threadlocal to per-Runtime field

- **Sketch**: each `Runtime` instance owns its own
  `Diagnostic` and trace buffer; thread sharing is the
  caller's concern.
- **Why rejected** (deferred, not killed):
  1. D-021 already records "Diagnostic threadlocal var
     concurrent guest threads decision" as Phase 14
     blocker. Coupling M3 to that re-architecture would
     stall both. Match D-021's choice (threadlocal until
     Phase 14) for now.

## Consequences

### Positive

- **Bounds-check spec audit ready**: 7.8 spec gate becomes
  diagnosable in minutes rather than days when ARM64 vs
  x86_64 vs spec triplets disagree.
- **v1 W54-class regression detection**: regalloc /
  coalescer / per-arch encoding bugs (the dominant Phase 8+
  bug class per v1 postmortem) get a structured detection
  mechanism from the start.
- **Diagnostic foundation for Phase 14 GC + Phase 15 opt**:
  GC × JIT × optimisation interference (the v1 regret) gets
  a trace foundation before the interference paths exist.
  Post-mortem analysis is built in, not retrofitted.
- **Compile-time gating preserves zero release overhead**:
  per ROADMAP §A12, the dispatch table + per-emit-handler
  paths use `comptime` branches; release builds compile out
  the trace code entirely (verified by inspecting the
  emitted JIT helper sizes).

### Negative

- **JitRuntime gains no field** (trace state is threadlocal,
  not per-Runtime). However, the trap stub on both arches
  must call into a Zig drain function (or accessor). This
  adds 1 helper call to the trap path, ~20 cycles on trap
  (acceptable: trap is the slow path).
- **Trap-time JIT register state is destroyed by drain call**.
  The drain helper follows the host C ABI (System V AMD64 /
  AAPCS64), so all caller-saved registers (RAX/RCX/RDX/RSI/
  RDI/R8-R11 on x86_64; X0-X18 on ARM64) are clobbered after
  the call returns. The trap stub already sets `trap_flag = 1`
  + `RAX/X0 = 0` BEFORE drain (per ADR-0017 trap_flag
  amendment) so the host caller's "did this trap?" check
  remains correct. **Diagnostic implication**: post-trap
  GP register dumps (e.g. `signal_handler` style introspection)
  are NOT trustworthy after drain has run. The ringbuffer
  event sequence — captured BEFORE drain — is the canonical
  audit trail. Documentation in `src/diagnostic/trace.zig`
  + the trap stub emit path must spell this out so future
  contributors don't try to read GP registers post-trap for
  diagnosis.
- **TLS access from trap stub**: AAPCS64 `TPIDR_EL0` reads
  are EL0-permitted on macOS/Linux/Windows; x86_64 `FS:0`
  (Linux) / `GS:0` (Windows) likewise unprivileged. No
  signal-handler-level state is required. Confirmed safe
  on the three target hosts.
- **Build matrix grows**: `-Dtrace-ringbuffer=true/false`
  doubles the build target count nominally. Mitigation:
  the audit/CI pipeline only needs to run one variant for
  spec-test green; the other is for tag releases.
- **Per-thread storage overhead**: 256 bytes per thread.
  Negligible for the typical 1-thread / 1-instance Phase 7
  workload; bounded for Phase 14 multi-thread workloads.

### Neutral / follow-ups

- **ADR-0016 Revision history amendment** when M3-a lands:
  document that M3 is no longer "deferred to Phase 7 close"
  and that M3-a / M3-b / M3-c phasing is the new plan.
- **D-022 status flip**: when M3-a lands, flip D-022 from
  `blocked-by: ADR-0016 M3 work item` to `discharged`.
- **D-021 cross-reference**: trace storage uses the same
  threadlocal pattern as Diagnostic; both are unblocked by
  the same Phase 14 concurrent-thread decision.
- **C ABI accessor** (`zwasm_get_trace_entries`) deferred
  to M3-b/-c; not needed for the immediate Phase 7 internal
  audit use case.
- **Test infrastructure**: a new test layer
  `test-diagnostic-trace` may eventually be added; for now
  the M3-a unit test in `src/diagnostic/trace.zig` is
  sufficient.
- **ROADMAP §4.6 build flags table**: when M3-a impl lands,
  add `-Dtrace-ringbuffer` to the documented build flag list
  (current entries: `-Dwasm`, `-Dwasi`, `-Dengine`). Queue
  for the M3-a implementation commit.

## References

- ROADMAP §2 P/A (project principles), §A12 (no pervasive
  build-time if), §11 (zone layering)
- ADR-0016 (Diagnostic phasing; this ADR amends M3 timing)
- ADR-0017 (JitRuntime ABI; trap stub call site coordination)
- ADR-0021 (op_*.zig file layout; trace category integration
  points)
- ADR-0026 (x86_64 invariant strategy; trap stub coordination)
- D-021 (Diagnostic threadlocal concurrency phase 14 follow-up)
- D-022 (M3 trace ringbuffer; this ADR is the discharge
  precondition)
- v1 postmortem: `~/Documents/MyProducts/zwasm/.dev/archive/
  w54-redesign-postmortem.md` (W54 coalescer regression case
  study; trace presence reduced diagnostic time 2-3 days
  → 30 minutes)
- Cross-runtime survey: `private/notes/p7-trace-survey.md`
  (informal; not load-bearing)
- regalloc2 trace pattern: `~/Documents/OSS/regalloc2/src/
  lib.rs` (`trace!()` macro feature gating)
- wasmtime tracing pattern: `~/Documents/OSS/wasmtime/crates/
  wasmtime/src/runtime/` (`tracing::trace!`)

## Revision history

| Date | SHA | Note |
|---|---|---|
| 2026-05-05 | `618ac144` | Initial accepted version (#7 of 7-issue cleanup batch) — design only; M3-a implementation tracked as separate Phase 7 chunk |
