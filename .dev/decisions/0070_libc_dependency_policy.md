# 0070 — libc dependency policy

- **Status**: Accepted
- **Date**: 2026-05-19
- **Author**: continue loop §9.12 substrate audit cycle
- **Tags**: phase-9, libc, dependency-boundary, posix, hygiene

## Context

The 2026-05-16 D-134 investigation (SIGSEGV recovery via `sigsetjmp` /
`siglongjmp`) surfaced a wider concern: zwasm v2's libc dependency surface
is under-managed. Phase 9 completion substrate audit (ADR-0062 §Q6) escalated
this to a formal decision gate. Concretely:

- **Zig 0.16 stdlib direction**: `std.posix.*` / `std.process.*` /
  `std.heap.*` / `std.Threaded` are explicitly designed to be
  buildable-without-libc. zwasm v2 is currently moving against this current —
  `flake.nix` + `build.zig` hard-require `-lc`, and signal handling fans
  through libc primitives.
- **Phase 10+ pressure**: AOT mode (Phase 12), embedded distribution
  (post-Phase-13), Windows-native compatibility (Phase 13+) each multiply the
  cost of carrying libc fanout. Unwinding the dependency post-Phase-10 is
  harder than gating new additions now.
- **Reference clone evidence**: wasmtime / wasmer / wasm3 each manage libc
  boundary explicitly; zwasm v1 did not (the substrate-audit retrospective
  marks this as one of v1's accumulated debts).

A full site inventory (`grep -rnE 'std\.c\.|@extern.*"c"|sigsetjmp|siglongjmp|
pthread_jit|sys_icache_invalidate' src/ test/ build.zig` plus DebugAllocator
scan) found **16 active call sites**, plus the `@extern(.{ .library_name = "c" })`
declarations for `sigsetjmp` / `siglongjmp` in
`test/spec/spec_assert_runner_base.zig`.

## Decision

Classify every `std.c.*` / `@extern("c")` / `pthread_*` / `sigsetjmp` / `siglongjmp`
call site in zwasm v2 into one of three categories, and gate new additions to
**necessary** behind ADR amendment.

### Categories — defined

| Category | Definition | Treatment |
|---|---|---|
| **necessary** | No Zig stdlib (`std.posix.*`, `std.process.*`, `std.heap.*`, `linux.*`) equivalent exists at Zig 0.16. Adding a Zig stdlib equivalent requires an upstream Zig issue / PR. | Retain; track upstream issue link in this ADR's "necessary watch list". New additions require ADR amendment. |
| **replaceable** | A clear `std.posix.*` / `std.process.*` equivalent exists at Zig 0.16. The migration is mechanical (drop-in symbol rename + small signature adjustments). | Migrate in §9.12-D sample-migration chunk OR debt-row-named follow-up. New additions are rejected by `scripts/check_libc_boundary.sh` unless ADR-justified. |
| **convenience** | Used only under Debug builds (e.g. `std.heap.DebugAllocator` requiring libc on Linux). Loss of the libc dependency would degrade development ergonomics without affecting Release semantics. | Permitted under Debug build only. Release-build libc fanout in this category is rejected. |

### Concrete inventory (2026-05-19 measurement)

#### Necessary set (6 unique symbols, ~8 sites)

| Symbol | Sites | Justification | Upstream watch |
|---|---|---|---|
| `pthread_jit_write_protect_np` | `src/platform/jit_mem.zig:144` (×2 calls — setExecutable / setWritable) | Darwin arm64 W^X toggle. POSIX has no equivalent; this is the canonical Apple-supplied API for JIT-with-hardened-runtime. | Zig stdlib has no plan to wrap; watch ziglang/zig for future Darwin JIT support. |
| `sys_icache_invalidate` | `src/platform/jit_mem.zig:145` | Darwin arm64 instruction cache invalidation. Cross-platform equivalent (`__builtin___clear_cache`) is Clang-builtin and not Zig-exposed. | Zig stdlib: track `@clearInstructionCache` builtin proposal. |
| `sigsetjmp` (linkage `@extern("c")`) | `test/spec/spec_assert_runner_base.zig:1826` | Signal-safe setjmp variant; glibc-mangled name. POSIX-mandated; no Zig stdlib equivalent. | Zig stdlib: no plan. Watch for builtin / std addition. |
| `siglongjmp` (linkage `@extern("c")`) | `test/spec/spec_assert_runner_base.zig:1834` | Signal-safe longjmp variant. Same as above. | Same as above. |
| `std.c.mmap` + `MAP` + `vm_prot_t` constants | `src/platform/jit_mem.zig:64-67` | Darwin `MAP_JIT` flag is required for arm64 hardened-runtime JIT. `std.posix.mmap` does not currently expose `MAP_JIT`. | Zig stdlib issue: file upstream for `MAP_JIT` constant. |
| `std.c.mprotect` | `src/platform/guarded_mem.zig` (commit-on-grow, ADR-0202 D1) | Zig 0.16 `std.posix` has no `mprotect` wrapper (verified via `lib/std/posix.zig` grep), and macOS has no non-libc syscall path. Added 2026-07-06 (B133 / ADR-0202). | Zig stdlib: watch for a `std.posix.mprotect` wrapper; migrate when it lands. |
| `std.c.sigset_t` + `std.c.stack_t` (type-only) | `src/platform/sigcontext.zig` (Darwin `ucontext_t` layout mirror, ADR-0202 D2) | TYPE references only — no new linkage (same class as `vm_prot_t`). Zig 0.16 keeps `ucontext_t`/`mcontext_t` PRIVATE (`std/debug/cpu_context.zig`), so the PC-redirect handler must mirror the layout, and the Darwin prefix embeds these libc types. Added 2026-07-06 (B133 / ADR-0202). | Zig stdlib: watch for a public `std.debug.SignalContext`-class API; migrate when it lands. |
| `std.c.MAP_FAILED` | `src/platform/jit_mem.zig` (mmap return-value check) | Mmap sentinel. Tied to `std.c.mmap` use. | Resolved when `std.c.mmap` is replaced. |
| `std.c._exit` (signal-handler context) | `test/spec/spec_assert_runner_base.zig:2034` (test SIGSEGV recovery handler) + `src/platform/signal.zig` (ADR-0166 **production** internal-fault handler) | Reclassified from Replaceable 2026-05-20 (§9.12-D / B131); production site added 2026-06-06 (ADR-0166 / D-292 B-core). `std.posix.exit` does not exist in Zig 0.16; `std.process.exit` routes through `std.c.exit` which runs atexit handlers and is **not async-signal-safe**. The signal-handler context REQUIRES the raw `_exit` syscall to avoid re-entry into stdio buffers. No working stdlib equivalent. | Zig stdlib: watch for `std.posix.exit` (raw syscall variant). |
| `std.c.write` (`extern "c" fn write`, signal-handler context) | `src/platform/signal.zig` (ADR-0166 production internal-fault handler) | Added 2026-06-06 (ADR-0166 / D-292 B-core). The raw `write(2)` syscall is the canonical async-signal-safe output primitive (POSIX `signal-safety(7)`); `std.posix.write` returns an error union, forcing a silent-fallback in a signal context. No allocation/stdio. (`fork`/`waitpid` in `signal.zig`'s fork test are test-only, sibling to the realworld runner; the `std.posix.W` wait-macros are pure-Zig.) | Zig stdlib: watch for an async-signal-safe raw-write wrapper. |
| `std.c.fork` / `waitpid` / `alarm` | `test/realworld/run_runner_jit.zig:137,165,167,168` (4 sites) | Reclassified from Replaceable 2026-05-20 (§9.12-D / B131 amendment). Zig 0.16's `std.posix` does NOT expose `fork`, `waitpid`, or `alarm` — verified by grep of `lib/std/posix.zig`. The runner already documents this inline (`run_runner_jit.zig:134-136`). No working stdlib equivalent in current Zig. | Zig stdlib: watch for posix process-control additions (`std.posix.fork`/`waitpid`/`alarm`). Until then, libc shims are the only path. |
| `std.c.environ` (c_api context) | `src/api/wasi.zig` (`zwasm_wasi_config_inherit_env` C ABI export, ADR-0184) | Added 2026-06-13 (ADR-0184 amendment). Full-environ snapshot for WASI env inheritance from C. Same constraint class as `std.c.getenv` (B132): a C-ABI export has no `std.process.Init`, so on POSIX the environ block is reachable only via the libc global; `std.process.Environ`'s PosixBlock is constructed FROM it. The Windows path reads the PEB through `std.process.Environ` (`.global` block, no libc); the site is comptime-POSIX-only. | Zig stdlib: same watch as getenv — an "Init-free Environ.fromGlobal()" addition would absorb this site. |
| `std.c.getenv` (c_api context) | `src/api/instance.zig:212` (`wasm_engine_new` C ABI export) | Reclassified from Replaceable 2026-05-20 (§9.12-D / B132 amendment). `wasm_engine_new` is a C ABI export called from arbitrary C host code; it does NOT receive a `std.process.Init` (the Juicy Main mechanism is for Zig binaries' `main`). `std.process.Environ.getPosix` requires an `Environ` value that can only be constructed from `std.process.Init.io.environ` or by reading `std.c.environ` directly (still libc). On POSIX, `std.c.getenv` is the canonical one-shot env-var read for code that doesn't own `main` — same constraint as `sigsetjmp`/`siglongjmp` for c_api signal handlers. | Zig stdlib: watch for a "Init-free Environ.fromGlobal()" addition. Until then, c_api entry points use `std.c.getenv`. |

#### Replaceable set (0 unique symbols, 0 sites — post-B132)

§9.12-D close: the 9 symbols originally classified as Replaceable
have resolved as follows:

- 1 migrated to `std.posix.*` (`munmap` — B130).
- 2 migrated to `std.posix.*` (`pid_t`, `kill` — B132 with
  EXEMPT-FALLBACK marker on the signal-handler `kill` site).
- 6 reclassified to Necessary (4 in B131: `_exit` / `fork` /
  `waitpid` / `alarm`; 1 in B132: `getenv`; `write` was already
  unused — no actual site in current code).

`scripts/check_libc_boundary.sh --gate` returns 0. §9.12-D's
literal exit met.

#### Convenience set (0 active sites)

`std.heap.DebugAllocator` is referenced in code comments at `src/engine/runner.zig:1943`
but is not an active call site (no `std.heap.DebugAllocator` instantiation in current
code). The convenience category is **declared but currently empty**; it exists to
absorb future Debug-only libc dependencies (e.g. if `std.heap.DebugAllocator` is
later selected on Linux Debug builds for leak detection).

### Enforcement

1. **`.claude/rules/libc_boundary.md`** — auto-load rule on `src/**/*.zig` editing.
   Codifies: before writing `std.c.<name>`, check `std.posix.<name>` /
   `std.process.<name>` first; cite this ADR; reviewer checklist for grep-able
   anti-patterns.
2. **`scripts/check_libc_boundary.sh`** — pre-commit gate. Greps for new
   `std.c.*` / `@extern("c")` / `pthread_*` sites and flags any that are not
   on this ADR's necessary list. Lands in §9.12-D.
3. **`audit_scaffolding §G.5` extension** — periodic audit that re-runs the
   grep against the active branch and reports drift against this ADR's
   inventory.
4. **ROADMAP §14 forbidden-list amendment** — add: "Unconscious libc fanout
   (new `std.c.*` calls without ADR justification or rule exception)" with
   cite to this ADR.
5. **§9.12-D sample-migration chunk** — converts the 10 replaceable sites in
   one commit; proves the rule has teeth.

## Alternatives considered

### Alternative A — Full libc-free build now (eliminate even the necessary set)

- **Sketch**: re-implement `sigsetjmp` / `siglongjmp` in inline assembly per
  target; replace `pthread_jit_write_protect_np` with a custom syscall wrapper;
  fork Zig stdlib to add `MAP_JIT`.
- **Why rejected**: the necessary set has no upstream-blessed Zig stdlib path
  *yet*. Re-implementing libc primitives in inline asm carries a substantial
  reliability risk (D-103 → D-134 lineage is already 3 distinct libc-bug
  cycles); the maintenance cost of forking Zig stdlib exceeds the value before
  Phase 13's Windows-native push makes it necessary. Defer to Phase 13.

### Alternative B — Keep current state; address libc fanout when Phase 12 / 13 demands

- **Sketch**: defer all libc-boundary work; let new `std.c.*` sites accumulate
  organically.
- **Why rejected**: every new site in Phase 10's GC / EH / tail-call / memory64
  implementation work is a new dependency to unwind in Phase 12. Phase 10's
  per-op file pattern (per ADR-0073) makes the rule's enforcement cheap —
  one file = one review point. Deferring loses the cheap enforcement window.

### Alternative C — Convenience category absorbs DebugAllocator now (proactive)

- **Sketch**: introduce `std.heap.DebugAllocator` in Debug builds across
  `src/engine/runner.zig` to gain leak-detection coverage; ADR-justify it as
  a convenience-category libc dependency.
- **Why deferred (not rejected)**: leak-detection coverage is a Phase 9b /
  Phase 11 concern; this ADR's scope is the dependency boundary itself.
  DebugAllocator adoption is a separate ADR if pursued.

### Alternative D — Per-target libc policy (Darwin allows more; Linux strict)

- **Sketch**: relax the necessary-set criterion on Darwin (where Apple's
  libc is the stable API surface) while keeping Linux strict (where `linux.*`
  syscall wrappers are preferable).
- **Why rejected**: cross-target consistency outweighs the small Darwin-only
  benefit. The necessary-set already names Darwin-specific symbols
  (`pthread_jit_write_protect_np`) without diluting the policy.

## Consequences

### Positive

- **Phase 12 AOT readiness**: AOT-mode binaries can be built with a minimal
  libc footprint; every `std.c.*` site is either justified or migrated.
- **Phase 13 Windows-native readiness**: `sigsetjmp` / `siglongjmp` are the
  only POSIX-specific dependencies that remain after §9.12-D; the Windows
  port writes a single SEH-shim file rather than touching N call sites.
- **Drift is caught at commit time**: `scripts/check_libc_boundary.sh` fires
  on PR; new sites surface in review, not at AOT-build time.
- **Inventory is concrete + tracked**: this ADR's tables are the single
  source of truth; audit can compare against grep output deterministically.

### Negative

- **§9.12-D adds 10 call-site migrations** to the §9.12 cohort; this is
  ~1 chunk of work.
- **`pthread_jit_write_protect_np` ties zwasm to Apple's hardened-runtime
  policy** — if Apple deprecates the API, the necessary watch list must
  re-open. Mitigation: maintain an upstream-watching note in this ADR.

### Neutral / follow-ups

- File the upstream Zig issue / PR for `MAP_JIT` in `std.posix.mmap` (a
  small, well-scoped contribution; track in a `private/notes/` followup).
- The convenience category has 0 active sites today; the policy slot is
  pre-declared for future use.
- A separate `.claude/rules/libc_boundary.md` skeleton already exists; it
  is filled in during §9.12-D.

## References

- ROADMAP §14 (forbidden list amendment to be added by §9.12-D commit), §11
  layers.
- ADR-0067 (ubuntunote host pivot; D-134 Rosetta) — one origin of libc
  reliability concerns.
- ADR-0071 (Phase 9 substrate audit resolution; Q6 referent).
- `.dev/archive/phase9/phase9_completion_substrate_audit.md` §Q6.
- D-134 lineage (D-103 → d-29 → d-62 → d-65); the signal-recovery story
  driving the necessary set.
- Inventory survey: 2026-05-19 grep-based site enumeration (this ADR's
  tables are the captured result).

## Revision history

| Date       | SHA          | Note                                                          |
|------------|--------------|---------------------------------------------------------------|
| 2026-05-19 | `bdd433d5` | Initial draft — Q6 deliverable with full inventory + 3-category policy. |
| 2026-05-20 | `8dfe9018` | §9.12-D / B131 amendment — reclassify `_exit` / `fork` / `waitpid` / `alarm` from Replaceable → Necessary. Zig 0.16 `std.posix` lacks all four; the originally-claimed `std.posix.{exit,fork,waitpid,alarm}` targets do not exist (verified via `lib/std/posix.zig` grep). Necessary set grows from 6 → 7 (counting fork/waitpid/alarm as one row); Replaceable shrinks from 8 → 4 (post-B130 munmap → 3). D-151 (the gap-naming row in `debt.md`) is discharged by this amendment. |
| 2026-05-20 | `b098a688` | §9.12-D / B132 close — migrated `std.c.kill` → `std.posix.kill` (with EXEMPT-FALLBACK marker on the SIGALRM-handler `catch {}`) and `std.c.pid_t` → `std.posix.pid_t`. Reclassified `std.c.getenv` from Replaceable → Necessary because the `wasm_engine_new` c_api export is called from C code without `std.process.Init`, so `std.process.Environ.getPosix` is structurally unavailable. Replaceable set 3 → 0; §9.12-D `[ ]` → `[x]`. |
| 2026-05-19 | `43d82eb5` | **Accepted** at §9.12 collab gate. User intent: libc 依存サーフェスを Phase 10+ (AOT / 組込 / Windows native) 着手前に管理下に置き見据える。3-category 分類 + 5 deliverable 着地は §9.12-D で実施。 |
| 2026-05-23 | `b2e7203a` | **ADR-0105 D1 amendment** — add 6 stack-limit query symbols to Necessary (`std.c.pthread_self`, `pthread_get_stackaddr_np`, `pthread_get_stacksize_np`, `pthread_getattr_np`, `pthread_attr_getstack`, `pthread_attr_destroy`). The JIT-prologue stack-probe per ADR-0105 needs the thread-stack low-end address to compute `stack_limit = low + STACK_GUARD_HEADROOM`. Zig 0.16 `std.posix` does not expose any of these; the Mac `_np` family is platform-specific, the Linux `getattr_np` family is glibc-specific, and `pthread_self` is needed as the thread handle for all of them. Live in `src/platform/stack_limit.zig` (Zone 0). Necessary set grows from 13 → 19. The Windows side uses `extern "kernel32" GetCurrentThreadStackLimits` (not a libc symbol, so not in the NECESSARY allowlist; goes through the `@extern("kernel32")` path which check_libc_boundary.sh PATTERN does not match). |
| 2026-06-13 | (pending) | **ADR-0184 amendment** — add `std.c.environ` to Necessary for `zwasm_wasi_config_inherit_env` (C-API full-environ snapshot). Same B132 constraint class as `std.c.getenv`: no `std.process.Init` at a C-ABI export; POSIX-only (Windows uses the PEB via `std.process.Environ`, no libc). Necessary set grows by 1. |
| 2026-07-06 | (pending) | **B133 / ADR-0202 amendment** — add `std.c.mprotect` to Necessary for `src/platform/guarded_mem.zig` commit-on-grow (guard-page linear-memory backing, ADR-0202 D1). Zig 0.16 `std.posix` dropped its `mprotect` wrapper; macOS has no non-libc syscall path. Necessary set grows by 1. |
| 2026-06-08 | (pending) | **ADR-0178 amendment** — the Linux `pthread_getattr_np` / `pthread_attr_getstack` / `pthread_attr_destroy` necessary sites are now `comptime`-gated behind `builtin.abi.isGnu()` (glibc only). On musl/other Linux they are NOT referenced — so NOT linked (fixing cljw's `x86_64-linux-musl` link failure). The non-glibc fallback uses raw `std.os.linux.openat`/`read`/`close`/`getrlimit` (off-boundary `linux.*` wrappers, NOT `std.c`/`pthread_*`), so the Necessary set is unchanged in size; these three glibc symbols are simply no longer emitted on musl. No new boundary symbol added. |
