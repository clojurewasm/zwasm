# 0013 — Runtime-asserting WAST runner detailed design

- **Status**: Accepted
- **Date**: 2026-05-03
- **Author**: continue loop
- **Tags**: phase-6, test-runner, runtime-assertion, per-instr-trace,
  prerequisite-for-6.A

## Context

ADR-0012 §6.A authorises adding `test/runners/wast_runtime_runner.zig`
as the runtime-asserting WAST runner. This ADR fixes its detailed
design: file location, capability scope, manifest format, runtime
API surface it consumes, per-instr trace API it exposes, and the
re-derivation discipline applied to v1's `e2e_runner.zig` (844 LOC
textbook reference).

v1 audit findings (Step 0 Survey):
- v1's `e2e_runner.zig` consumes wast2json JSON output
  (`commands[]` array). v2's policy (ADR-0012 §1) is generated
  artifacts not committed; v2 keeps wast2json invocation behind
  `scripts/regen_test_data*.sh` and the runner consumes a flat
  text manifest (continuation of the existing `wast_runner.zig`
  pattern).
- v1 returns `anyerror!void` from invokes — too wide; v2 has a
  typed `interp.Trap` (12 specific conditions, listed in §3.2).
- v1 has no per-instr trace; v2 needs it for ADR-0012 §6.E.
- v1 reuses one VmImpl with `reset()` between invokes; v2 spins
  up a fresh `interp.Runtime` per top-level command per ROADMAP
  §P3 (no global state).

## Decision

### 1. File location and Zone

- File: `test/runners/wast_runtime_runner.zig` (per ADR-0012 §3
  layout — `test/runners/` is the cross-origin runner directory).
- Zone: **test code, not src code**. Imports allowed: `std`,
  `zwasm` module (Zone 1 `parser` / `sections` / `validator` /
  `lowerer` / `zir`, Zone 2 `interp`, **Zone 3 `cli_run` /
  `c_api`** for the higher-level instantiate / invoke pipeline
  matching the existing `test/realworld/run_runner.zig` pattern).
  Zone discipline (`scripts/zone_check.sh`) does not apply to
  `test/` per `.claude/rules/zone_deps.md` "Tests are exempt".
- Build wiring: registered as the `test-wasmtime-misc` step
  executable in `build.zig` (the step itself is created by
  ADR-0012 §6.D; the runner binary lands at §6.A).

### 2. Manifest format (extension of existing `wast_runner.zig` format)

Continue the flat-text manifest pattern from `wast_runner.zig`.
Each line is a directive. Existing 3 directives kept; new 6
runtime directives added:

```
# Existing (kept verbatim)
malformed <wasm-file>
valid     <wasm-file>
invalid   <wasm-file>

# New (runtime-asserting)
module        <name>?  <wasm-file>
register      <as-name> <module-name>?
invoke        <module-name>? <export> <arg-encoding>...
assert_return <module-name>? <export> <arg-encoding>... -> <expected-encoding>...
assert_trap   <module-name>? <export> <arg-encoding>... !! <trap-kind>
assert_exhaustion <module-name>? <export> <arg-encoding>... !! <trap-kind>
```

`<arg-encoding>` and `<expected-encoding>` follow a per-line
TLV-style notation:
- `i32:42`, `i64:-1`, `f32:nan:canonical`, `f32:nan:arithmetic`,
  `f32:0x7fc00000`, `f64:1.5`, `ref.null:func`, `ref.null:extern`,
  `ref.func:0`
- Multiple values space-separated.

`<trap-kind>` matches the v2 `interp.Trap` enum tags exactly
(`Unreachable`, `DivByZero`, etc., listed in §3.2). For
`assert_exhaustion`, the canonical kinds are `StackOverflow` /
`CallStackExhausted`.

The manifest is generated from wast2json output by an extended
`scripts/regen_test_data.sh` (the regeneration is §6.C work, not
6.A; 6.A only consumes whatever `manifest.txt` shape exists,
including the existing 3-directive form).

### 3. Runtime API consumption

#### 3.1 Pipeline per `module` directive

```
parser.parse(gpa, wasm_bytes)                    → parser.Module
sections.decodeTypes / Functions / Codes / ...   → typed section data
validator.validateFunction(...)                  → spec compliance check
lowerer.lowerFunction(...)                       → zir.ZirFunc per function
runtime_setup(gpa, module, lowered_funcs)        → Runtime{ funcs, memory, globals, ... }
```

`runtime_setup` is a runner-internal helper (not exported back to
src) that wires the module-level state into a `Runtime`. It
absorbs the section-decode + import-resolve plumbing currently
duplicated between `wast_runner.zig` and `realworld/run_runner.zig`.

#### 3.2 Trap surface

The runner relies on the typed `interp.Trap` error set
(`src/interp/mod.zig` line 73):

```
Trap = error{
    Unreachable, DivByZero, IntOverflow, InvalidConversionToInt,
    OutOfBoundsLoad, OutOfBoundsStore, OutOfBoundsTableAccess,
    UninitializedElement, IndirectCallTypeMismatch,
    StackOverflow, CallStackExhausted, OutOfMemory,
}
```

`assert_trap`'s `<trap-kind>` matches the error tag name
verbatim. `OutOfMemory` is NOT a permitted assertion target
(allocator failures bubble up as runner errors, not test
expectations).

#### 3.3 Invoke flow

For each `invoke` / `assert_return` / `assert_trap`:
1. Look up the module by name (or "current" if name omitted).
2. Look up the export by name in the module's export table.
3. Push args onto `Runtime.operand_buf` per arg-encoding.
4. Call `interp.dispatch.run(rt, func)` (or equivalent entry).
5. Catch `Trap!` error union or read returned `Runtime.operand_buf`
   slice depending on directive.

### 4. Cross-module Store sharing

Re-derived from v1's `named_modules` + `registered` model, but
expressed as a single `RunnerContext` struct (no global state):

```zig
const RunnerContext = struct {
    arena: std.heap.ArenaAllocator,
    modules_by_name: std.StringHashMap(*Module),
    registered: std.StringHashMap(*Module),
    current: ?*Module,
    // ...
};
```

- `module <name>?` adds to `modules_by_name` (or replaces
  `current` when name omitted).
- `register <as-name> <module-name>?` resolves `<module-name>`
  in `modules_by_name`, then adds it to `registered` under
  `<as-name>`.
- Cross-module `(import "<as-name>" "<export>" ...)` resolves
  via `registered.get(as-name)`.

Per ROADMAP §P3, the `RunnerContext` is per-test-file scope; a
fresh context is built for each manifest, then arena-freed at the
end of that manifest. No state leaks across test files.

### 5. Per-instruction trace API (the new capability)

The trace is the design-input new feature. It serves ADR-0012
§6.E (interp behaviour bug pinpointing).

API shape — **callback injection on `Runtime`**:

```zig
// in src/interp/mod.zig (added in 6.A):
pub const TraceEvent = struct {
    pc: u32,
    op: zir.ZirOp,
    operand_top: ?Value,  // top of operand stack post-op (null if none)
    frame_depth: u32,
};

pub const TraceCallback = *const fn (ctx: *anyopaque, ev: TraceEvent) void;

pub const Runtime = struct {
    // ... existing fields ...
    trace_cb: ?TraceCallback = null,
    trace_ctx: ?*anyopaque = null,
};
```

Dispatch loop adds one branch:

```zig
// in src/interp/dispatch.zig run loop, post-handler call:
if (rt.trace_cb) |cb| {
    cb(rt.trace_ctx.?, .{
        .pc = saved_pc,
        .op = op,
        .operand_top = if (rt.operand_len > 0) rt.operand_buf[rt.operand_len - 1] else null,
        .frame_depth = rt.frame_len,
    });
}
```

When `trace_cb == null`, the runtime cost is one branch (predicted
not-taken). This satisfies ROADMAP §P3 (no per-instruction cost
when feature unused) and §A12 (no pervasive build-time `if`).

The runner uses this to implement an optional trace mode
controlled by `--trace <fixture>` CLI flag:

```sh
./zig-out/bin/wast_runtime_runner test/wasmtime_misc/wast/embenchen --trace fannkuch
```

When set, prints one line per executed instruction to stdout.
Used by 6.E investigators to compare v2 trace against wasmtime
trace fixture-by-fixture.

### 6. Capability scope (from ADR-0012 §6.A row, repeated for self-completeness)

In:
- assert_return, assert_trap, assert_invalid, assert_malformed,
  assert_unlinkable, assert_uninstantiable, assert_exhaustion
- register, action, module
- cross-module Store sharing
- per-instr execution trace

Out (deferred to relevant feature phases):
- thread block (Phase 9+)
- assert_return_canonical_nan / assert_return_arithmetic_nan
  (delivered per current `Value` storage; the wast format already
  accommodates `nan:canonical` / `nan:arithmetic` in
  `<expected-encoding>` per §2)

### 7. v1 patterns explicitly rejected

Per `.claude/rules/no_copy_from_v1.md` and ROADMAP §14:

| v1 pattern | Reason rejected | v2 substitute |
|---|---|---|
| Single global `VmImpl` reused via `reset()` | ROADMAP §P3 (no global state) | Per-`Runtime` instance per test-file |
| `anyerror!void` invoke return | ROADMAP §P1 (typed errors) | `interp.Trap!void` |
| `usingnamespace` re-exports | Zig 0.16 compile error | Explicit `pub const` re-exports |
| `std.io.AnyWriter` writer params | Removed in Zig 0.16 | `*std.Io.Writer` |
| Per-module alloc + free of intermediates | ROADMAP §P3 cold-start | `ArenaAllocator` per test file, batch free |
| 128-slot fixed result buffer | Implicit limit, not bound to spec | Match `interp.max_operand_stack` (4096) |
| JSON command-array parsing in Zig | wast2json schema is wide + shifting | Flat text manifest (continuation of v2 `wast_runner.zig` policy) |

### 8. Module structure of `test/runners/wast_runtime_runner.zig`

Top-level shape:

```zig
//! Runtime-asserting WAST runner (Phase 6 / §9.6 / 6.A per ADR-0013).

const std = @import("std");
const zwasm = @import("zwasm");

pub fn main(init: std.process.Init) !void { ... }

const RunnerContext = struct { ... };
const Module = struct { ... };  // runner-internal, wraps zir.ZirFunc[]

fn runManifest(ctx: *RunnerContext, manifest_text: []const u8) !void { ... }
fn handleModule(ctx, args) !void { ... }
fn handleRegister(ctx, args) !void { ... }
fn handleAssertReturn(ctx, args) !void { ... }
fn handleAssertTrap(ctx, args) !void { ... }
fn handleAssertInvalid(ctx, args) !void { ... }
fn handleAssertMalformed(ctx, args) !void { ... }
fn handleAssertUnlinkable(ctx, args) !void { ... }
fn handleAssertUninstantiable(ctx, args) !void { ... }
fn handleAssertExhaustion(ctx, args) !void { ... }
fn handleAction(ctx, args) !void { ... }
fn handleInvoke(ctx, args) !void { ... }
fn handleValidMalformedInvalid(...) !void { ... }  // existing 3 directives

// Argument parsing
fn parseValue(text: []const u8) !zwasm.interp.Value { ... }
fn matchExpected(actual: []const Value, expected_text: []const u8) bool { ... }

// Trace
const TraceState = struct { writer: *std.Io.Writer, fixture: []const u8 };
fn traceCallback(ctx_ptr: *anyopaque, ev: zwasm.interp.TraceEvent) void { ... }
```

Soft cap target: **≤ 800 LOC** (v1 textbook is 844 LOC; v2's
typed errors + arena discipline + by-file dispatch are expected
to come in slightly under). Hard cap: 1000 LOC per `scripts/file_size_check.sh`.

### 9. Sub-step sequence in 6.A implementation

1. Extend `src/interp/mod.zig` with `TraceEvent` + `TraceCallback`
   types + `Runtime.trace_cb` / `trace_ctx` fields.
2. Extend `src/interp/dispatch.zig` `run` loop with the
   `if (rt.trace_cb)` branch (single conditional, post-handler).
3. Add `test/runners/wast_runtime_runner.zig` skeleton (main +
   RunnerContext + manifest parsing + 3 existing directive
   handlers).
4. Add new directive handlers one at a time, each with a tiny
   in-tree fixture in `test/runners/fixtures/<directive>/`
   exercising it.
5. Wire `test-runtime-runner-smoke` step into `build.zig`
   pointing at `test/runners/fixtures/`. The full
   `test-wasmtime-misc` step lands in 6.D.
6. Three-host `zig build test-runtime-runner-smoke` + `test-all`
   green.
7. Commit (`feat(p6): land §9.6 / 6.A — runtime-asserting WAST
   runner`).
8. Step 7 of the per-task TDD loop (handover update + push +
   re-arm).

## Alternatives considered

- **JSON-driven runner (consume wast2json output directly)**:
  rejected — same reason as v2's existing `wast_runner.zig` (JSON
  parsing in Zig is overhead; wast2json schema shifts; flat text
  is auditable).
- **Trace via ring buffer + file dump**: rejected — adds
  allocation, complicates teardown; callback injection is
  zero-cost when disabled and lets the consumer (runner) own
  format choices.
- **Single `Runtime` reused with `reset()` (v1 model)**:
  rejected per ROADMAP §P3 — fresh `Runtime.init` per top-level
  invoke is the v2 invariant.
- **Per-handler error sets (one error set per assert_*)**:
  rejected — `interp.Trap` is the project-wide trap surface;
  the runner translates to test pass/fail outside the typed
  error path.

## Consequences

### Positive
- ADR-0012 §6.A blocking prerequisite cleared.
- Per-instr trace API lands in `src/interp/` once and powers all
  future trace-based investigation (6.E, future JIT diff, future
  fuzz reduction).
- Manifest format extension stays in the `wast_runner.zig`
  flat-text family; readers don't context-switch between flat
  text and JSON.

### Negative
- `src/interp/mod.zig` and `src/interp/dispatch.zig` gain ~30
  LOC for trace plumbing. ROADMAP §P3 budget acceptable
  (predicted-not-taken branch).
- `test/runners/wast_runtime_runner.zig` is the largest file in
  `test/`; need to watch the ≤ 1000 LOC hard cap as directives
  accumulate.

### Neutral / follow-ups
- Manifest generator extension is **6.C work** (not 6.A);
  `scripts/regen_test_data.sh` learns to emit the new directive
  forms when 6.C vendors wasmtime_misc BATCH1-3.
- The `--trace` CLI flag is consumed by 6.E investigators
  manually; no automation around trace-comparison-with-wasmtime
  in this ADR (would be Phase 7+ if needed).
- `test/runners/fixtures/` layout is private to the runner;
  contributors who add new directive handlers add their own
  smoke fixtures here.

## References

- ROADMAP §9.6 / 6.A (the work item this ADR designs)
- ROADMAP §P1 (typed errors), §P3 (cold-start), §P10 (no copy
  from v1), §P13 (type up-front), §A2 (file size cap), §A12 (no
  pervasive build-time if)
- ADR-0012 (test/bench redesign — §6.A row + §3 layout)
- ADR-0011 (Phase 6 reopen — the parent context)
- ADR-0008 (Phase 6 charter)
- `src/interp/mod.zig` (line 35-86 — Value + Trap, line 172-230 —
  Runtime API)
- `src/interp/dispatch.zig` (line 36 step / line 57 run — entry
  points the runner consumes)
- `test/spec/wast_runner.zig` (the existing flat-text manifest
  runner this one extends)
- v1 `test/e2e/e2e_runner.zig` (844 LOC textbook reference;
  read, never copy)
- `.claude/rules/no_copy_from_v1.md`
- `.claude/rules/textbook_survey.md`
- `.claude/rules/zone_deps.md`

**Amendment history**:
- 2026-05-03 (during 6.A implementation, commit `af411f0`): §1
  Zone constraint relaxed to allow Zone 3 imports for test
  runners, aligning with the existing `test/realworld/run_runner.zig`
  precedent (`zwasm.cli_run` import) and `.claude/rules/zone_deps.md`'s
  "Tests are exempt" clause. The original strict "MUST NOT
  import Zone 3" was over-restrictive design-time prudence;
  the amended text matches reality. No supersession ADR filed
  because the change does not alter the design's load-bearing
  decisions (capability scope, manifest format, trace API
  shape) — only the import-policy phrasing.
