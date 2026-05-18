# 0073 — All-layer consistent DCE substrate via build-option

- **Status**: Proposed
- **Date**: 2026-05-19
- **Author**: continue loop §9.12 substrate audit cycle (reflecting 2026-05-19 user feedback)
- **Tags**: phase-9, substrate, build-option, dce, feature-flag, all-layer-consistent

## Context

User feedback 2026-05-19 (Q3 adoption policy):

> The design intent: when filtered out by build-option (`-Dwasm` / `-Dwasi` / `-Denable`),
> the code for that feature is **literally "absent"** = the command-line argument does not exist
> = it is functionally unavailable. Branching is likely to spread because this was not
> originally a consideration, but it is worth proceeding incrementally + via spike.

Current facts (measured 2026-05-19):

- `build.zig` declares `-Dwasm=v1_0|v2_0|v3_0` (default v3_0), `-Dwasi=p1|p2` (default
  p1), `-Dengine=interp|jit|both`, etc.
- However, `build_options.wasm_level` is only consulted at 2 diagnostic sites in
  `cli/main.zig` + `diagnostic/trace.zig`. None of validator / lower / emit / runtime /
  c_api / CLI / WASI applies a build-option feature gate (binaries always include all
  levels).
- `src/instruction/wasm_X_Y/<op>.zig` placeholder structure already exists (3514 LOC
  of Wasm 1.0 + 2.0 op bodies populated), but the build-option DCE pattern is not
  established.
- Mechanical feasibility of the substrate has been verified by spike
  `q3-build-option-dce-poc` (see "Spike results" below).

## Decision

**Establish build-option-driven DCE in a single uniform pattern across all 4 layers
(ZirOp/codegen/interp, CLI, c_api, WASI)**. The substrate is identical at the
abstraction level (declarative metadata + comptime filter); layer-specific
adaptations cover surface mechanics (CLI arg parser table, c_api `@export`,
WASI syscall dispatch).

### Common pattern across all layers

Every declarative element (op file / CLI arg row / c_api export row / WASI syscall
row) exports a **canonical metadata aggregate**:

```zig
pub const wasm_level: ?WasmLevel = ...;   // null = enabled in all builds
pub const wasi_level: ?WasiLevel = ...;   // null = enabled regardless of WASI build
pub const enable_features: []const Feature = &.{};  // future-use feature gates
```

Central collector (1 file per layer) consumes these via `inline for` + comptime
filter:

```zig
inline for (registered_elements) |e| {
    if (comptime e.wasm_level) |lvl| {
        if (comptime @intFromEnum(lvl) > @intFromEnum(build_options.wasm_level))
            continue;  // comptime continue → no instantiation → no symbol emitted
    }
    if (comptime e.wasi_level) |lvl| {
        if (comptime @intFromEnum(lvl) > @intFromEnum(build_options.wasi_level))
            continue;
    }
    // ... register / dispatch / export the element
}
```

In a `-Dwasm=v1_0` build, handlers / CLI args / c_api exports / WASI syscalls for
Wasm 2.0+ are **not reached at comptime → absent from the binary**. The spike
result (below) confirms this with `nm` + `xxd` evidence.

### Layer-by-layer specifics

#### Layer 1 — ZirOp + validator + lower + JIT + interp

`src/instruction/wasm_X_Y/<op>.zig` exports:

```zig
pub const op_tag: ZirOp = .v128_load;
pub const wasm_level: WasmLevel = .v2_0;
pub const handlers = .{
    .validate = validate_v128_load,
    .lower    = lower_v128_load,
    .arm64    = emit_arm64_v128_load,
    .x86_64   = emit_x86_64_v128_load,
    .interp   = interp_v128_load,
};
```

`src/ir/dispatch_collector.zig` (new) imports every op file at comptime, validates
completeness invariants, and constructs the central dispatcher per axis using
`inline switch (op) { inline else => |tag| ... }`. The 5 existing dispatcher
sites (`validator.zig`, `lower.zig`, `engine/codegen/arm64/emit.zig`,
`engine/codegen/x86_64/emit.zig`, `engine/interp/dispatch.zig`) each shrink to
a thin call to `dispatch_collector.dispatcher(.<axis>)`.

#### Layer 2 — CLI (`src/cli/`)

CLI arguments are declared in a single declarative table:

```zig
// src/cli/args.zig
pub const args = .{
    .{ .name = "--wasm-level",  .wasm_level = null,  .wasi_level = null, .handler = handle_wasm_level },
    .{ .name = "--wasi-dir",    .wasm_level = null,  .wasi_level = .p1,  .handler = handle_wasi_dir },
    .{ .name = "--enable-gc",   .wasm_level = .v3_0, .wasi_level = null, .handler = handle_gc_flag },
};

pub fn parseArgs(argv: [][:0]const u8) !void {
    inline for (args) |arg| {
        if (comptime arg.wasm_level) |lvl| {
            if (comptime @intFromEnum(lvl) > @intFromEnum(build_options.wasm_level))
                continue;
        }
        // ... arg participates in the parser dispatch
    }
}
```

In a `-Dwasm=v1_0` build, `--enable-gc` is **absent from the parser's match
table** → `zwasm run --enable-gc foo.wasm` → "unknown argument: --enable-gc".
It also does not appear in `zwasm --help`.

#### Layer 3 — C API (`src/api/wasm.zig` + `include/wasm.h`)

C API exports are declared in a single declarative table:

```zig
pub const exports = .{
    .{ .name = "wasm_module_new",    .wasm_level = null,  .impl = wasm_module_new },
    .{ .name = "wasm_v128_extract",  .wasm_level = .v2_0, .impl = wasm_v128_extract },
    .{ .name = "wasm_gc_struct_new", .wasm_level = .v3_0, .impl = wasm_gc_struct_new },
};

comptime {
    for (exports) |e| {
        if (e.wasm_level) |lvl| {
            if (@intFromEnum(lvl) > @intFromEnum(build_options.wasm_level)) continue;
        }
        @export(e.impl, .{ .name = e.name, .linkage = .strong });
    }
}
```

In a `-Dwasm=v1_0` build, the `wasm_v128_extract` symbol does not exist in the
binary (verified via `nm`). On the `include/wasm.h` side, a `build.zig`
`addConfigHeader` step generates preprocessor gates: `#if ZWASM_WASM_LEVEL >= 2`
wraps the corresponding declarations. C consumers building against zwasm
control feature surface via the `ZWASM_WASM_LEVEL` macro.

#### Layer 4 — WASI (`src/wasi/`)

WASI syscalls follow the same pattern with `wasi_level` metadata:

```zig
// src/wasi/preview1/syscalls.zig
pub const syscalls = .{
    .{ .name = "fd_write",  .wasi_level = .p1, .impl = wasi_p1_fd_write },
    .{ .name = "fd_close",  .wasi_level = .p1, .impl = wasi_p1_fd_close },
};
```

The WASI dispatch table is built at comptime from this table, filtered by
`build_options.wasi_level`. Disabled syscalls do not appear in the dispatch
table → guest calls to them return `errno.NoSys` at runtime (Wasm-spec-conformant
behaviour).

### Enforcement (aligned with ADR-0071 + master plan Chapter 7)

- **`scripts/check_build_dce.sh`** — verifies symbol table grep + binary size
  across the 6 build-option combinations (`-Dwasm={v1_0,v2_0,v3_0}` ×
  `-Dwasi={p1,p2}`). Fails if a Wasm 2.0+ symbol appears in a `-Dwasm=v1_0`
  build. Lands in §9.12-A as part of the pre-commit + pre-push gate.
- **`audit_scaffolding §K.1`** (new section — Phase 9 completion enforcement)
  flags signs that DCE has broken (e.g. new `std.c.*` site without metadata,
  new `@export` outside the declarative table).
- **`test/build_completeness/`** — E2E test directory verifying in each build
  that the disabled-axis features are absent (size delta, symbol absence,
  CLI rejection of disabled args).

### Two-stage control: build-option + runtime option

The build-option DCE is the **outer gate** (literal absence). A **runtime
option** (`--wasm-level=2.0` on a `-Dwasm=v3_0` build) is the **inner gate**
(refusing to instantiate modules that exceed the runtime-selected level even
when the binary supports them). This two-stage shape is intentional:

- Distribution binary: `-Dwasm=v3_0` (full feature support compiled in).
- Restricted runtime: `--wasm-level=2.0` rejects Wasm 3.0 modules at
  instantiate-time. The Wasm 3.0 code is still in the binary (size cost) but
  is unreachable from the user's runtime scope.
- Minimal binary: `-Dwasm=v1_0` (Wasm 2.0+ literally absent from binary).
  Smallest size; smallest attack surface; no `--wasm-level` knob exposed.

This pattern means a downstream consumer of zwasm chooses size-vs-flexibility
at build time, then audits runtime scope at deploy time.

## Spike results (2026-05-19)

Three spikes were run as `private/spikes/q3-*/` under §9.12-pre. Summaries:

### Spike `q3-build-option-dce-poc` — DCE substrate end-to-end

- **Result**: substrate works literally as designed.
- 5 representative per-axis op files (Wasm 1.0 / 2.0 / 3.0 + WASI p1 / p2).
- `dispatch_collector.zig` filter via `inline for` + comptime `continue`.
- 6-build matrix (`-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2}`) under Debug:

  | wasm | wasi | bytes | text | #handlers | i32_add | v128_load | struct_new | p1_fd_write | p2_http_send |
  |------|------|-------|------|-----------|---------|-----------|------------|-------------|--------------|
  | v1_0 | p1 | 2046568 | 1528252 | 2 | ✓ | ✗ | ✗ | ✓ | ✗ |
  | v1_0 | p2 | 2046840 | 1528772 | 3 | ✓ | ✗ | ✗ | ✓ | ✓ |
  | v2_0 | p1 | 2046904 | 1528740 | 3 | ✓ | ✓ | ✗ | ✓ | ✗ |
  | v2_0 | p2 | 2047176 | 1529292 | 4 | ✓ | ✓ | ✗ | ✓ | ✓ |
  | v3_0 | p1 | 2047224 | 1529268 | 4 | ✓ | ✓ | ✓ | ✓ | ✗ |
  | v3_0 | p2 | 2047496 | 1529788 | 5 | ✓ | ✓ | ✓ | ✓ | ✓ |

- Every disabled handler absent from `nm`. Magic-byte probe (`xxd | grep`)
  confirms the unique constants (`0x9E3779B97F4A7C15`, `0xDEADBEEFCAFEBABE`)
  are not in the binary at all when the corresponding axis is disabled.
- Metadata `wasm_level` / `wasi_level` symbols remain (~2 B / op) for the
  comptime filter to inspect. Harmless overhead.
- ReleaseSmall / ReleaseSafe inline everything to `main` (toy spike's
  dispatch is comptime-known); Debug is the load-bearing evidence axis.
- **Recommendation**: merge-into-prod; no substrate change required.

### Spike `q3-zig-inline-switch` — 581-tag compile-time wall

- **Result**: no wall hit at 581 tags. Zig 0.16 compiles `inline switch
  (op) { inline else => |tag| body(tag) }` over 581 enum tags in ~9.4 s
  wall-clock (ReleaseSafe) without requiring `@setEvalBranchQuota`.

- Build wall-clock (ReleaseSafe, MaxRSS):

  | N tags | inline | quota | wall (s) | MaxRSS (MB) | .TEXT (B) |
  |-------:|--------|------:|---------:|------------:|----------:|
  | 100 | true | default | 8.59 | 339 | 313712 |
  | 300 | true | default | 9.28 | 339 | 315808 |
  | 581 | true | default | 9.39 | 341 | 318608 |
  | 581 | true | 100k | 9.39 | 347 | 318608 |
  | 581 | false (plain switch baseline) | default | 8.95 | 336 | 312576 |

- `.TEXT` overhead for `inline switch` vs plain switch at N=581: +6032 B
  (+1.9 %). Trivial.
- Debug builds slightly smaller wall (~4.8 s) and identical scaling.
- `@setEvalBranchQuota(100_000)` produces identical results to default →
  default quota is sufficient.
- **Recommendation**: merge-into-prod; no tag-range split required for
  Wasm 1.0 + 2.0 (full ZirOp covering current 581 tags). The Cranelift
  `isle-split-match` workaround stays unused for now; if Phase 10's Wasm
  3.0 + GC slot expansion grows ZirOp beyond ~1000 tags and the wall
  becomes measurable, re-spike at that boundary.

### Spike `q3-interp-dispatch-bench` — dispatch shape cycle cost

- **Result**: at production N (= 581 ZirOp count) **the three dispatch
  shapes tie within ±1.5 %**. Hypothesis C is **not** justified on perf
  grounds; the bench is a perf-null result.
- ReleaseFast, Apple M4 Pro, 10M op stream, 5-trial median:

  | N (op count) | indirect (ns/op) | tail (ns/op) | inline-switch (ns/op) | inline-sw vs indirect |
  |-------------:|-----------------:|-------------:|----------------------:|----------------------:|
  | 50 | 6.89 | 7.31 | **0.91** | **0.13×** (7.6× faster) |
  | 128 | 27.8 | 29.1 | 27.6 | 0.99× |
  | 256 | 126.7 | 124.8 | 125.0 | 0.99× |
  | 581 (full ZirOp) | 358 | 361 | 360 | 1.01× |

- The `inline switch` win at small N is concentrated where the jump table
  fits in icache + BTB and per-op work is tiny; that condition does not
  hold at zwasm v2's production scale.
- Caveats: ubuntunote x86_64 re-run is recommended before finalising
  (different branch predictor + icache shape); real handlers carry
  push/pop + spec-trap paths that further dilute dispatch differences;
  this is `ReleaseFast` only.
- **Adoption decision (substrate-shape-axes only)**: Hypothesis C is
  adopted because the design-quality axes (1 op = 1 file; cross-layer
  consistency; build-option DCE) decide it. The bench result is cited
  as evidence that adoption does **not** pay a hot-path tax at production
  N. The bench informs future micro-optimisation choices (small-N
  fast-path generation; tag-range partitioning) and does not gate the
  substrate decision itself.

## Alternatives considered

### Alternative A — Runtime feature toggle only (Wasmer-style)

- **Sketch**: a single binary contains all features, with runtime
  `--wasm-level=N` rejecting modules requiring features beyond N.
- **Why rejected**: does not satisfy "literally absent" — the binary
  still contains all v2.0+ / v3.0 code. Attack surface and size goals
  are not met.
- **Note**: the runtime toggle is **retained** as the two-stage control's
  inner gate (see "Two-stage control" above). The rejection here is
  against runtime-only — runtime-plus-build is the adopted shape.

### Alternative B — Per-layer ad-hoc DCE (gate only at ZirOp layer)

- **Sketch**: apply the substrate at the IR/codegen layer only; keep
  CLI / c_api / WASI as legacy.
- **Why rejected**: violates the cross-layer consistency goal (user
  feedback iii: "consistent pattern across every layer"). Phase 10 work
  on c_api / WASI / CLI extensions would either re-derive the pattern
  inconsistently or skip it entirely.

### Alternative C — Per-level build-target modules

- **Sketch**: produce 3 separate Zig modules (`zwasm_v1_0`, `zwasm_v2_0`,
  `zwasm_v3_0`) each pre-filtered at the module level; build-time selects
  one as the root.
- **Why rejected**: triples the module count and the test-runner matrix;
  the comptime filter approach achieves the same DCE outcome without the
  module duplication. Verified by spike `q3-build-option-dce-poc`.

### Alternative D — Conditional `pub` via `if (build_options.X)`

- **Sketch**: gate `pub fn handler_*` declarations behind `if (comptime
  build_options.X)` at the declaration site.
- **Why rejected**: Zig does not support conditional `pub` — the
  declaration is parsed regardless. The `inline for + continue` pattern
  is the canonical way to skip declarations without invoking them; this
  alternative does not exist in the language.

### Alternative E — Cranelift-style ISLE DSL

- **Sketch**: write op handlers in a DSL (similar to Cranelift's ISLE)
  compiled by a build step to Zig switch arms.
- **Why rejected**: requires bootstrapping a new tooling pipeline (DSL
  parser, code generator, Zig integration). The benefit (declarative
  pattern matching with sharing) does not exceed the cost for zwasm v2's
  scale. Re-evaluate if Phase 10 + Wasm 3.0 implementation reveals
  recurring share-able patterns across ops.

## Consequences

### Positive

- **Literal absence guarantees**: `-Dwasm=v1_0` builds are bit-for-bit
  smaller, with no v2.0+ symbols / strings / handler bodies. Audit and
  attack-surface reduction are concrete, not narrative.
- **Cross-layer consistency**: 4 layers (IR, CLI, c_api, WASI) share the
  same declarative-metadata + comptime-filter pattern. New layers added
  in Phase 10+ inherit the boilerplate.
- **Phase 10 readiness**: adding a Wasm 3.0 feature is one file (op file
  + CLI arg row + c_api export row if needed); no dispatcher edit, no
  cross-cutting test changes.
- **Audit substrate**: `scripts/check_build_dce.sh` + `audit_scaffolding §K.1`
  catch regressions at commit time, not at release time.

### Negative

- **5-dispatcher rewrite**: §9.12-B converts each of the 5 dispatchers
  (validator / lower / arm64 emit / x86_64 emit / interp) into
  `inline switch + dispatch_collector` consumers. Mechanical but
  cohort-large.
- **CLI / c_api / WASI declarative-form reshape**: existing parsing /
  export / syscall code becomes table-driven. Reshape of existing code
  rather than additive.
- **Spike verification cost**: 3 spikes ran at §9.12-pre to verify
  feasibility (~1 hour total wall-clock; included in §9.12-pre exit
  criterion).

### Neutral / follow-ups

- The 581-tag `inline switch` wall has been measured (no wall) but
  Phase 10's expansion to ~700-900 tags should re-validate; track in
  §15 future decisions.
- `include/wasm.h` preprocessor-gate generation via `addConfigHeader` is
  the canonical Zig 0.16 pattern; verify in §9.12-B.
- `test/build_completeness/` is a new test directory; lands in §9.12-A
  alongside `check_build_dce.sh`.
- The 3 spike directories remain under `private/spikes/q3-*/` (gitignored
  scratch). Their measurement reports (the `README.md` files) are the
  load-bearing artifacts; promotion to `.dev/lessons/` follows
  `.claude/rules/spike_lifecycle.md` if a measurement turns out to merit
  long-term retention.

## References

- ROADMAP §2 P14 (sharpening per ADR-0071), §4.5 (per-op file pattern;
  ADR-0023 amend), §4.6 (build flags).
- ADR-0023 (src directory structure; §4.5 amend pair, 2026-05-19 Revision
  history row).
- ADR-0050 (skip-impl ratchet; D-5 + D-6 amend, 2026-05-19).
- ADR-0070 (libc dependency policy; orthogonal but cited as a sibling
  cleanup landing in §9.12).
- ADR-0071 (Phase 9 substrate audit resolution; Hypothesis C adoption is
  the keystone decision this ADR realises in implementation detail).
- 3 spikes:
  - `private/spikes/q3-zig-inline-switch/` (compile-time wall measurement;
    no wall at 581 tags).
  - `private/spikes/q3-interp-dispatch-bench/` (dispatch shape cycle bench;
    perf null at production N; substrate decision proceeds on design-quality axes).
  - `private/spikes/q3-build-option-dce-poc/` (representative-op DCE PoC;
    literal absence confirmed via `nm` + `xxd`).
- User feedback 2026-05-19 (the adoption-of-build-option-DCE axis as
  Phase 9 completion requirement iii).
- Master plan Chapter 4 (proposed build-option DCE substrate architecture)
  + Chapter 7 (mechanical enforcement layer).

## Revision history

| Date       | SHA          | Note                                                                              |
|------------|--------------|-----------------------------------------------------------------------------------|
| 2026-05-19 | `<backfill>` | Initial draft — build-option DCE substrate; 4-layer detail + Alternatives A/B/C/D/E + 3 spike summaries (q3-build-option-dce-poc, q3-zig-inline-switch, q3-interp-dispatch-bench). |
