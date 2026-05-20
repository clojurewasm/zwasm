# 0079 — Split `src/engine/runner.zig` along driver / compile / setup boundary

- **Status**: Proposed
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (close-plan §6 (g))
- **Tags**: file-layout, refactor, zone-2, file-size-cap

## Context

`src/engine/runner.zig` is 1995 lines — within 5 lines of the
hard cap (2000 per ROADMAP §A2). The file accumulates three
structurally distinct responsibilities that historically grew
together because the second / third were extracted as
helpers from the first:

1. **Top-level driver** — `runI32Export` / `runVoidExport` /
   `findExportFunc` / `Error` set (~ 200 LOC at file head and
   ~ 80 LOC at `runI32Export`).
2. **Compile pipeline** — `compileWasm` + the 800-line
   helper chain it spawned (defined-globals init, funcref-
   global resolution, table init, data-segment init,
   table-import patching, table-declaration scanning).
3. **Runtime instance setup** — `setupRuntime` (the 450-LOC
   "fold all the above into a JitRuntime" function) +
   `hostDispatchTrap` (the cross-module dispatch trap).

The growth pattern is the close-plan C1 anti-pattern made
concrete: each substantive refactor finds a new helper that
"only belongs here because runner.zig already owns its caller",
hits the file-size cap, and gets quietly extracted to an
unrelated layer (`engine/export_lookup.zig` etc.) — naming
drifts from purpose.

D-141 has been `blocked-by: substrate audit Q3 architecture
decision` since 2026-05-17 because the per-op-module vs
comptime-switch decision was assumed to determine the file
shape. That assumption is now wrong: substrate audit Q3 lands
in §9.12 (B1–B158 already implemented per-op-modules per
ADR-0074), and the runner.zig split is **orthogonal** to it —
the split target is the engine-side driver, not the codegen
inner loop the Q3 decision shaped.

Close-plan §6 (g) instructs this ADR to **unblock D-141** by
proposing a concrete split. Implementation is deferred to a
follow-up cycle (this ADR is `Proposed` only).

## Decision

Split `src/engine/runner.zig` into **three files** at the
existing structural boundary:

| New file                          | Contents                                                                              | Approx LOC |
|-----------------------------------|---------------------------------------------------------------------------------------|------------|
| `src/engine/runner.zig`           | Top-level driver: `Error`, `CompiledWasm`, `findExportFunc`, `runI32Export`, `runVoidExport`. | ~ 380       |
| `src/engine/compile.zig`          | `compileWasm` + per-section helpers (`applyDefinedGlobalsInit`, `resolveFuncrefGlobals`, `applyTableInit`, `applyTableInitForTable`, `patchTableImportFuncptrs`, `countDeclaredTables`, `declaredTableMin`, `declaredTableMax`, `applyActiveDataSegments`). | ~ 900       |
| `src/engine/setup.zig`            | `setupRuntime` (the JitRuntime-assembly function) + `hostDispatchTrap` (cross-module dispatch trap helper).   | ~ 700       |

Each file gets a single `Zone 2` declaration at the top
(matching the existing `runner.zig` comment style). Public
re-exports stay in `runner.zig` so external callers
(`src/cli/run.zig`, `c_api/instance.zig`, spec runners) need
no import changes:

```zig
// src/engine/runner.zig
pub const compileWasm = @import("compile.zig").compileWasm;
pub const applyDefinedGlobalsInit = @import("compile.zig").applyDefinedGlobalsInit;
// ... etc for every existing `pub` in the compile chain.
pub const setupRuntime = @import("setup.zig").setupRuntime;
```

The re-exports give callers zero-churn discovery — `git
grep "runner.compileWasm"` keeps working — while the
implementation lives where its purpose names it.

### Why three files (not two, not five)

- **Two files** (driver + everything-else) leaves
  `engine/runner.zig` at ~ 1600 LOC — still over the soft
  cap, still a magnet for the close-plan C1 drift.
- **Five files** (driver + compile-helpers + globals-init +
  table-init + data-init) shatters the compile pipeline
  across files whose contents are interleaved in execution
  order; readers must hop. The 900-LOC compile.zig is
  cohesive — every function consumes the prior section's
  output.
- **Three files** matches the actual three roles. Each
  resulting file sits comfortably under the 1000-LOC soft
  cap (driver ~ 380, compile ~ 900, setup ~ 700).

### Implementation order (follow-up cycle, NOT in this ADR)

1. Carve `setup.zig` first (the leaf — only `runner.zig` calls
   `setupRuntime`; lowest blast radius).
2. Carve `compile.zig` second (touches more sites; verify
   re-exports preserve every existing import).
3. `runner.zig` shrinks to ~ 380 LOC by subtraction.

Each step is a separate chunk with a green test gate. No spike
is required (the re-export pattern is mechanical), so this is
an `infrastructure`-typed chunk family per
[`LOOP.md` §"Chunk types"](../../.claude/skills/continue/LOOP.md).

## Alternatives considered

### Alternative A — Wait for substrate audit Q3

- **Sketch**: Keep D-141 `blocked-by: substrate audit Q3`;
  defer the split until the per-op-module decision lands.
- **Why rejected**: Substrate audit Q3 was already resolved in
  §9.12-B (ADR-0074) — the per-op-module shape landed. The
  block was structural confusion: Q3 shaped the **codegen**
  inner loop, not the **engine** driver. Waiting longer is
  loss-only.

### Alternative B — Split by execution phase (parse / compile / link / setup)

- **Sketch**: `parse.zig` (sections walking), `compile.zig`
  (per-function compile), `link.zig` (JitModule assembly),
  `setup.zig` (runtime init).
- **Why rejected**: `parse/` and `engine/codegen/shared/linker.zig`
  already own those phases. The engine-side driver wraps them;
  it doesn't replicate them. The proposed three-file split
  matches the wrapper structure, not the wrapped one.

### Alternative C — Comment-based section markers, no file split

- **Sketch**: Add `// ============= COMPILE PIPELINE
  =============` markers, raise the soft cap to 2500 to
  accommodate, leave the file monolithic.
- **Why rejected**: The close-plan B1 entry calls this out as
  the "永久に短期最小コスト負け" pattern — comment markers
  defer the split forever and the file keeps drifting. The
  cap raise normalises the drift.

## Consequences

- **Positive**:
  - D-141 unblocks (the substrate-audit-Q3 barrier dissolves
    by ADR-0074 having already landed; this ADR's existence
    + acceptance is the formal hand-off).
  - `runner.zig` returns to under the soft cap (380 ≪ 1000).
  - File names match contents (`compile.zig` for compile
    helpers, `setup.zig` for runtime init). Close-plan C1
    "engine/export_lookup.zig is the misnamed dumping
    ground" drift loses its pressure source.
  - File-size soft-cap WARN list drops by 1 entry; pattern
    closes the precedent for similar splits (validator.zig,
    lower.zig, liveness.zig — all 1000+ LOC) once their
    Q3-equivalent barriers dissolve.
- **Negative**:
  - Three-file Zone-2 surface area is one file more to
    maintain. Mitigated by re-exports — the external API
    stays single-file.
  - A future reader must `grep` for symbols across three files
    instead of one. Mitigated by re-export discoverability +
    `compile.zig` / `setup.zig` names matching their content.
- **Neutral / follow-ups**:
  - Implementation chunks land per the order above (3
    `infrastructure`-typed chunks); each chunk's test gate
    is `cohort` (test-all) because the touched surface
    crosses module boundaries.
  - D-141's row body retires (close-plan §6 (g) checkpoint).

## References

- Close-plan §6 (g) — `.dev/phase9_structural_debt_close_plan.md`
- D-141 — `.dev/debt.md` (current `blocked-by:` row to be
  retargeted at this ADR).
- ADR-0023 — `src/` directory structure normalisation
  (Zone vocabulary).
- ADR-0074 — per-op-file Zone split (lands the substrate-
  audit-Q3 decision the prior D-141 block waited on).
- ROADMAP §A2 — file size soft (1000) / hard (2000) caps.
- Source: `src/engine/runner.zig` (1995 LOC, current shape).

<!--
## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-21 | `7faf9da4` | Initial Proposed version.               |
-->
