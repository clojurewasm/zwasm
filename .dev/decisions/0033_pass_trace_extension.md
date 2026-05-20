# 0033 — Per-pass diagnostic extension to the trace ringbuffer

- **Status**: Accepted
- **Date**: 2026-05-09
- **Author**: Phase 8 / §9.8a / 8a.1-a autonomous /continue cycle
- **Tags**: roadmap, phase8, diagnostic, trace, observability, jit

## Context

ADR-0032 reorganised Phase 8 into a foundation-first §9.8a
followed by a bench-driven §9.8b. The first foundation row,
**§9.8a / 8a.1**, extends ADR-0028's M3-a trace ringbuffer with a
*per-pass* diagnostic surface. The §9.8a rationale was forced by
two cross-cycle failure modes during 8.4 Hoist:

1. **"is this pass even firing?"** — 8.4-d landed a hoist
   pipeline integration behind `max_hoists_per_func = 4`
   (`4d6fc0b`) without a runtime-observable signal that a
   given hoist actually applied. The cap=4 partial integration
   maintains 52/55 compile-pass + 15/55 RUN-PASS, but whether
   the cap fired or hoist was simply skipped on a given
   fixture is invisible to the realworld_run_jit runner. 8a.5
   (D-053 cap-removal investigation) needs this signal as its
   primary correctness gate.
2. **"which pass cost the latency?"** — bench-delta-per-commit
   (8a.3) has to attribute regressions to specific passes
   (`hoist`, `liveness`, `regalloc`, `emit`, `lower`); without
   a per-pass enter/exit record there is no ground truth for
   the attribution.

The v1 retrospective recurrence here is identical to ADR-0028's:
v1 had a `--trace=jit,regir,...` flag that surfaced per-pass
boundaries; v2's M3-a covered `bounds` + (planned) `trap` only,
so per-pass observability was a gap. ADR-0028's `Category` enum
was already designed to be extensible (4-bit field, 6 used / 10
reserved), and the §9.8a reorg makes it the immediate next
extension.

### Existing infrastructure to extend

- `src/diagnostic/trace.zig:38` — `Category` enum with 4 reserved
  slots used (`bounds=0`, `trap=1`, `regalloc=2`, `jit=3`,
  `exec=4`, `regir=5`). Slot 6 is the next free index.
- `src/diagnostic/trace.zig:77` — `TraceEntry` is `packed
  struct(u64)` with `category: u4 + event: u4 + payload_a: u24 +
  payload_b: u32`. Layout is fixed; extension is purely
  per-category event/payload semantics.
- `src/diagnostic/trace.zig:34` — `enabled: bool =
  build_options.trace_ringbuffer`. The `-Dtrace-ringbuffer`
  build flag (`build.zig:55`) gates the entire mechanism at
  compile-time per ROADMAP §A12. The pass extension reuses this
  same flag — no new build-matrix axis.
- `src/ir/zir.zig:559` — `ZirFunc` carries the analysis-slot
  pattern (`?LoopInfo`, `?Liveness`, `?ConstantPool`); a new
  `?PassDiagnostics` slot mirrors that shape per ROADMAP §P13
  (day-1 reservation; field added now, populator wired in
  8a.1-c).
- `src/engine/codegen/shared/compile.zig:97-127` — the JIT
  pipeline: `lowerer.lowerFunctionBody → loop_info.compute →
  hoist.run → liveness.compute → regalloc.compute →
  emit.compile`. Five passes; each is the wrap target for
  enter/exit events.

### What the §9.8a rows downstream of 8a.1 expect from this surface

- **8a.2 (JIT-execution sentinel)** — orthogonal mechanism;
  doesn't depend on per-pass trace, but shares the
  `ZWASM_DIAG=` opt-in vocabulary so the `passes` token here
  composes with `jit_exec` later.
- **8a.3 (bench-delta-per-commit)** — reads per-pass timing /
  application counts from the per-function `PassDiagnostics`
  slot to attribute regressions.
- **8a.4 (`ZWASM_DIAG=passes,...`)** — the env var surface
  flips the build-time `enabled` flag's runtime visibility on,
  drains the ringbuffer at process exit / fixture boundary.
- **8a.5 (D-053 cap-removal investigation)** — primary
  consumer; uses `applied_count` + `skipped_count` from the
  hoist `PassDiagnostics` entry to verify that cap removal
  raises the application count without breaking the
  realworld_run_jit baseline.

## Decision

**Land a per-pass diagnostic extension that occupies trace
`Category.pass = 6` and a new `ZirFunc.pass_diagnostics:
?PassDiagnostics` slot, both gated by the existing
`-Dtrace-ringbuffer` build flag.** Two channels:

1. **Ringbuffer channel (cross-cut, temporal)** — every pipeline
   stage emits one `pass_enter` and one `pass_exit` `TraceEntry`
   into the per-thread ring. Captures pass ordering across
   funcs; drains on trap or process exit. Consumed by post-
   mortem dumps and the planned `ZWASM_DIAG=passes` surface.
2. **Per-function slot (local, structured)** — each pass writes
   one `PassRecord` into `func.pass_diagnostics.entries` at
   exit time, carrying a small structured summary. Consumed by
   unit tests, the 8a.5 cap-removal investigation, and
   bench-delta attribution.

The two channels share the `passEnter()` / `passExit()` write
sites. Both fold to no-ops via `comptime` branches when
`trace.enabled == false`, preserving zero release-build overhead
per ROADMAP §A12.

### Concrete shape

#### `Category.pass = 6` and pass-id catalogue

`src/diagnostic/trace.zig` extension:

```zig
pub const Category = enum(u4) {
    bounds = 0,
    trap = 1,
    regalloc = 2,
    jit = 3,
    exec = 4,
    regir = 5,
    pass = 6,           // ← new (this ADR)
    _,
};

pub const PassEvent = enum(u4) {
    pass_enter = 0,
    pass_exit = 1,
    _,
};

pub const PassId = enum(u8) {
    lower = 0,
    loop_info = 1,
    hoist = 2,
    liveness = 3,
    regalloc = 4,
    emit = 5,
    _,                  // 250 spare for future passes
};
```

`PassId` is a separate `u8` enum (not packed into `payload_a`)
because the ringbuffer's `payload_a: u24` and the per-function
slot's `PassRecord` both reference it; separating it from the
event-tag shape keeps the catalogue extensible without churning
the `TraceEntry` packed-struct layout.

For ringbuffer entries with `category = .pass`:

| Field | Semantics |
|---|---|
| `event` | `.pass_enter` or `.pass_exit` |
| `payload_a` | `func_idx (u20) << 4 \| pass_id_lo4 (u4)` — matches the existing pattern of using `payload_a: u24` to carry func-relative context. |
| `payload_b` | enter: 0; exit: packed summary digest (see PassRecord below) |

The 4-bit `pass_id_lo4` is the low nibble of `PassId`; the high
nibble lives in the per-function slot only (where the full
`PassId` is unambiguous). 16 of 256 PassIds is enough for the
visible Phase 8 surface; if §9.8b lands more passes the encoding
adjusts in a follow-up ADR.

#### `passEnter()` / `passExit()` API

```zig
pub inline fn passEnter(func_idx: u32, pass: PassId) void {
    if (comptime !enabled) return;
    writeEntry(.{
        .category = .pass,
        .event = .pass_enter,
        .payload_a = packPass(func_idx, pass),
        .payload_b = 0,
    });
}

pub inline fn passExit(func_idx: u32, pass: PassId, summary: PassSummary) void {
    if (comptime !enabled) return;
    writeEntry(.{
        .category = .pass,
        .event = .pass_exit,
        .payload_a = packPass(func_idx, pass),
        .payload_b = summary.digest(),
    });
}
```

Both are `inline`; the `comptime !enabled` branch dead-code-
eliminates the body in release builds with `-Dtrace-ringbuffer=
false`. Same shape as the existing `writeBounds`.

#### Per-function `PassDiagnostics` slot

`src/ir/zir.zig` adds:

```zig
pub const PassRecord = struct {
    pass: PassId,
    applied: u32,
    skipped: u32,
    extra: u32,         // pass-specific; documented per call site
};

pub const PassDiagnostics = struct {
    entries: []const PassRecord = &.{},
};

pub const ZirFunc = struct {
    // ... existing fields ...
    loop_info: ?LoopInfo = null,
    liveness: ?Liveness = null,
    constant_pool: ?ConstantPool = null,
    pass_diagnostics: ?PassDiagnostics = null,  // ← new
    // ... existing fields ...
};
```

Slot ownership mirrors `LoopInfo` / `Liveness`: borrowed slice;
caller owns the lifetime; freed by `compileOne`'s
`deinitFuncResult` symmetric to existing slots. The slot is
populated only when `trace.enabled == true`; otherwise the
`?PassDiagnostics` stays `null` and the slot is dead state.

#### Per-pass summary (`PassSummary` + per-pass interpretation of `extra`)

The `applied` / `skipped` axes are common; `extra` is per-pass.
This avoids the "single slot dual meaning" anti-pattern by
documenting `extra`'s semantics on each pass's call site:

| PassId | `applied` | `skipped` | `extra` |
|---|---|---|---|
| `lower` | wasm-ops lowered | (always 0) | resulting `instrs.len` |
| `loop_info` | loop frames found | non-loop frames seen | (always 0) |
| `hoist` | const → local rewrites | hoist candidates skipped | synthetic locals added |
| `liveness` | vregs analysed | (always 0) | range-table length |
| `regalloc` | vregs assigned | spill decisions | high-water slot id |
| `emit` | ZirInstrs emitted | (always 0) | bytes emitted |

`PassSummary.digest()` computes a `u32` for the ringbuffer's
`payload_b` slot — a compact representation that captures the
"applied + skipped" counters in 16 + 16 bits (saturating at
`maxInt(u16)` per side). The full structured record only lives
in the per-function slot.

`PassSummary.digest()` is **lossy by design**: when `applied >
65535` the ringbuffer entry saturates and the per-function slot
is the source of truth. This matches ADR-0028's existing
truncation discipline (`func_idx → u24`); the reader interprets
ringbuffer payloads as approximate.

#### Pipeline wiring (8a.1-d preview, not in this ADR's scope)

`compile.zig`'s pipeline body becomes:

```zig
trace.passEnter(func_idx, .lower);
try lowerer.lowerFunctionBody(allocator, body, &func, module_types);
trace.passExit(func_idx, .lower, .{ .applied = ..., .skipped = 0, .extra = ... });
```

…repeated for each of the 5 passes. The `passExit` summary value
is computed by each pass's `run()` returning a `PassSummary` (or
`compute()` returning one as part of its existing return tuple);
the wrappers in `compile.zig` thread it into both the ringbuffer
entry and the per-function slot. Concrete API + slot-population
mechanics land in 8a.1-c (slot helpers) + 8a.1-d (call-site
wiring).

### What this ADR does NOT do

- **No new build flag** — reuses `-Dtrace-ringbuffer` from
  ADR-0028. Default `false` in release; `true` in debug +
  release-safe.
- **No runtime opt-in surface** — `ZWASM_DIAG=passes` is 8a.4's
  scope. This ADR covers the recording layer.
- **No bench-delta attribution mechanics** — that's 8a.3.
- **No JIT-execution sentinel** — that's 8a.2's separate
  prologue inject.
- **No ZirFunc slot field added in this commit** — 8a.1-a is
  design framing only; 8a.1-c lands the slot field + helpers.

## Alternatives considered

### Alternative A — Ringbuffer-only (no per-function slot)

- **Sketch**: emit `pass_enter` / `pass_exit` ringbuffer entries
  but skip the `?PassDiagnostics` slot on `ZirFunc`. Tests +
  8a.5 read by draining the ringbuffer post-compile.
- **Why rejected**:
  1. **Read pattern mismatch**: 8a.5 needs structured per-func
     access ("did hoist apply on this func, and how many
     times?"). The ringbuffer is temporally ordered and
     wraps at 32 entries; for a multi-function module the
     hoist record on func 0 is overwritten before the test
     reads it.
  2. **Test ergonomics**: unit tests asserting "hoist applied
     N times on `tinygo_fib`" would have to carry ringbuffer
     drain + filter logic on every assertion site. A
     `func.pass_diagnostics` direct lookup is one line.
  3. **Ringbuffer + slot shares write site**: the additional
     cost of populating the slot is one `append` per pass;
     amortised across the 5 passes per func it's negligible
     vs. the ringbuffer write itself.

### Alternative B — Per-function slot only (no ringbuffer category)

- **Sketch**: skip `Category.pass = 6`; write only to
  `func.pass_diagnostics.entries`. Cross-pass / cross-func
  ordering reconstructed from the per-func entries.
- **Why rejected**:
  1. **Trap-time post-mortem**: the ringbuffer's drain-on-trap
     pattern (ADR-0028's primary use case) doesn't extend
     across function boundaries — per-function slots are not
     accessible from a trap stub mid-compile. The ringbuffer
     is the only channel that captures "what was the JIT
     doing when the trap fired".
  2. **Cross-func ordering**: the `regalloc` v1 W54 case is
     cross-func; coalescer decisions on func A interact with
     spill decisions on func B. A temporal log captures this;
     per-func slots do not.
  3. **§9.8b consumers**: bench-delta attribution wants both
     per-func breakdown AND temporal pass-cost ordering;
     two channels match two read patterns naturally.

### Alternative C — Ad-hoc `dbg` prints (status quo without infra)

- **Sketch**: add `dbg.printPass(func_idx, pass, summary)` calls
  at each pass site; rely on `ZWASM_DEBUG=passes` env var.
- **Why rejected**:
  1. **Same anti-pattern v1 paid for**: `--trace=jit,regir,...`
     in v1 was a per-event stderr print; debugging required
     redirect + grep + correlate by timestamp (ADR-0028's
     Alternative B rejection text).
  2. **No structured access**: tests can't assert "hoist
     applied N times" cheaply; have to grep stdout.
  3. **Cost in release builds**: `dbg.print` is runtime-
     branched, not comptime. Even no-op'd, the call overhead
     pollutes the JIT compile path.

### Alternative D — Closed `PassId` enum (no extensible `_`)

- **Sketch**: declare `PassId` as `enum(u8) { lower, loop_info,
  hoist, liveness, regalloc, emit }` with no `_` extension.
- **Why rejected**:
  1. §9.8b lands at least one new pass (Coalescer); maybe
     two (Regalloc upgrade introduces live-range splitting
     phases). Closing the enum forces an ADR for every new
     pass, which is friction without benefit.
  2. Open enums are the established pattern in this codebase
     (`Category`, `PassEvent` itself); diverging here would
     be inconsistent.

## Consequences

### Positive

- **8a.5 (D-053) gets a primary correctness signal**:
  `func.pass_diagnostics.entries[hoist].applied` is a direct
  read for the cap-removal verification; "hoist applied >0
  on tinygo_fib" becomes a unit test assertion, not a
  speculative observation.
- **8a.3 (bench-delta) gets per-pass attribution**: the
  `extra` field carries timing-relevant size data
  (`emit.bytes_emitted`, `liveness.range_count`,
  `regalloc.high_water_slot`) so a regression on one pass
  doesn't get attributed to the wrong stage.
- **Trap-time post-mortem extends across passes**: when a
  bug like the 8.4-d still-unidentified UnsupportedOp source
  fires, the trap drain shows the last few `pass_enter` /
  `pass_exit` events — narrowing the search from 17 silent
  return sites to "the failing pass + which func".
- **Zero release-build overhead** per ROADMAP §A12: both
  channels are `comptime` no-ops with
  `-Dtrace-ringbuffer=false`. Verified by the existing
  `trace.zig` test "trace: enabled flag matches build_options".
- **No new build-matrix axis**: reuses ADR-0028's existing
  `-Dtrace-ringbuffer`. The `passes` channel ships when
  `trace_ringbuffer == true`.

### Negative

- **`ZirFunc` grows by `?PassDiagnostics`** — one optional
  pointer (8 bytes when null on 64-bit hosts; the entries
  slice itself is heap-allocated when populated). For the
  realworld 55-func corpus that's 55 × 8 = 440 bytes of
  null-slot overhead per compile; negligible. With slot
  populated (~5 entries × 16 bytes = 80 bytes per func), full
  corpus is ~4.4 KiB. Bounded.
- **Pipeline call sites pay 2× `passEnter`/`passExit` per
  pass** — 5 passes × 2 calls = 10 inline calls per func,
  each comptime-elided when disabled. When enabled: 10 × 1
  ringbuffer write + 5 slot appends = ~15 cache writes per
  func. For the 55-func realworld corpus that's ~825 writes
  per `compileWasm`; negligible.
- **PassSummary.digest()'s u16 saturation is lossy**:
  documented as such; the per-function slot is the source of
  truth when ringbuffer entries are read approximately. A
  reader that needs exact counts goes via the slot.
- **Slot lifetime adds one `deinit` clause to
  `compileOne`'s `deinitFuncResult`** — symmetric to the
  existing `liveness` and `loop_info` clauses; mechanical.

### Neutral / follow-ups

- **8a.1-b**: extend `src/diagnostic/trace.zig` with
  `PassId` enum + `Category.pass = 6` + `passEnter` /
  `passExit` API + 2-3 unit tests asserting ring-buffer
  ordering of pass events.
- **8a.1-c**: add `ZirFunc.pass_diagnostics: ?PassDiagnostics`
  slot + `PassRecord` / `PassDiagnostics` types + slot
  helpers (`appendPassRecord(allocator, func, record)` +
  `deinitPassDiagnostics`). Unit tests assert slot
  population symmetric to the existing `Liveness` slot
  test.
- **8a.1-d**: wire `passEnter` / `passExit` into the 5
  pipeline stages in `compile.zig`. Each pass's `run()` /
  `compute()` either returns a `PassSummary` directly or has
  the wrapper synthesise one from existing return values
  (`hoist.run` → recover `applied` from
  `func.hoisted_constants.len`; `liveness.compute` → recover
  range-table length). 1-line edit per pass site.
- **8a.1-e**: integration unit test asserting the full
  pipeline records 5 enter + 5 exit events for a sample
  function, in pipeline order. Three-host gate.
- **ADR-0028 cross-reference**: when 8a.1-b lands, ADR-0028's
  category table updates note `pass = 6` is occupied (no
  Revision history row needed — extension is non-breaking).
- **`ZWASM_DIAG=passes` plumbing** (8a.4): builds on this
  ADR's `enabled` flag; runtime opt-in surface flips a
  threadlocal `bool` consumed by the `comptime` branches'
  twin runtime check.
- **D-021 / D-022 unaffected**: per-thread storage discipline
  is identical to ADR-0028's; trap-stub call site
  coordination (D-022) covers `trap` category, not `pass`.

## References

- ROADMAP §9.8a / 8a.1 (per-pass diagnostic ringbuffer
  extension), §A12 (no pervasive build-time `if`), §P13
  (analysis-slot day-1 reservation), §11 (zone layering)
- ADR-0028 (Diagnostic M3 trace ringbuffer; this ADR extends
  the `Category` enum with slot 6 and adds a per-function
  observability surface)
- ADR-0031 (ZIR-stage hoist pass; the 8a.5 D-053 cap-removal
  investigation depends on this ADR's `applied`/`skipped`
  counters)
- ADR-0032 (Phase 8 foundation-first reorg; this ADR is the
  first §9.8a foundation row)
- `.claude/rules/single_slot_dual_meaning.md` — `extra` field
  on `PassRecord` is documented per call site to avoid the
  single-slot-dual-meaning anti-pattern
- `.claude/rules/spec_citation.md` — `passEnter`/`passExit` are
  diagnostic infrastructure, not spec-semantic handlers; no
  Wasm spec citation required
- `src/diagnostic/trace.zig` (existing M3-a-1 ringbuffer)
- `src/ir/zir.zig:559` (`ZirFunc` struct + analysis-slot
  pattern)
- `src/engine/codegen/shared/compile.zig:97` (pipeline stage
  ordering — wrap targets for 8a.1-d)
- D-053 (hoist cap-removal investigation; primary consumer of
  `func.pass_diagnostics.entries[hoist].applied`)

## Revision history

| Date | SHA | Note |
|---|---|---|
| 2026-05-09 | `93da3902` | Initial accepted version (§9.8a / 8a.1-a design framing) |
