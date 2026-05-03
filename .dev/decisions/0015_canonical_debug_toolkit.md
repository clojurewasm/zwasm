# 0015 — Adopt canonical debug toolkit for Phase 6+

- **Status**: Accepted
- **Date**: 2026-05-04
- **Author**: zwasm v2 / continue loop
- **Tags**: phase-6, debug, tooling, observability, infrastructure

## Context

The §9.6 / 6.K.2 migration ("Single-allocator Runtime + Instance
back-ref") surfaced a `0xAA`-fill regression in
`partial-init-memory-segment/load`: cross-module-imported memory
slices were being poisoned by Zig 0.16's `Allocator.free` wrapper
(`@memset(slice, undefined)` before delegating to `rawFree`). The
hunt cost an hour of edit / rebuild / `std.debug.print` cycles
because the project had no standing tooling for any of:

- module-scoped logging that doesn't require source edits;
- AddressSanitizer / UBSan integration (`-fsanitize=address` is
  available in Zig 0.16's `std.Build.Module.sanitize_c` field but
  was never wired);
- a reproducer harness so the failing fixture survives the bug
  fix as a guard against regression;
- `wasm-tools dump` / `wasm-objdump` / `lldb` reachable from the
  Nix dev shell on every host.

This will recur. Phase 6's remaining K-stream work (6.K.3
cross-module imports, 6.K.4 element forms 5/6/7, 6.K.6
partial-init re-measure) all touch the same allocator and
ownership surfaces. Phase 7 (JIT v1 ARM64 baseline) will introduce
mmap/munmap of executable pages, register-allocator validation, and
emit-time invariants where ad-hoc debug is even more expensive.

ROADMAP §A2 (file-size cap) and §A12 (no-pervasive-if dispatch)
both rely on the contributor catching subtle invariants. Without
a debug toolkit, every catch is a manual rebuild loop. Per ROADMAP
§P3 (cold-start / no-allocation-per-call), runtime overhead is
forbidden — but **debug overhead at debug time** is fair game and
must be opt-in / zero-cost in non-safe release builds.

A research survey
([`private/notes/debug-toolkit-survey.md`](../../private/notes/debug-toolkit-survey.md),
588 lines, gitignored) compared Zig 0.16's `DebugAllocator`,
`sanitize_c`, LLDB watchpoints, Valgrind / Mac `leaks` /
Instruments, `wasm-tools` / wabt, `bytehound` / `heaptrack`, `rr`,
and Windows ucrt `_CrtSetDbgFlag` / Application Verifier across
the three target hosts. The survey's top-3 ranked recommendations
(`dbg.zig` logger, `-Dsanitize=address` opt-in, `private/dbg/`
reproducer template) close ~80% of the recurrence risk.

A v1 grep for comparable utilities (`getenv` / `dbg.zig` / scoped
logger) returned only two `getenv` mentions in v1's `cli.zig:77`
and `platform.zig:625`, both as forward comments. v1 has no
analogue; this ADR introduces genuinely new code, not a v1
carry-over. ROADMAP §P10 / `no_copy_from_v1.md` is satisfied.

### What lands where (commit map)

The toolkit lands in three commits, each independently revertible:

1. **Commit `6b8981d` (already on `origin/zwasm-from-scratch`)** —
   `src/util/dbg.zig` (the env-gated logger), `flake.nix` additions
   (`wasm-tools` + `lldb`), `private/dbg/_template/` skeleton, a
   demonstrator `dbg.print` call site at `instantiateRuntime`'s
   memory-allocation branch, and the test wiring in `src/main.zig`.
   That commit's message references `ADR-0015 candidate, pre-draft`
   as a forward link; this ADR is the §18 cover and the rationale.
2. **The commit that lands this ADR** — the present file plus the
   ROADMAP §9.6 amendment (row `6.K.7`). Per ROADMAP §18.2 step 4,
   that commit message references this ADR explicitly so
   `git log -- .dev/ROADMAP.md` is browseable for cause.
3. **A future commit (tracked as §9.6 / 6.K.7)** — the residual
   `-Dsanitize=address` build option and the `zig build run-repro
   -Dtask=<name>` step.

The ROADMAP §9.6 amendment that adds row `6.K.7` lands in commit
(2). This satisfies the §18.2 four-step contract: amend in place,
ADR exists, handover synced, ADR referenced in the commit.

## Decision

Adopt a four-part canonical debug toolkit, supported by two
infrastructure changes (Nix flake + ROADMAP).

### Part 1 — `src/util/dbg.zig` env-gated logger (LANDED in `6b8981d`)

`ZWASM_DEBUG=mod[,mod...]` selects which modules emit. Static-
string keys, prefix matching (`interp` enables `interp.alloc` /
`interp.dispatch` / …), `*` enables every module. The whitelist
parses lazily on the first `dbg.print` call, then caches in a
static buffer (4 KiB env-string capacity, 64 entry limit; silent
truncation past those bounds — debug paths only, accepted).

**Release-mode semantics** (load-bearing): the early-exit guard at
`dbg.zig:99` and `dbg.zig:125` strips the call site **only on
`ReleaseFast` and `ReleaseSmall`** via a `builtin.mode` check.
`ReleaseSafe` (used for hosted CI lanes that want safety checks
without the full Debug overhead) **still emits** the env read +
filter check, because `ReleaseSafe` exists to validate runtime
invariants and silencing the logger there would defeat that. So
the precise statement is: "non-safe release builds emit zero code
at the call site; `ReleaseSafe` and `Debug` evaluate the filter."
The ADR previously said "release builds emit zero code" — that
imprecision is fixed here.

**libc requirement** (interaction with ROADMAP §P5): the
implementation reads `ZWASM_DEBUG` via `std.c.getenv` because Zig
0.16 dropped `std.posix.getenv` and `std.process.getEnvVarOwned`
needs an allocator (which the lazy-init code path doesn't have).
This means **`dbg.zig` is callable only from libc-linked
compilation units**. The c\_api binding already links libc per the
shipping wasm-c-api contract; the wast\_runtime\_runner /
realworld\_run\_runner / spec\_runner test binaries also link libc
(verified via build.zig). Pure-Zig binaries (currently none in
this project; potentially a future libc-free `zwasm` build for
embedded contexts) would fail to link `dbg.zig` and would need
either a no-op compile-mode shim or a wholly different mechanism.
The TODO comment at `dbg.zig:69` documents this per
`.claude/rules/no_workaround.md` (a Zig 0.16 stdlib-gap workaround
with explicit expiry condition).

Module taxonomy (initial):

- `c_api.alloc` — `instantiateRuntime` allocator decisions
- `c_api.exports` — export wiring
- `interp.alloc` — Runtime resource allocations (memory /
  globals / tables / func\_entities)
- `interp.dispatch` — dispatch loop entries (high-volume; off by
  default)
- `interp.trap` — trap raise events
- `frontend.parse` — section decoder positions
- `frontend.validate` — validator type-stack transitions

Call sites are added incrementally as bugs are diagnosed; each
call site lives next to the code it observes, not in a central
log point.

### Part 2 — `-Dsanitize=address` build option (PENDING — §9.6 / 6.K.7)

Wire `module.sanitize_c = .full` (and `module.sanitize_thread =
true`) through `addExecutable` / `addTest` when `-Dsanitize` is
set. Zig 0.16's `std.zig.SanitizeC` enum variants: `.off`,
`.trap`, `.full`. `.full` enables clang ASan + UBSan on Mac
aarch64 and Linux x86_64; **skip on Windows ucrt** (clang
ASan/Win32 needs an MSVC redist that doesn't ship through the
Nix dev shell).

Adopted as a **weekly OrbStack ASan lane**, not per-commit. ASan
adds ~2× runtime overhead (survey §1.2) and meaningful memory
overhead (the survey doesn't quote a precise multiplier; clang
ASan's published shadow-memory ratio is ~2× but real-world heap
growth varies — measure during 6.K.7 implementation). Catches
use-after-arena-free, out-of-bounds-load, and double-free at the
moment of the bad access with a real stack trace.

### Part 3 — `private/dbg/<task>/` reproducer template (LANDED in `6b8981d`)

Each Phase 6+ regression that requires more than `ZWASM_DEBUG=`
to diagnose lands a directory:

- `README.md` — symptom, hypotheses tried, root cause, principle
  the fix restored.
- `fixture.wat` (or `.wasm`) — the smallest input that triggers.
  `wasm-tools shrink` aids reduction.
- `repro.zig` — standalone harness that exits 0 when the bug is
  fixed, 1 when reproduced, 2 on setup error.
- `investigation.md` (optional) — chain of hypotheses for
  future-self.

Gitignored under `private/`; repros stay locally as a "things
that broke once" mini-corpus that the contributor consults
before chasing similar-looking bugs.

### Part 4 — `zig build run-repro -Dtask=<name>` step (PENDING — §9.6 / 6.K.7)

Discovers `private/dbg/<task>/repro.zig` and links it against the
zwasm modules with the same options as the test binaries. Lets
the contributor iterate on a single repro without re-running the
full test suite. Skipped silently when `private/dbg/<task>/`
doesn't exist; never required for a green CI run.

### Supporting change — `flake.nix` additions (LANDED in `6b8981d`)

Added: `pkgs.wasm-tools` (dump / validate / print / strip / smith
/ shrink / objdump / metadata-show — Phase 6+ debug + Phase 7
fuzz corpus prereq) and `pkgs.lldb` (interactive debugger +
watchpoints; Mac CLT version varies, Nix copy guarantees a
known-good version on every host). `dsymutil` arrives via the
existing clang. The justification for adding `wasm-tools`
specifically (despite `wabt`'s `wasm-objdump` already shipping):
`wasm-tools smith` and `wasm-tools shrink` are Phase 7 fuzz
corpus prerequisites that wabt does not provide; landing both now
avoids a flake-touch later.

Windows-specific tooling deliberately **not** added (Zig 0.16
doesn't emit MSVC debug CRT artefacts; Windows debug stays
runtime-via-`dbg.zig` + `DebugAllocator`).

Cost: ~50 MB extra closure on Mac, ~120 MB on Linux. Acceptable
for a dev shell.

### Supporting change — ROADMAP §9.6 amendment (lands in this commit)

Insert immediately after `6.K.6`:

```
| 6.K.7 | Land `-Dsanitize=address` build option + `zig build run-repro -Dtask=<name>` step (per ADR-0015 §1.2 + §1.4). Mac + OrbStack only; Windows skip per ASan-ucrt gap. | [ ] |
```

`6.K.7` is a normal Phase 6 close blocker per §9.6 / 6.J's
"every 6.K.\* row above is `[x]`" contract. It runs alongside
6.K.3〜6.K.6 in any order; it does **not** depend on the
funcref/ownership cascade so it can land in parallel with 6.K.3
implementation if convenient.

## Alternatives considered

### Alternative A — `gdb` instead of `lldb`

- **Sketch**: Adopt `gdb` as the canonical debugger; add to flake
  on Linux only.
- **Why rejected**: Mac aarch64 has no `gdb` support — Apple
  blocks debugger entitlements. LLDB is the only option on Mac;
  using two debuggers across hosts fragments the watchpoint
  recipe and any documented investigation procedure. LLDB is the
  uniform choice.

### Alternative B — `std.log` instead of `dbg.zig`

- **Sketch**: Use `std.log` with a custom `std_options.logFn` and
  per-scope log levels.
- **Why rejected**: `std.log`'s scope filtering is comptime, but
  the levels are **runtime** parameters (or comptime via root's
  `std_options.log_level`, which is a single global). `std.log`
  doesn't compile-strip in `ReleaseSafe` (which we run in CI
  lanes), so a mis-set level still emits format-string code. The
  bigger problem is that `std.log` ties the project to Zig
  stdlib's logger contract (severity levels, scope tags, default
  formatter) when zwasm doesn't have a coherent severity model
  yet — the env-gated key/value approach is more honest about
  what's actually happening. The minor duplication is acceptable.

### Alternative C — Always-on AddressSanitizer

- **Sketch**: Make `-Dsanitize=address` the default for `zig
  build test-all`.
- **Why rejected**: 2× runtime overhead would push every three-
  host A13 gate from minutes to tens of minutes. ASan belongs in
  a weekly opt-in lane, not the per-commit gate. Windows ucrt
  also can't run ASan without MSVC redist — always-on would mean
  the three-host gate splits.

### Alternative D — `bytehound` / `heaptrack` for memory profiling

- **Sketch**: Add a heap profiler to catch arena fragmentation /
  unbounded allocator growth.
- **Why rejected**: `bytehound` is unmaintained since 2023 and
  Linux-only. `heaptrack` is correct but Phase 7 territory
  (we're not memory-bound yet). Defer to Phase 7 JIT bring-up
  ADR.

### Alternative E — `rr` (record / replay) for non-determinism

- **Sketch**: Add `rr` to the Linux flake for time-travel
  debugging.
- **Why rejected**: Linux x86_64 only, requires hardware perf
  counters that OrbStack may not expose, slow. Phase 6 bugs are
  deterministic — `rr` is for Phase 7 JIT non-determinism.
  Re-evaluate when a non-deterministic bug actually surfaces.

### Alternative F — Windows ucrt-specific tooling (`_CrtSetDbgFlag` / Application Verifier)

- **Sketch**: Mirror the Mac/Linux toolkit on Windows with
  Microsoft's debug surfaces.
- **Why rejected**: Both require MSVC debug CRT artefacts that
  Zig 0.16 doesn't emit. Wiring them would need either an MSVC
  toolchain detour or a custom Zig fork — both out of scope for
  v0.1.0. Windows debug relies on `dbg.zig` (cross-platform) and
  `DebugAllocator` (cross-platform) for now.

### Alternative G — Valgrind on OrbStack

- **Sketch**: Add `pkgs.valgrind` to the Linux-only flake branch
  + `scripts/run_valgrind.sh` wrapper.
- **Why rejected (for now)**: Valgrind on a Zig-emitted aarch64
  binary fails to support some instructions; on x86_64 it works
  but covers the same bug class as ASan with worse signal-to-
  noise. ASan is the chosen mechanism. Valgrind revisits if a
  specific Phase 7 bug surfaces that ASan misses (rare).

### Alternative H — `-Dstrict-alloc` (DebugAllocator-strict opt-in)

- **Sketch**: A toggle that swaps `c_allocator` for
  `DebugAllocator(.{ .never_unmap = true, .retain_metadata =
  true, .canary = ... })` in the wast\_runtime\_runner /
  realworld\_run\_runner.
- **Why rejected (for now)**: Survey §6 item 5 ranked this as
  "useful, redundant with ASan on hosts where ASan works."
  Promote to a follow-up if Windows-specific UAF bugs surface
  that ASan can't catch (since Windows skips ASan). Not blocking
  for Phase 6 close.

## Consequences

### Positive

- **Recurrence risk for the 0xAA-class bug drops to ~0.** Future
  arena / ownership migrations land a `dbg.print("interp.alloc",
  ...)` call once and use `ZWASM_DEBUG=interp.alloc` to verify
  invariants without rebuilding.
- **Phase 7 starts with a reproducer corpus.** Every Phase 6
  K-stream regression that uses `private/dbg/<task>/` becomes a
  guard against the bug's return when JIT semantics are wired.
- **ASan lane catches use-after-arena-free, out-of-bounds-load,
  and double-free bugs at the moment of the bad access with a
  real stack trace.** This was exactly the bug class that
  consumed an hour in 6.K.2.
- **Three-host A13 gate cost is unchanged.** ASan is a separate
  weekly lane; `dbg.zig` is opt-in via env; the repro step is
  silent when no task is named.
- **Each piece is independent.** Reverting any one of dbg.zig /
  ASan / repro template / flake additions doesn't affect the
  others.
- **Phase 7 fuzz corpus tooling lands now**, not on the day the
  fuzz lane is opened — `wasm-tools smith` / `shrink` are
  available as soon as the dev shell rebuilds.

### Negative

- **`dbg.zig` requires libc** — `std.c.getenv` is the only
  no-allocator env-read in Zig 0.16. Compilation units that
  don't link libc (none today; potentially a future embedded
  build) cannot use `dbg.zig`. The TODO comment at `dbg.zig:69`
  per `no_workaround.md` documents the upstream gap (Zig
  dropped `std.posix.getenv` between 0.14 and 0.16) and the
  expiry condition (a future libc-free env-read in stdlib, or a
  fall-back path that uses `std.process.environ_map` from a
  Juicy Main when available).
- **`ReleaseSafe` doesn't strip dbg call sites.** The env read +
  filter check still runs there. This is intentional (CI lanes
  using ReleaseSafe want trace coverage), but it does mean
  `ReleaseSafe` benchmarks aren't valid baselines for runtime
  cost claims. Use `ReleaseFast` or `ReleaseSmall` for that.
- **`dbg.zig` global state is not thread-safe.** The `whitelist`
  static is single-init via the `whitelist_initialised` flag
  with no atomics; concurrent first-touch from two threads risks
  a torn whitelist. This is acceptable for the current single-
  threaded test runner and the c\_api invocation pattern; revisit
  if Phase 7 introduces threaded JIT background compilation.
- **Static buffer truncation is silent.** `ZWASM_DEBUG` >4 KiB
  is silently capped (`dbg.zig:82`); >64 entries is silently
  dropped (`dbg.zig:90`). Sane developer values stay well below
  these — but worth documenting if a contributor ever pastes a
  giant filter string.
- **ASan lane on OrbStack is ~2× slower.** Mitigated by running
  weekly, not per-commit. If 6.K.7 lands in Phase 6, the lane
  fires once before Phase 6 close — useful as a one-shot
  verification, not as ongoing CI cost.
- **`private/dbg/` discipline depends on contributor adherence.**
  The build step (Part 4) makes it discoverable but doesn't
  enforce "land a repro before fix". Cultural convention; revisit
  if Phase 7 surfaces orphaned repros. A `continue` skill
  amendment that *requires* a `private/dbg/<task>/` directory at
  the close of any regression-hunt cycle would mechanise this —
  filed as a follow-up rather than a hard rule today.

### Neutral / follow-ups

- **`-Dstrict-alloc` (DebugAllocator with `.never_unmap` +
  `.retain_metadata`)** — see Alternative H. Defer.
- **LLDB watchpoint recipe at `private/dbg/lldb_watchpoint_recipe.md`**
  — survey §6 item 6. Land alongside the first repro that uses
  it; not blocking.
- **`MallocStackLogging=1` Mac wrapper at `scripts/run_with_malloc_debug.sh`**
  — survey §1.4. Zero cost to add if needed; deferred until a
  Mac-only allocator bug actually surfaces.
- **`audit_scaffolding` integration** — adding `wasm-tools
  validate fixture.wasm` to the audit's "lies" pass is a 10-line
  follow-up. Queue for Phase 7 if useful.
- **Heaptrack / bytehound revisit at Phase 7** — see
  Alternative D.

## References

- ROADMAP §9.6 (Phase 6 reopen-scope; this ADR amends to add row
  6.K.7)
- ROADMAP §P3 (cold-start no-allocation), §P5 (link\_libc=false
  on host, surfaced as a tension by `dbg.zig`'s libc requirement),
  §P10 (no copy-paste from v1; v1 has no analogue, satisfied),
  §A2 (file-size cap), §A12 (no-pervasive-if dispatch)
- ADR-0014 (redesign + refactoring sweep before Phase 7) — the
  K-stream context this ADR supports
- ADR-0009 (zlinter `no_deprecated` gate) — Mac-host build option
  precedent
- ADR-0013 (wast\_runtime\_runner detailed design) — the `--trace`
  hook is the existing observability surface; `dbg.zig`
  complements it for non-trace inspection points
- `.claude/rules/no_workaround.md` — TODO + expiry-condition
  contract that `dbg.zig:69` follows for the libc / posix.getenv
  gap
- Survey: [`private/notes/debug-toolkit-survey.md`](../../private/notes/debug-toolkit-survey.md)
  (gitignored, 588 lines; §4.2 has the dbg.zig sketch, §1.2 the
  ASan flag wiring, §5.1–§5.3 the per-host flake recommendations)
- Commit `6b8981d` — landing the three "LANDED" parts above
- Zig 0.16.0 release notes: <https://ziglang.org/download/0.16.0/release-notes.html>
- Zig 0.15.1 release notes (`sanitize_c` API change): <https://ziglang.org/download/0.15.1/release-notes.html>
- `std.Build.Module` source (`sanitize_c` field): <https://github.com/ziglang/zig/blob/master/lib/std/Build/Module.zig>
- DebugAllocator source: <https://github.com/ziglang/zig/blob/master/lib/std/heap/debug_allocator.zig>
- wasm-tools: <https://github.com/bytecodealliance/wasm-tools>
- ziglang/zig#15439 (macOS `dsymutil` requirement): <https://github.com/ziglang/zig/issues/15439>
