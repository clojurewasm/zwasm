# 0016 — Adopt error diagnostic system (Diagnostic core + CLI parity, phase 1)

- **Status**: Accepted
- **Date**: 2026-05-04
- **Author**: zwasm v2 / continue loop
- **Tags**: phase-6, error-handling, diagnostic, cli-ux, c-abi, observability

## Context

zwasm v2's error UX has regressed against v1. Today `zwasm run
foo.wasm` fails with output of the form:

```
zwasm run: ModuleAllocFailed
```

— the bare Zig error tag. The survey
([`private/notes/error-system-survey.md`](../../private/notes/error-system-survey.md),
873 lines, gitignored) confirmed v1 had a 35-case
`formatWasmError` mapping at `~/Documents/MyProducts/zwasm/src/cli.zig:2153`
that turned the same error into something like:

```
error: failed to load module: validation: type mismatch
```

— still imperfect but materially more useful. v2 dropped this on
the way to the from-scratch redesign and never recovered.

Two further symptoms surfaced in §9.6 / 6.K.2's debug session:

1. The wast\_runtime\_runner FAIL message `result[0] mismatch`
   omits actual-vs-expected even though both values are in scope
   at `wast_runtime_runner.zig:776` — a one-line print would
   close the gap.
2. v2's interp `Trap` enum (`src/interp/mod.zig:137`, 12 tags) and
   the c\_api `TrapKind` enum (`src/c_api/trap_surface.zig:34`,
   11 tags) are duplicated, glued by a `mapInterpTrap()`
   function. Wasmtime shares one enum across runtime + c-api
   (`crates/environ/src/trap_encoding.rs:64`); v2's parallel fork
   is exactly the "Implicit Contract Sprawl" anti-pattern that
   motivated the ROADMAP §P10 redesign. It needs to collapse
   before more error sites accumulate against the wrong enum.

The survey compared four internal shapes (plain error set,
`*ErrorContext` arg, tagged Result union, hybrid) across hot-path
cost / library UX / C ABI / JIT compatibility, then reviewed
wasmtime, wazero, and ClojureWasm v2 (`~/Documents/MyProducts/ClojureWasmFromScratch/`)
for cross-reference. The hybrid shape — Zig error set drives
control flow on the hot path, structured `Diagnostic` payload in
a threadlocal slot — wins on every axis when constrained by
ROADMAP §A12 ("dispatch table not pervasive `if`"), §P3 ("no
allocation per call"), and Phase 7 JIT readiness ("traps must
return as plain `i64` codes for the JIT calling convention").

This ADR scopes **phase 1** (the survey's M1) only:

- `src/runtime/diagnostic.zig` (Zone 1) — `Kind`, `Phase`,
  `Location` (initially with only the `unknown` variant — full
  variants land in M2/M3), `Info`, threadlocal `last_diag`,
  `setDiag` / `clearDiag` / `getDiag`.
- `src/cli/diag_print.zig` (Zone 3) — `formatDiagnostic` renderer.
- `src/main.zig` — drop the bare `@errorName(err)` print in
  favour of `formatDiagnostic` if a diagnostic was set, falling
  back to `@errorName(err)` otherwise (drop-in compat for
  unwired error sites).
- **`setDiag` at the `runWasm` boundary in `src/cli/run.zig`** —
  exactly six sites, one per `runWasm`-visible error tag
  (`EngineAllocFailed`, `StoreAllocFailed`, `ConfigAllocFailed`,
  `ModuleAllocFailed`, `InstanceAllocFailed`, `NoFuncExport`).
  This is the **boundary** approach: phase 1 doesn't push
  `setDiag` into `c_api/instance.zig` or the frontend (those
  sites — ~95 in `instance.zig` alone — are M2's territory
  where they gain real location info). The boundary site
  produces a `Phase = .instantiate, Location = .unknown,
  Kind = <classified>` diagnostic that's enough for v1
  CLI parity but explicitly *not* a substitute for M2/M3's
  richer surfaces. The c\_api / frontend internals stay
  untouched in this commit.

Phases 2–5 (frontend location threading, interp trap location +
trace ringbuffer, C ABI accessors, backtraces) are referenced
in the migration path but **do not land in this ADR**. Each is
its own §9.6-or-later row when its prerequisite cycle reaches
it.

A v1 grep confirmed v2 has no analogue today: `git grep
'fn formatWasmError'` in v1 returns one definition at
`cli.zig:2153`; v2 has no function with that signature, no
threadlocal diagnostic slot, no tagged-union Location. The
spec-text strings (`out of bounds memory access`,
`integer divide by zero`, etc.) **already live in v2** at
`src/c_api/trap_surface.zig:trapMessageFor` (sourced upstream
from the Wasm spec, not from v1) — the renderer borrows from
that table, not from v1's `formatWasmError` switch. ROADMAP
§P10 / `no_copy_from_v1.md` is satisfied: v2 rebuilds the
diagnostic structure fresh on top of a `Kind × Phase × Location`
axis system that v1 never had, and the strings come from the
spec, not from v1.

### What lands where (commit map)

This commit lands:

1. **The ADR itself** (this file).
2. **ROADMAP §9.6 amendment** — adds row `6.K.8` for phase 1
   implementation tracking (parallel-eligible with 6.K.3〜6.K.7).
3. **Phase 1 implementation** — `src/runtime/diagnostic.zig`,
   `src/cli/diag_print.zig`, `src/main.zig` + `src/cli/run.zig`
   wiring, one real `setDiag` site in `c_api/instance.zig`,
   plus a golden CLI test that locks parity-against-v1 for at
   least one failure case.

Per ROADMAP §18.2: the ADR is the §18 cover for the §9.6 / 6.K.8
amendment; the commit message references this ADR explicitly so
`git log -- .dev/ROADMAP.md` is browseable for cause.

## Decision

Adopt the hybrid diagnostic shape (Zig error set + threadlocal
`Diagnostic` payload) plus a layered renderer at the surface
(CLI / test runner / C ABI), with phase 1 scope as defined
above. The ten design principles below are load-bearing — every
phase 2+ extension must satisfy them.

### Design principles (lift verbatim from survey §6)

1. **One source of truth for kinds.** A single
   `Diagnostic.Kind` enum is shared across the interpreter,
   the C ABI, and the CLI. No parallel mapping tables. The
   interp's `Trap` error set has 1:1 tags into `Kind`,
   enforced by an exhaustive switch
   (`require_exhaustive_enum_switch`, ADR-0009 / Phase B).
2. **Error union for control flow; threadlocal for payload.**
   `Trap` / `Error` is an enum-only Zig error set; a structured
   `Diagnostic` is written to a threadlocal slot at the raise
   site. Hot paths pay zero cost on success (identical to plain
   error set today). The diagnostic-emit branch is
   `@branchHint(.cold)`. **No `*ErrorContext` parameter is
   threaded through call sites** — that pattern was rejected on
   hot-path-cost grounds (Alternative A below).
3. **Two axes: kind × phase.**
   - `kind`: `parse_invalid_magic | parse_section_id |
     validate_type_mismatch | execute_oob_memory | wasi_<errno>
     | …` (~30 tags initially; grows additively).
   - `phase`: `parse | validate | instantiate | execute | wasi`.
   The CLI / C-host can treat them independently; the renderer
   composes them.
4. **Location is a tagged union.**
   `parse: { byte_offset }`, `validate: { fn_idx, body_offset,
   opcode }`, `execute: { fn_idx, pc, ea?, mem_size? }`,
   `wasi: { fd?, syscall }`. Default `unknown` variant for
   callers that haven't been instrumented yet (graceful
   degradation). Phase 1 ships **only** the `unknown` variant;
   phase 2 / 3 fill in the others as their respective subsystems
   are wired.
5. **Centralise emit sites at semantic boundaries.** Provide
   typed helpers (`requireValidLocalIdx`, `requireBlockType`,
   `requireMemBounds`, `requireValidatorTypeMatch`, …) modelled
   on ClojureWasm's `expectNumber` / `checkArity`. Every error
   in the codebase originates in one of these helpers; ad-hoc
   `return error.X` is forbidden in new code (lint-gated where
   feasible). **Phase 1 ships `setDiag` only**; the typed
   helpers are M2/M3 territory.
6. **C ABI extends via accessors, never via struct growth.**
   `wasm_trap_t` keeps its upstream-wasm.h shape. zwasm-specific
   information ships through `zwasm_trap_kind` / `_offset` /
   `_pc` / `_frames` accessors documented in `include/zwasm.h`.
   Mirror of wasmtime's c-api split. **Phase 1 does not add the
   accessors yet** — it does, however, document the contract so
   M4 has nothing to redesign.
7. **Library callers get both shapes.** Zig callers may pass
   `?*Diagnostic` (out-arg form) or read `lastDiagnostic()`
   (threadlocal form). C callers read
   `zwasm_get_last_error_*()` (threadlocal). The threadlocal is
   cleared on every binding entry, populated on error.
   **Phase 1 ships `lastDiagnostic()` and `clearDiag` /
   `setDiag` only**; the C-side `zwasm_get_last_error_*` exports
   land in M4.
8. **Renderer is data-driven, owned by the surface.** The CLI
   in `src/cli/diag_print.zig` and the test runners each call
   `formatDiagnostic(diag, source_ctx, writer)` with their own
   `source_ctx = { filename, bytes }`. The runtime never
   formats messages itself.
9. **Trace ring buffer on error.** When `Runtime.trace_cb` is
   set or `--trace` is requested, the runner keeps an 8-event
   ringbuffer; on trap, the buffer is drained alongside the
   diagnostic so the user sees "what just happened" without
   re-running. Wires the existing ADR-0013 hook into the error
   path. **Phase 3 territory** — phase 1 lays the design.
10. **Test runners print actual-vs-expected by default.** No
    `--verbose` gate on `assert_return` mismatch context. The
    PASS/FAIL line stays one-line for green; FAIL lines expand
    to multi-line diagnostics. Printable values use the same
    formatter the CLI uses for `formatWasmResult`. **Phase 3
    territory** — phase 1 leaves the runner unchanged.

### Phase 1 concrete deliverables (this commit)

1. **`src/runtime/diagnostic.zig`** (Zone 1, new — first file
   in the so-far-empty `src/runtime/` directory promised by the
   §A1 / Zone 1 layout). Provides:
   - `pub const Kind = enum(u32) { ... }` — initial tag set
     covering the six `runWasm`-visible error tags
     (`engine_alloc_failed`, `store_alloc_failed`,
     `config_alloc_failed`, `module_alloc_failed`,
     `instance_alloc_failed`, `no_func_export`) plus the 11
     spec-text trap kinds already enumerated at
     `c_api/trap_surface.zig:TrapKind` (lifted into one source
     of truth per principle 1; M4 will drop the duplicate).
     Numbering is **draft** in phase 1; M4 locks it the moment
     the C-ABI accessor family ships, after which adding a tag
     is append-only.
   - `pub const Phase = enum(u32) { unknown, parse, validate,
     instantiate, execute, wasi }`.
   - `pub const Location = union(enum) { unknown }` — only
     `unknown` in phase 1; M2/M3 add variants additively (Zig
     0.16 tagged-union evolution is forward-compatible).
   - `pub const Info = struct { kind, phase, location,
     message_buf: [512]u8, message_len }`. Inline 512-byte
     buffer (matches v1 c\_api `ERROR_BUF_SIZE` and
     ClojureWasm v2's `runtime/error.zig`; the symmetry is
     cheap and v1's longest message strings sit well under
     this cap). `setDiag` doesn't allocate on the cold path
     (per principle 2).
   - `threadlocal var last_diag: ?Info = null` (Zone 1; the
     threadlocal lives at runtime layer).
   - `pub fn setDiag(phase, kind, location, comptime fmt: []const u8, args: anytype) void`
     — fills `last_diag` via `std.fmt.bufPrint`. Truncates
     silently if `fmt` overflows 512 bytes. The implementation
     uses `@branchHint(.cold)` at the function entry to hint
     the cold path (Zig 0.16 builtin; non-binding hint that
     LLVM may ignore in `Debug` / `ReleaseSafe`).
   - `pub fn clearDiag() void` and `pub fn lastDiagnostic()
     ?*const Info`. The CLI / runner reads via the latter; the
     binding entry points clear via the former.
2. **`src/cli/diag_print.zig`** (Zone 3, new). Provides:
   - `pub fn formatDiagnostic(diag: *const Info, source: Source,
     writer: *std.Io.Writer) !void` where `Source = struct {
     filename: []const u8, bytes: ?[]const u8 }`. Renders the
     §5/Q-C case for each `phase` — phase 1 supports the
     `instantiate` case directly (the boundary scope), and
     the `parse` / `validate` / `execute` / `wasi` cases at
     fall-through (kind name only) until M2/M3 fill them out.
   - `pub fn renderFallback(err: anyerror, source: Source,
     writer: *std.Io.Writer) !void` — the
     `lastDiagnostic() == null` path. Renders
     `zwasm: <filename>: <@errorName>\n` (stylistically
     aligned with the `formatDiagnostic` family rather than
     v1's `error: failed to <verb>: <@errorName>` exact form;
     the user-facing prefix `zwasm:` matches the rest of v2's
     CLI output). Unwired error sites still produce useful
     output rather than disappearing into a `null` deref.
3. **`src/main.zig`** wire-up. The `cli_run.runWasm` invocation
   wraps with the diagnostic check:
   ```
   const code = cli_run.runWasm(...) catch |err| {
       if (diagnostic.lastDiagnostic()) |diag| {
           try diag_print.formatDiagnostic(diag, source, stderr);
       } else {
           try diag_print.renderFallback(err, source, stderr);
       }
       std.process.exit(1);
   };
   ```
4. **`setDiag` at the `runWasm` boundary** in
   `src/cli/run.zig`'s `runWasmCaptured` — **9 call sites
   across 6 tags**, one immediately before each existing
   `return error.X`. Five tags map 1:1 to a single raise
   point; `NoFuncExport` is raised from four locations
   (search-loop fall-through, vector-size guard, null
   external, non-func extern) and each gets a differentiated
   message so the user sees *why* the entry lookup failed,
   not just that it did:
   - `error.EngineAllocFailed`  →
     `setDiag(.instantiate, .engine_alloc_failed, .unknown, "engine allocation failed", .{})`
   - `error.StoreAllocFailed`   →
     `setDiag(.instantiate, .store_alloc_failed, .unknown, "store allocation failed", .{})`
   - `error.ConfigAllocFailed`  →
     `setDiag(.instantiate, .config_alloc_failed, .unknown, "wasi config allocation failed", .{})`
   - `error.ModuleAllocFailed`  →
     `setDiag(.instantiate, .module_alloc_failed, .unknown, "module decode/validate failed (no further detail in phase 1)", .{})`
   - `error.InstanceAllocFailed` →
     `setDiag(.instantiate, .instance_alloc_failed, .unknown, "instantiation failed (no further detail in phase 1)", .{})`
   - `error.NoFuncExport` (search-loop)   →
     `... "no exported function found (looked for _start, main, then any export)", .{}`
   - `error.NoFuncExport` (vec-size)      →
     `... "exported function vector size mismatch", .{}`
   - `error.NoFuncExport` (null extern)   →
     `... "exported function entry is null", .{}`
   - `error.NoFuncExport` (non-func extern) →
     `... "exported entry is not a function", .{}`
   `c_api/instance.zig` and the frontend stay untouched in
   phase 1 — those error paths bubble up through `runWasm` and
   are classified at the boundary into one of the six tags
   above. M2 pushes `setDiag` deeper to gain real location info.
5. **One golden CLI test** at `test/cli/diag_print_test.zig`
   verifying that a known-failing wasm input prints something
   like `zwasm: instantiation failed for ... — module decode/validate failed`
   (matching the §5/Q-C case (c) shape), **not** the prior
   `zwasm run: ModuleAllocFailed`. Test uses an intentionally
   malformed wasm (e.g. a 4-byte magic-only buffer) to drive
   `runWasm` to `error.ModuleAllocFailed`.
6. **ROADMAP §9.6 amendment** — add row `6.K.8`:
   ```
   | 6.K.8 | Land error diagnostic system M1 only — Diagnostic core (`runtime/diagnostic.zig`) + CLI render (`cli/diag_print.zig`) + `setDiag` at the six runWasm-boundary error tags + golden CLI test. M2 (frontend location), M3 (interp trap location + trace ringbuffer — closes the runner's `result[0] mismatch`), M4 (C-ABI accessors), M5 (backtraces) are deliberately deferred per ADR-0016. | [x] |
   ```
   Status convention matches surrounding 6.K rows
   (`[x]` plain, no parenthetical phrasing).

### Out of scope (reserved for follow-up rows)

- **M2 — frontend location threading.** Parse / validate sites
  thread `Location.parse` / `.validate` through `parser.zig` /
  `sections.zig` / `validator.zig`. Adds typed helpers per
  principle 5. Lands as a future ROADMAP row (probably §9.6 /
  6.K.9 or after Phase 6 close).
- **M3 — interp trap location + trace ringbuffer wiring.**
  Each `Trap.X` raise site in `memory_ops.zig`, `mvp.zig`, etc.
  calls `setDiag(.execute, ...)` with full location. Trace
  ringbuffer at runtime; runners drain on FAIL. Closes the
  `result[0] mismatch` runner UX gap. Future row.
- **M4 — C ABI accessor family.** `zwasm_trap_kind` /
  `_phase` / `_offset` / `_func_index` / `_frames` plus
  `zwasm_get_last_error_*` exports. Drops the parallel
  `c_api.TrapKind` enum and aliases to
  `runtime.diagnostic.Kind`. Future row.
- **M5 — frame-info backtraces, faulting-address capture.**
  Post-v0.1.0; depends on JIT frame layout (Phase 7).

## Alternatives considered

### Alternative A — `*ErrorContext` parameter threaded through every call

- **Sketch**: Every function that can fail takes a final
  `?*ErrorContext` arg; on error, populate the context.
  Pattern used by some Rust crates (`anyhow`-style with explicit
  contexts).
- **Why rejected**: ROADMAP §A12 (dispatch table not pervasive
  `if`) and Phase 7 JIT (which wants `Trap!T` to lower to a
  plain `i64` return code) both reject the extra-arg cost. Hot
  paths in the dispatch loop run millions of `try` calls per
  second; adding a pointer arg materially regresses
  benchmarks. Survey §5/Q-A table confirms the cost; the
  hybrid (iv) keeps hot-path cost identical to today's plain
  error set.

### Alternative B — Tagged Result union (`Result(T, Diagnostic)`)

- **Sketch**: Replace `Trap!T` with a tagged
  `union(enum) { ok: T, err: Diagnostic }` returned by every
  fallible function.
- **Why rejected**: Wide return values spill registers in the
  Zig 0.16 ABI and break the JIT's "return code is the trap
  code" assumption. The hybrid achieves the same UX without
  this cost.

### Alternative C — Extend `wasm_trap_t` struct with zwasm fields

- **Sketch**: Add `kind: u32`, `offset: u64`, `pc: u64`, `frames:
  ?*FrameVec` directly to the C-visible struct.
- **Why rejected**: Binary compat with C hosts that ship their
  own `<wasm.h>` from upstream (`WebAssembly/wasm-c-api`). Such
  hosts allocate `wasm_trap_t` at upstream's size; if zwasm
  appends fields, the host's stack slot is undersized →
  corruption. The accessor family (principle 6) is the
  wasmtime-vetted alternative.

### Alternative D — Port v1's `formatWasmError` switch verbatim

- **Sketch**: Copy the 35-case switch from
  `~/Documents/MyProducts/zwasm/src/cli.zig:2153` into v2's CLI.
- **Why rejected**: ROADMAP §P10 / `no_copy_from_v1.md`. The
  spec-text mappings v1 uses are still valid (they're spec
  quotations), but the v1 switch lives at the CLI layer with
  no kind/phase axis — it's a flat error-tag → string map. v2's
  Kind/Phase/Location structure subsumes it; the renderer reads
  `@tagName(diag.kind)` and looks up message text from a
  comptime table indexed by `Kind`. The content is borrowed
  (spec text is upstream); the structure is fresh.

### Alternative E — Single `Trap` enum, drop `c_api.TrapKind`, use `@errorName` directly

- **Sketch**: Don't introduce `Diagnostic.Kind` at all; use
  Zig's `@errorName(err)` everywhere as the "kind" string.
- **Why rejected**: `@errorName` returns the Zig identifier
  (`OutOfBoundsLoad`), not a spec-text string; useful for
  developers but not for end-users. The Kind enum is what
  enables "spec-text per kind" (`out of bounds memory access`)
  and stable C-ABI integer codes for the M4 accessor family.
  Conflating the two locks v2 into the developer-string
  presentation forever.

### Alternative F — ClojureWasm-style `Diagnostic` verbatim

- **Sketch**: Reuse ClojureWasm's diagnostic shape directly,
  with their `Phase = { read, expand, analyze, eval }` enum.
- **Why rejected**: CW's phases describe a Lisp pipeline (read
  / expand / analyze / eval); zwasm's phases are
  parse / validate / instantiate / execute / wasi. The
  *pattern* (kind × phase × location + threadlocal + cold-side
  emit) is borrowed; the *content* is fresh. Survey appendix
  is explicit on this.

## Consequences

### Positive

- **CLI parity with v1 returns** for the common failure
  surface (instantiation failures via `runWasm`). The
  `result[0] mismatch` complaint is *not* closed by phase 1 —
  that's M3 — but the bigger v1 → v2 regression at
  `main.zig:58` is.
- **Single source of truth for error kinds** is laid down. M4
  (drop `c_api.TrapKind`, alias to `Diagnostic.Kind`) becomes
  mechanical once phase 1 ships.
- **Zero hot-path cost.** The success path returns `void` /
  `T` exactly as today. Diag emission is `@cold`-hinted and
  only runs on the trap path, which is already off the hot
  loop.
- **Forward-compatible with Phase 7 JIT.** The error set stays
  enum-only, so the JIT's "return `i64` trap code" lowering
  works unchanged. No struct-return ABI churn.
- **The 256-byte inline message buffer means `setDiag` is
  allocation-free** (per principle 2). Important for
  out-of-memory paths where allocation would compound the
  failure.
- **Tagged-union `Location`'s `unknown`-only phase 1 leaves
  M2/M3 additive** — adding `parse` / `validate` / `execute`
  variants doesn't break any phase-1 caller, since the renderer
  switches on `phase` first and only reads `location` for the
  variants it knows.

### Negative

- **Threadlocal precludes cross-thread diagnostic flow.** v2
  is single-threaded per ROADMAP §7 (Concurrency design — the
  C-API binding is single-threaded; multi-Store cross-thread
  is post-v0.1.0). Acceptable. If Phase 7+ introduces
  multi-engine multi-thread, the threadlocal moves to a
  per-`Store`-pointer slot.
- **TLS interaction with no-libc embedded builds.** Zig 0.16's
  `threadlocal var` lowers to `__thread` (Linux glibc /
  Mac aarch64 darwin TLS) or `_Thread_local` (Windows ucrt) —
  all of which are libc-supported. The c\_api binding +
  test runners + CLI all link libc today, so phase 1 is fine.
  But this means **`runtime/diagnostic.zig` is callable only
  from libc-linked compilation units**, the same constraint
  ADR-0015 documented for `util/dbg.zig`. A future no-libc
  embedded build (none today) would need either a Zig stdlib
  no-libc TLS path or a compile-mode shim that disables the
  threadlocal. No `// TODO(adr-0016): ...` comment is added
  in phase 1 because the constraint is identical to ADR-0015's
  TODO at `dbg.zig:69` — that single TODO covers the libc
  dependency family.
- **Phase 1 leaves ~120 interp `Trap.X` raise sites unwired.**
  Until M3 lands, every execute-phase trap renders via
  `renderFallback` — the `@errorName(err)` form, identical to
  today's CLI output for that path. Phase 1 fixes only the
  six `runWasm`-visible boundary tags; the
  `result[0] mismatch` runner UX gap (the original 6.K.2
  surface) is **not** closed by phase 1. Be honest about this
  at the ship-gate: phase 1 is necessary plumbing for M2/M3,
  not a user-visible UX improvement except for the
  `zwasm run foo.wasm`-fails-to-instantiate case.
- **`@branchHint(.cold)` is advisory.** LLVM may not respect
  it in `Debug` / `ReleaseSafe` builds. Negligible
  hot-path cost regardless (the branch is taken only on
  trap), but means cold-path icache eviction isn't strictly
  guaranteed in non-release. The survey doesn't name
  `@branchHint` directly — its use here is the standard
  Zig 0.16 builtin for "this branch is unlikely", not a
  survey-vetted tactic.
- **512-byte truncation.** A diagnostic message longer than
  512 bytes (after format substitution) gets truncated. v1's
  longest message strings are well under 200 bytes; the cap
  matches v1 c\_api `ERROR_BUF_SIZE` and ClojureWasm's
  `error.zig`. Audit during M3 if any execute-trap message
  wants more.
- **`Trap` ↔ `Kind` 1:1 mapping is comptime-asserted** but
  every new error tag added to `Trap` requires the same tag
  in `Kind` (and vice versa). Drift detection is a
  comptime exhaustive switch (per principle 1); enforcement
  costs ~5 lines but does add a coupling point. **Phase 1
  does NOT yet enforce the assertion** — it lands the Kind
  enum but leaves the comptime cross-check as M4 work (when
  the parallel `c_api.TrapKind` collapses into `Kind`).
- **`zig test` parallelism assumption.** Phase 1 assumes
  serial test execution within a single test binary. Per
  Zig 0.16, `zig test` runs tests in the same process
  serially; the `--listen=-` IPC path is for the build
  runner, not in-test parallelism. If a future test binary
  uses `std.Thread.spawn`, `clearDiag` becomes a setUp /
  tearDown contract — out of phase 1 scope.
- **CLI golden tests will need updating** as M2/M3 land
  per-phase richer messages. Acceptable: golden tests are
  the right place to lock UX changes.

### Neutral / follow-ups

- **M2 frontend location threading** is queued; rough estimate
  ~1 week. Will land as ROADMAP §9.6 / 6.K.9 (or post-Phase-6
  if §9.6 closes first).
- **M3 interp trap location + trace ringbuffer** — the
  load-bearing fix for the `result[0] mismatch` UX. ~1 week.
  Lands behind M2.
- **M4 C ABI accessors** — ~3 days; depends on M2 + M3 having
  populated the location variants. Drops the parallel
  `c_api.TrapKind` enum.
- **M5 frame-info backtraces + faulting-address capture** —
  post-v0.1.0; depends on JIT frame layout (Phase 7).
- **Lint rule for "no ad-hoc `return error.X` outside typed
  helpers"** (per principle 5) — would close drift, but
  zlinter's rule pipeline doesn't have this primitive yet.
  Re-evaluate at Phase 8 zlinter expansion.

## References

- ROADMAP §9.6 (Phase 6 reopen-scope; this ADR amends to add
  row 6.K.8)
- ROADMAP §P3 (cold-start no-allocation), §P10 (no copy-paste
  from v1), §A12 (dispatch table not pervasive `if` — the spirit
  of this principle motivates Alt A's rejection: no per-call-site
  overhead)
- ROADMAP §7 (Concurrency design — single-threaded C-API binding;
  the threadlocal `last_diag` lives within this constraint)
- ADR-0014 (redesign + refactoring sweep before Phase 7) — the
  K-stream context this ADR supports
- ADR-0015 (canonical debug toolkit) — sister ADR landed
  earlier today; the `dbg.zig` logger is independent of this
  diagnostic system but the two are coordinated under the
  same handover override cycle
- ADR-0013 (wast\_runtime\_runner detailed design) — the
  `--trace` callback that principle 9's trace ringbuffer hook
  extends
- ADR-0009 (zlinter `no_deprecated` gate) — `require_exhaustive_enum_switch`
  is the lint that enforces principle 1's `Trap` ↔ `Kind`
  drift detection
- Survey: [`private/notes/error-system-survey.md`](../../private/notes/error-system-survey.md)
  (gitignored, 873 lines; §5 has the five-question answers,
  §6 the design principles lifted verbatim above, §7 the
  M1–M5 migration path)
- v1 `formatWasmError`:
  `~/Documents/MyProducts/zwasm/src/cli.zig:2153` (read-only
  reference for spec-text content; structure deliberately
  diverges per P10)
- v2 regression site: `src/main.zig:58` (bare
  `@errorName(err)` print)
- v2 duplicated enums:
  `src/interp/mod.zig:121` (`Trap`, 12 tags) +
  `src/c_api/trap_surface.zig:34` (`TrapKind`, 11 tags) +
  `c_api/trap_surface.zig:mapInterpTrap` (the glue)
- ClojureWasm v2 reference:
  `~/Documents/MyProducts/ClojureWasmFromScratch/src/runtime/error.zig`
  + `error_print.zig` (the `Phase × Kind × Location + threadlocal`
  pattern this ADR borrows. **CW v2 is in Zig, not Clojure** —
  the `.cljc` file the survey originally cited does not exist;
  the actual sources are these `.zig` files. CW's phases differ
  from zwasm's — see Alternative F)
- wasmtime trap encoding:
  `~/Documents/OSS/wasmtime/crates/environ/src/trap_encoding.rs:64`
  (single shared enum across runtime + c-api; the model for
  principle 1. Path corrected from a previous draft that wrote
  `crates/wasmtime/src/runtime/`.)
