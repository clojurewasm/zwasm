# ADR-0202 — Guard-page linear memory + signal-based OOB traps (bounds-check elision)

> Doc-state: ACTIVE
> Status: Implemented (2026-07-07, @5c5c45f6d) — D-507 CLOSED. Phase 1 #131
> (reservation-backed memory), phase 2 #132 (fault→trap handler + registry),
> phase 3 #133 (elision flip + AOT soundness guard). Implements ROADMAP §4.9 as
> written; supersedes-in-part ADR-0166's premise ("v2 uses NO signal-based wasm
> trap semantics") for the guard-fault class only. **Retrospective: the perf
> hypothesis is REFUTED** (measured scalar-elision delta ~noise; the 1.75–3.9x
> gap is optimising-tier quality = D-513). Elision shipped for correctness +
> code-size + as the D-509 guard-fault foundation; ~~AOT elision DISABLED~~
> **AOT elision ENABLED 2026-07-09 (ADR-0203 stage 4 / D-515(1))**: the
> `.cwasm` v0.5 header carries `flag_bounds_elided`, the full-fidelity
> loader's re-link re-registers trap entries against the loaded block,
> setup binds the guarded reservation (no plain-heap fallback), and the
> loader explicitly REJECTS an elided artifact on a non-guarded host
> (`ElidedArtifactNeedsGuardedHost` — the D5 "non-D1-host reject" clause;
> vacuous today since every jit_mem platform is guarded-capable, but
> enforced rather than left to set-inclusion coincidence) — all five D5
> clauses realized by the ADR-0203 architecture rather than by extending
> the (retired) mini-runtime. Follow-ups: D-514 (SIMD elision),
> D-515(2) (spec-assert corpus under elision).

## Context

**Root cause.** Every JIT linear-memory access emits an inline bounds check —
arm64 (`src/engine/codegen/arm64/op_memory.zig:251-258`):

```
ORR  W16, WZR, W_addr        ; zero-extend idx
ADD  X16, X16, #offset       ; if offset != 0
ADD  X17, X16, #access_size
CMP  X17, X27                ; X27 = pinned mem_limit
B.HI <oob stub>              ; per-function trap stub, kind=6
LDR/STR ..., [X28, X16]      ; X28 = pinned vm_base
```

x86_64 is worse: base/limit are NOT pinned — every access reloads
`[R15+vm_base_off]` / `[R15+mem_limit_off]` before the CMP
(`x86_64/op_memory.zig:186-215`). Measured cost (senior-runtime gap analysis
2026-07-06 §0): shootout fib2 1.75x / heapsort 3.0x / matrix 3.9x vs wasmtime —
a large slice of the sub-4x band is this per-access overhead. wasmtime
(`memory_reservation`/`memory_guard_size`/`signals_based_traps`) and WAMR
(Segue) elide the check via guard regions + fault classification.

**ROADMAP §4.9 already specifies the target design** ("Linear memory is
mmap-backed … Bounds check via guard pages … SIGSEGV … converted to a Wasm
trap"). The shipped model (plain-allocator buffer, `realloc` on grow — base
pointer MOVES, `runtime.zig:476`, `setup.zig:214`; explicit CMP everywhere) was
the interim simplification. This ADR schedules the rework per the design
priority (ADR-0153: measured structural deficiency → rework, not defer).

**Existing assets.** (a) Sticky-flag trap model (ADR-0199): per-function trap
stubs set `trap_flag`/`trap_kind`, unwind ONE frame (`ADD SP, frame_bytes` +
`LDP FP,LR` + `RET`), and post-call checks cascade — signal recovery can reuse
this wholesale. (b) Test-only fault recovery already exists: POSIX
`sigsetjmp`/`siglongjmp` (`spec_assert_runner_base.zig:2519+`, D-103) and the
Win64 VEH Rip/Rsp/Rax redirect (`src/platform/windows_traphandler.zig`,
ADR-0103). (c) Production diagnostic handler (ADR-0166, `signal.zig`) owns
SIGSEGV last-resort disposition. (d) `jit_mem.zig` already does per-OS page
allocation (mmap / NtAllocateVirtualMemory).

## Decision

**D1 — Reservation-backed linear memory (qualifying memories).** A memory
qualifies when: `idx_type == .i32` AND `page_size_log2 == 16` (standard 64KiB
pages) AND `platform.guarded_mem.supported` (single source of truth: 64-bit
macOS/Linux any-arch + x86_64-windows — deliberately a superset of today's JIT
targets so aarch64-linux is not special-cased later). Qualifying memories reserve
`4 GiB (idx span) + 4 GiB (offset span) + 1 host page` of PROT_NONE address
space (POSIX `std.posix.mmap` + `MAP_NORESERVE`-equivalent; Windows
`NtAllocateVirtualMemory` MEM_RESERVE, mirroring `jit_mem.zig`). The accessible
prefix (`mem_limit` bytes) is committed RW (`std.posix.mprotect` / MEM_COMMIT);
`memory.grow` extends the committed prefix in place — **the base pointer never
moves** (the post-grow X28/X27 reload stays, harmless). Free = unmap the whole
reservation. Non-qualifying memories (memory64, custom page sizes, unsupported
hosts) keep the existing allocator path AND explicit checks. Reservation
failure at instantiation = instantiation error (no silent fallback to a
checked recompile — the compiled code already elided its checks; 8 GiB of VA
failing on a 64-bit host is pathological).

**D2 — Production fault→trap conversion by PC redirect (no setjmp).** One
production handler per OS, classification-first, diagnostic-last:

- Classify: fault address ∈ a registered guarded reservation (D1) AND fault PC
  ∈ a registered JIT code region → look up the containing function's kind=6
  (oob_memory) trap stub and **rewrite the faulting context's PC to the stub**
  (POSIX: mcontext pc/rip; Windows: `ContextRecord.Rip` +
  EXCEPTION_CONTINUE_EXECUTION). The stub then runs the normal ADR-0199 path:
  set `trap_flag`/`trap_kind=6` via the pinned runtime reg (X19/R15 — callee-
  saved, still live at fault), unwind its own frame, cascade via post-call
  checks. Works at any wasm→host→wasm depth; never skips a host frame (the
  reason setjmp/longjmp — the ADR-0103 test model — is NOT promoted).
- POSIX signals: the handler owns **both SIGSEGV and SIGBUS** — macOS reports
  guard-region hits as SIGBUS (wasmtime handles the same pair). The
  classification branch is merged INTO the ADR-0166 handler body (one
  sigaction install, `cli/main.zig` + embedding init); not-classified falls
  through to the existing internal-error line + `_exit(70)`.
- Windows: classification is merged INTO the ADR-0166 production VEH body
  (classify → `Rip = stub` + CONTINUE_EXECUTION; else diagnostic + 
  ExitProcess(70)). A separate First=0 VEH would be DEAD code — the ADR-0166
  VEH is First=1 (front of chain) and ExitProcess(70)s on ACCESS_VIOLATION
  before any later handler runs (`signal.zig:74-99`). The ADR-0103
  test-recovery VEH is untouched.
- Third handler (test builds): the spec runners' process-wide D-103
  `installSigsegvHandler` (sigsetjmp/siglongjmp) and this handler contend for
  the same sigaction slot. Sub-decision: in test-runner processes the MERGED
  handler owns SIGSEGV/SIGBUS; the classify branch runs first, and the D-103
  siglongjmp recovery becomes its unclassified-in-test else-branch (instead of
  `_exit(70)`), preserving the miscompile-recovery behaviour the spec harness
  relies on. One handler, three dispositions: classified→redirect,
  test-armed→siglongjmp, else→diagnostic exit.

**D3 — Zone-0 trap registry (`src/platform/`).** Async-signal-safe global
registry: (a) JIT code regions `{start, end, func_table}` where `func_table` =
sorted per-function `{code_start_off, oob_stub_off}`. The linker has
`func_offsets` today but the oob-stub offset is currently emit-local and
DISCARDED (`EmitCindStub.emit`'s `stub_byte`) — D4 adds `oob_stub_off` to
`EmitOutput` (both arches) so the linker can build the table at publish; (b)
guarded reservations `{base, reserve_end}`.
Zone 2 (engine/runtime) registers/unregisters via downward calls (zone_deps
compliant — mirrors how `windows_traphandler` exposes an arm/disarm surface).
**Concurrency (as-built)**: fixed-capacity global arrays mutated only at
publish / instantiate / teardown — never while JIT code is executing on the
same thread — and read locklessly from the handler. The runtime is
single-threaded today, so this quiescent-mutation discipline is sufficient
without atomics. **D-509 (threads) MUST revisit**: cross-thread registration
while another thread faults needs either a seqlock/RCU-style atomic snapshot
swap or a registration barrier; this is called out here so the threads
campaign does not inherit the single-threaded assumption silently.

**D4 — Emit-side elision.** New `EmitCtx` field `bounds_elided: bool = false`
(beside `memory0_idx_type`, both arches). When set (memory0 qualifies per D1):

- memory0 i32 loads/stores/atomics/SIMD drop `ADD ip1 / CMP / B.HI` (and on
  x86_64 the mem_limit reload) — worst case `idx(≤2^32-1) + offset(≤2^32-1) +
  access(≤16)` lands inside the D1 reservation. Atomics KEEP the alignment
  check (unaligned_atomic must stay precise); ea computation + `[base, ea]`
  addressing unchanged.
- Functions containing elided accesses FORCE-EMIT the kind=6 stub (today it is
  emitted only when `oob_fixups` is non-empty; D2 needs a redirect target).
- memory64 and bulk ops (`memory.fill/copy/init` — length-ranged, not
  guard-coverable) keep explicit checks unchanged.

**D5 — Engine knob + AOT.** Engine-level `bounds_checks: .auto | .explicit`
(default `.auto` = elide when memory qualifies). `.explicit` is the debugging /
differential-fuzz axis (D-510 can diff elided-vs-checked JIT in addition to
JIT-vs-interp). The `.cwasm` format records the elision bit AND serializes the
D3 `func_table` (`aot/serialise.zig` carries `per_func_offsets` only today);
`aot/load.zig` registers the table + requires a D1-capable host for elided
artifacts (reject with a clear error otherwise).

**Soundness invariant (binding-time).** Elided code is memory-safe ONLY while
memory0's runtime binding is reservation-backed. Enforced at instantiation /
memory-import wiring / host-`Memory`-creation: binding a non-guarded buffer to
an instance whose code was compiled elided is an instantiation ERROR, never a
silent acceptance (every `setMemory0Bytes`-feeding path checks the backing).

**D6 — Unchanged.** Interp (oracle) semantics + its memory accessors; trap
wire codes + `TrapKind` surfaces; X28/X27 pinning (memory.size/grow still read
them); sandbox caps (`store_memory_pages_max`, fuel, interrupt); EH unwinder
(guard faults are traps, not wasm exceptions); ADR-0103 test recovery.

## Consequences

- **+** Removes exactly `ADD ip1 / CMP / B.HI` (3 instructions, arm64) / the
  mem_limit reload + CMP + JA (x86_64; the vm_base reload stays — it feeds the
  access itself) per memory access. Code-size + icache win; foundational for
  the guard-fault infra D-509 (threads) needs.
- **⚠ MEASURED PERF (retrospective, correcting the pre-impl hypothesis):** the
  arm64 shootout delta is ~noise-level, NOT the "large slice of the 1.75x
  floor" this ADR's Context hypothesised (aarch64 macOS, hyperfine, D-507 phase
  1 baseline vs phase 3): matrix 348.9→344.7 (~1%), base64 710.5→700.5 (~1.5%),
  sieve 835.7→802.7 (~4%), fib2 1230.8→1194.1 (~3% but fib2 has NO hot-path
  memory access → within the ±2–4% run stddev). The bounds check was a
  pinned-reg CMP + a well-predicted (never-taken) branch — cheap on an OoO
  core, so eliding it saves few cycles. **The 1.75–3.9x gap vs wasmtime is
  dominated by optimising-tier codegen quality (D-513), not bounds checks** —
  exactly what the gap report's own ">4x outliers = tier quality" caveat
  implied; this measurement extends it down to the sub-4x band too. The
  elision still ships: it is correct, reduces code size, is the standard
  production design, and its guard-fault machinery is the reusable foundation
  D-509 requires — but it is NOT the perf lever the Context framed it as. Per
  the perf-measure-first principle, the hypothesis is recorded as refuted.
- **+** Base-stable memory is a prerequisite D-509 (shared memories) needs
  anyway; realloc-relocation dies here.
- **−** 8 GiB VA reservation per qualifying memory (reserve-only; no commit
  charge). Multi-memory modules multiply it; acceptable on 64-bit targets, and
  non-qualifying paths remain for everything else.
- **−** ADR-0166's "any fatal signal is a zwasm bug" narrows to "any
  *unclassified* fatal signal"; `signal.zig` doc + this classification order
  encode it.
- **Risk (accepted):** PC-redirect touches per-OS mcontext layouts (macOS
  arm64/x86_64, Linux x86_64/aarch64, Win64) — each verified on the 3-host
  gate + Rosetta x86_64-macos (reproduces linux-class JIT bugs, per memory).
- **Risk (watched):** a store straddling the commit/guard boundary must not be
  partially visible (spec memory_trap corpus asserts this). Precise faults on
  the supported targets + the wasmtime/V8 precedent cover it; the boundary
  fixture set (test_discipline §1) pins it per-arch.
- ADR-0070: ONE new libc site — `std.c.mprotect` (Zig 0.16 `std.posix` has no
  wrapper; macOS has no non-libc syscall path) → B133 amendment + allowlist
  entry, filed with this ADR. Everything else (`std.posix.mmap/sigaction`,
  ntdll `Nt*`/VEH) is outside the `check_libc_boundary` pattern (same as
  `signal.zig`/`jit_mem.zig`).

## Implementation order (TDD, correctness-first)

1. D1 platform reservation primitive (`src/platform/guarded_mem.zig`) + runtime
   backing switch — behavior-preserving (checks still emitted), full net green.
2. D3 registry + D2 handler — fault→trap conversion proven by a test that
   faults a guarded region from JIT code BEFORE any check is elided (redirect
   path exercised in isolation).
3. D4 elision flip behind D5 knob + force-emitted stubs + boundary fixtures;
   oob corpus green on both engines; bench delta; 3-host + Rosetta verify.

Verification per step. Step 2 (pre-elision): the redirect mechanism is proven
in-process (`fault_redirect_test` — a guard fault in hand-emitted JIT code
resumes at the registered stub, fork-isolated) plus a plumbing test that the
oob-stub offset reaches the registry through BOTH the plain and the
wrapper-thunk link paths. A CLI-subprocess `trap kind=6` test is NOT meaningful
here — with checks still emitted no CLI run can reach the guard path. Step 3
(elision on): add the **per-OS CLI-level oob test asserting the literal
`trap kind=6` output with NO runner recovery armed** — with the explicit check
gone the guard path is the ONLY mechanism, so this is the load-bearing
end-to-end proof (and the spec runner's classify-first ordering keeps its
sigsetjmp recovery from absorbing a guard fault as generic "trapped").
