# Phase 9 Completion — Master Plan v2 2026-05-19

> **Purpose**: Achieve all of the user's 7 requirements plus additional feedback (design quality first / build-option DCE driven through every layer / mechanical enforcement so we cannot give up) within the Phase 9 close, and establish a substrate that lets Phase 10 (Wasm 3.0) start with **zero debt, fully prepared, fast iteration, and giving up made physically impossible**.
>
> **Origin**: After §9.9 [x] flip in the 2026-05-18 to 19 sessions, the user presented 7 requirements plus 3 additional feedback items (skip-impl 100% as top priority / removal of cost/risk wording / adopting the build-option DCE axis). Investigation → integration → self-review → first draft → policy adjustment → this second draft.
>
> **Status**: Confirmed draft. In this session it has been promoted to `.dev/phase9_completion_master_plan.md` and the full scaffolding has been set up. Next `/continue` will launch the autonomous loop starting from §9.12-pre (ADR drafts + 3 spikes).

---

## Chapter 1 — User requirements (verbatim) + feedback incorporation

### 1.1 The 7 requirements

| # | Requirement |
|---|---|
| (1) | Resolve all Phase-9-eligible debt and ADRs |
| (2) | **Wasm 2.0 completion 100% PASS (arm/amd) + comprehensive tests that guarantee it** |
| (3) | Incorporate, "sparing no effort", the insights and reflections gained through Phase 9 into the codebase / tools / instructions |
| (4) | Modular / dep-direction / bug-resistant preparation so that Phase 10+ C API / WASI / Wasm 3.0 / CLI / build option work proceeds without friction |
| (5) | Wasm 2.0 benchmark Mac-only + comparison with other runtimes (referring to v1 is allowed) |
| (6) | Iteration speed — drastic reorganization of `.dev/` / `.claude/` / tools / gates |
| (7) | After cleanup, run windowsmini through end-to-end + fix Win-specific bugs |

### 1.2 Additional feedback (3 items)

| # | Content |
|---|---|
| (i) | **Reaching 100% on skip-impl is the top priority** (= the primary exit criterion of Phase 9 completion) |
| (ii) | **Drop cost-estimate / risk wording because it induces compromise**. The decision axes are "design cleanliness / resistance to latent bugs / ease of resolution" |
| (iii) | **Establish true DCE via build-options + the two-stage control with runtime options** in a consistent pattern across every layer. In a `-Dwasm=v1_0` build, Wasm 2.0+ code / CLI arguments / c_api / WASI must be **literally absent** |

### 1.3 Overarching value

The substrate must be branded with "**ingenuity and completeness so we never give up**". While using spikes liberally to try and err, in the final form any change in the direction of compromise is **physically blocked** by gate / lint / `@compileError` / audit.

---

## Chapter 2 — Measured ground truth (2026-05-18 to 19)

### 2.1 Wasm 2.0 completion level = not yet achieved

| Runner | PASS | FAIL | Skipped | skip-impl | skip-adr |
|---|---:|---:|---:|---:|---:|
| `spec_assert_runner_non_simd` | 25325 | 0 | 688 | **193** | 495 |
| `simd_assert_runner` | 13301 | 0 | 440 | **50** | 390 |
| **Total** | 38626 | 0 | 1128 | **243** | 885 |

The handover/debt claim of "skip-impl == 0" is **inaccurate**. 243 directives remain in the actual measurement.

### 2.2 Breakdown of the 243 skip-impl items

| Token | Count | Originating corpus / cause |
|---|---:|---|
| `SKIP-CROSS-MODULE-IMPORTS` | 100 modules + ~66 cascade | imports (39) / elem (19) / data (19) / linking (16) / table_grow (2) / memory_grow (2) / global (2) / table (1). `hasUnbindableImports()` over-rejects. |
| `SKIP-NO-LINK-TYPECHECK` | 26 | imports (24) / linking (2). Link-time type check of `assert_unlinkable` is not implemented. |
| `SKIP-VALIDATOR-GAP` (SIMD) | 50 | simd_lane (36) / simd_align (11) / others (3). Gaps in `assert_invalid` checking of lane-number range and align-immediate range. |
| `skip-impl` inside `exports/manifest.txt` | 1 | `non-invoke-action` (`get` / `set` directives not yet supported). |

### 2.3 ZirOp + Dispatcher structure

- ZirOp: **568 + 13 pseudo = 581 tags**
- All Wasm 3.0 slots are declared (try_table / throw / return_call / call_ref / GC / memory64 / etc.)
- 5 dispatcher sites:
  - `validator.zig` (1699 LOC, switch line 515)
  - `lower.zig` (1091 LOC, switch line 160)
  - `arm64/emit.zig` (1984 LOC, switch line 808 → `op_*.zig`)
  - `x86_64/emit.zig` (1956 LOC, same shape)
  - `interp/dispatch.zig + mvp.zig` — already Hypothesis A (central `DispatchTable.interp[op]` lookup)
- `DispatchTable` has 4 axes (parsers / interp / jit_arm64 / jit_x86) — **only interp is populated**
- `src/feature/*/register.zig` — **only mvp is implemented** (214 LOC); the other 9 features are placeholders (20 LOC each)
- `src/instruction/wasm_X_Y/<op>.zig` — **3514 LOC populated** (most of Wasm 1.0 / 2.0; Wasm 3.0 is placeholder)
- `build_options.wasm_level` consultation: **only 2 diagnostic sites in `cli/main.zig`** (validator/lower/emit/runtime untouched)

### 2.4 debt / ADR / lessons / scaffolding inventory

- debt: 28 active (`now` 6, `blocked-by` 22)
- ADR: 77 entries (`Accepted` 49; ~22-25 candidates for moving to `Closed (Phase X DONE)` since Phase 1-8 is DONE)
- lessons: 39 entries (1 not yet Citing-backfilled)
- scaffolding: `ROADMAP.md` 2373 LOC (Phase 0-8 narrative has 800-1000 LOC of compression room), `continue/SKILL.md` 958 LOC (300 LOC of compression room), 6 private/audit-*.md files (5 old ones are archive candidates)

---

## Chapter 3 — Design axes and Q3 adoption

### 3.1 Evaluation axes (changed from the prior plan)

| Axis | Adopted | Not adopted |
|---|---|---|
| Design cleanliness (1 op = 1 file / consistent across all layers / clean axis separation) | Yes | |
| Resistance to latent bugs (build option makes a feature "literally absent" / type-level enforcement) | Yes | |
| Ease of resolution (when a failure occurs, the root cause is confined to 1 file / unused paths are physically absent) | Yes | |
| ~~Implementation cost / effort~~ | | No (induces compromise) |
| ~~Risk estimation~~ | | No (induces compromise) |
| ~~Wall-clock timeline~~ | | No (delegated to the autonomous loop) |

### 3.2 Q2 — Re-inspection scope

| Clause | Adoption |
|---|---|
| §2 P13 (Day-1 ZIR sized for full target) | **Accept (kept)** — 581 tags already declared, Wasm 3.0 slots in place |
| §2 P14 (no pervasive build-time `if`) | **Amend (sharpen)** — "Only **runtime** if-branching on feature flags is forbidden. `if (comptime build_options.X)` and `if` for DCE in a `comptime` context are allowed". The Cranelift / Wasmer style (runtime feature toggle) remains forbidden |
| §4.5 (DispatchTable feature modules) | **Amend** — "DispatchTable interp axis = required (mvp complete); validator/lower/emit/jit axes = per-op file pattern (`src/instruction/wasm_X_Y/<op>.zig` exports `pub const handlers = .{...}`, dispatched via comptime collector)" |
| §4.6 (`-Dwasm=` / `-Denable=` build flags) | **Accept (consistent with Q3)** — flags are declared in build.zig; the collector applies the feature_level filter via `build_options.wasm_level` |

### 3.3 Q3 — Architecture adoption = **C** (per-op file + comptime collector + build-option DCE)

Facts from the investigation (Task #2 survey):

| Hypothesis | Build-option DCE | 1 op = 1 file | Consistent across all layers |
|---|---|---|---|
| A (DispatchTable completion) | Not possible (table is populated at runtime) | No | No |
| B (wrapping with comptime if) | Possible | No (central file becomes monolith) | Partial |
| **C (per-op file + comptime inline_for)** | **Possible** | **Excellent** | **Excellent** |
| D-1 (current hybrid) | Not possible | Partial | No |

**Adopted = C**. Rationale: it surpasses the others on the three axes of design cleanliness, resistance to latent bugs, and ease of resolution. Among A/B/C, build-option DCE truly works only for B/C. Among them, only C achieves both "1 op = 1 file" organization and the across-all-layers consistent pattern.

C's compile-time wall (the `inline switch` eval quota / IR bloat for 581 tags on Zig 0.16) will be measured by spike. Even if we hit the wall, we can split `inline switch` by character (equivalent to Cranelift's `isle-split-match`) to work around it. **This is not a reason to compromise on the design**.

### 3.4 Q4 — Boundary between audit and implementation

Audit deliverables = ADR + decisions + 3 spike measurements + minimal implementation sample (implement a representative op `i32.add` in the C pattern, confirm all green on `-Dwasm={v1_0,v2_0,v3_0}` builds). C migration of the remaining ops is done in §9.12-B (completion of the adopted Q3 C).

### 3.5 Q5 — Substrate hygiene

| Trigger | Locked-in artifact |
|---|---|
| D-132 / D-133 op_table register-numeral hardcoding | Extension of the comptime disjointness check in `abi.zig` + reinforcement of `audit_scaffolding §G` grep + D-133 sweep |
| Cat III runtime/instance hygiene | New `.claude/rules/runtime_instance_layer.md` + lint |
| comment-as-invariant pattern | **New `.claude/rules/comment_as_invariant.md`** |
| `bug_fix_survey` discipline | Reinforcement of `.claude/rules/bug_fix_survey.md` + inline `/continue` Step 4 checklist |
| test stress axes | Add §"stress axes" section to `.claude/rules/edge_case_testing.md` + corpus design ADR |

### 3.6 Q6 — libc dependency boundary

| Deliverable |
|---|
| ADR `0070_libc_dependency_policy.md` (3 categories: necessary / replaceable / convenience) |
| `.claude/rules/libc_boundary.md` (auto-load on `src/**/*.zig`) |
| ROADMAP §14 amendment (add "Unconscious libc fanout" to the forbidden list) |
| `scripts/check_libc_boundary.sh` + extension of `audit_scaffolding §G.5` |
| Sample migration: `std.c.write` / `_exit` / `getenv` / `munmap` (~5-10 sites) → `std.posix.*` |

---

## Chapter 4 — Proposed build-option DCE substrate architecture

### 4.1 Consistent pattern across all layers

Using the **build option axes** of `-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2}` × (future) `-Denable=<features>`, achieve a state where each layer is **literally "absent"**.

### 4.2 ZirOp / validator / lower / JIT / interp

Each op exports the following:

```zig
// src/instruction/wasm_X_Y/<op>.zig (canonical form)
pub const op_tag: ZirOp = .i32_add;
pub const wasm_level: WasmLevel = .v1_0;
pub const enable_features: []const Feature = &.{};  // for future use
pub const handlers = .{
    .validate = validate_i32_add,
    .lower    = lower_i32_add,
    .arm64    = emit_arm64_i32_add,
    .x86_64   = emit_x86_64_i32_add,
    .interp   = interp_i32_add,
};

fn validate_i32_add(ctx: *ValidatorCtx) !void { ... }
fn lower_i32_add(ctx: *LowerCtx)         !void { ... }
fn emit_arm64_i32_add(ctx: *Arm64EmitCtx) !void { ... }
fn emit_x86_64_i32_add(ctx: *X86_64EmitCtx) !void { ... }
fn interp_i32_add(ctx: *InterpCtx)       !void { ... }
```

Central dispatch (1 file per axis):

```zig
// src/ir/dispatch_collector.zig (new)
const all_op_modules = collectAllOpModules();  // comptime
// At comptime, import and collect every src/instruction/wasm_X_Y/*.zig

pub fn validate(op: ZirOp, ctx: *ValidatorCtx) !void {
    return inline switch (op) {
        inline else => |tag| blk: {
            const op_mod = comptime opModuleFor(tag);
            if (comptime op_mod.wasm_level > build_options.wasm_level) {
                @compileError("op " ++ @tagName(tag) ++ " not in build (wasm_level=" ++ @tagName(build_options.wasm_level) ++ ")");
            }
            break :blk op_mod.handlers.validate(ctx);
        },
    };
}
```

In a `-Dwasm=v1_0` build the Wasm 2.0+ `validate_*` functions **are not reached at comptime → not included in the binary**.

### 4.3 CLI (`src/cli/`)

```zig
// src/cli/args.zig
pub const args = .{
    .{ .name = "--wasm-level",   .wasm_level = null,   .wasi_level = null,   .handler = handle_wasm_level },
    .{ .name = "--wasi-dir",     .wasm_level = null,   .wasi_level = .p1,    .handler = handle_wasi_dir },
    .{ .name = "--enable-gc",    .wasm_level = .v3_0,  .wasi_level = null,   .handler = handle_gc_flag },
};

pub fn parseArgs(...) !void {
    inline for (args) |arg| {
        if (comptime arg.wasm_level) |lvl| {
            if (comptime lvl > build_options.wasm_level) continue;  // not registered at all
        }
        if (comptime arg.wasi_level) |lvl| {
            if (comptime lvl > build_options.wasi_level) continue;
        }
        // arg is included in the build → it appears in the matching table at parse time
    }
}
```

In a `-Dwasm=v1_0` build, `--enable-gc` **does not appear** in the parser's match table → `zwasm run --enable-gc foo.wasm` becomes "unknown argument: --enable-gc". It also does not appear in `zwasm --help`.

### 4.4 C API (`src/api/wasm.zig` + `include/wasm.h`)

```zig
// src/api/wasm.zig (canonical pattern)
pub const exports = .{
    .{ .name = "wasm_module_new",      .wasm_level = null,   .impl = wasm_module_new },
    .{ .name = "wasm_v128_extract",    .wasm_level = .v2_0,  .impl = wasm_v128_extract },
    .{ .name = "wasm_gc_struct_new",   .wasm_level = .v3_0,  .impl = wasm_gc_struct_new },
};

comptime {
    for (exports) |e| {
        if (e.wasm_level) |lvl| {
            if (lvl > build_options.wasm_level) continue;  // not exported at all
        }
        @export(e.impl, .{ .name = e.name, .linkage = .strong });
    }
}
```

In a `-Dwasm=v1_0` build, the `wasm_v128_extract` symbol does not exist in the binary (does not appear in nm / dumpbin). On the `include/wasm.h` side, the declaration is gated by a preprocessor `#if ZWASM_WASM_LEVEL >= 2` (build.zig runs a header configure step for `wasm.h`).

### 4.5 WASI (`src/wasi/`)

Same pattern. Each `wasi_p1_*` / `wasi_p2_*` syscall carries `wasi_level` metadata and is DCE'd via build options.

### 4.6 Significance of cross-layer consistency

- When adding one feature, the only edits needed are **1 op file + (test)**
- Even as features grow, the dispatcher does not change (the comptime collector auto-extends)
- When a bug occurs, the responsible op is localized in one shot (= grep for "feature X" hits a single file)
- Adjusting build options causes things to **truly appear/disappear** → size, dependencies, and surface are all affected

---

## Chapter 5 — Phase 9 completion sub-row structure + deliverables

### 5.1 List of sub-rows (11 sub-rows + 2 hard gates)

```
§9.12       Substrate audit decision gate (collab; ADR Accept only)
§9.12-pre   ADR drafts (Q2/Q3/Q4/Q5/Q6 + Q3 C adoption and DCE axis) + 3 spikes (autonomous)
§9.12-A     Iteration-speed scaffolding compression + building the enforcement layer
§9.12-B     Completion of Q3 C adoption (per-op file for all ops + comptime collector + build-option DCE extended to all layers)
§9.12-C     Q5 hygiene landings (rules + lints + code)
§9.12-D     Q6 libc boundary
§9.12-E     Wasm 2.0 completion 100% (skip-impl 243 → 0 + comprehensive 4-track tests green)  ← Primary exit of Phase 9 completion
§9.12-F     Phase-9-eligible debt cohort
§9.12-G     Phase 10 prep substrate (validation of Wasm 3.0 slots + c_api tests + CLI extensibility + Zone enforce)
§9.12-H     Bench baseline (Mac-only Wasm 2.0 + wasmtime comparison)
§9.12-I     ADR + lesson + private/ closure
§9.13-0     Cat IV windowsmini reconcile (D-084 / D-028 / D-136 + cross-platform sweep)
§9.13       Phase 10 entry gate (collab review)
```

### 5.2 Dependency DAG

```
§9.12-pre (ADR drafts + spikes; autonomous)
   |
§9.12 (collab decision gate)
   |
§9.12-A (scaffolding compression + enforcement layer)  ← All subsequent sub-rows are protected by the enforcement
   |
§9.12-B (Q3 C completion + DCE across all layers)
   |
§9.12-C (Q5 hygiene) <-> §9.12-D (Q6 libc) — can run in parallel
   |
§9.12-E (Wasm 2.0 100% drainage)  ← Primary exit of Phase 9 completion
   |
§9.12-F (debt cohort) <-> §9.12-H (Bench) — can run in parallel
   |
§9.12-G (Phase 10 prep substrate)
   |
§9.12-I (ADR + lesson + private/ closure)
   |
§9.13-0 (windowsmini batch + cross-platform sweep)
   |
§9.13 (Phase 10 entry gate)
```

### 5.3 Deliverables + exit criteria for each sub-row

#### §9.12 — Substrate audit decision gate (collab)

- Input: ADR drafts authored autonomously in §9.12-pre + 3 spike measurements
- Deliverable: The user Accepts Q2-Q6 + the Q3 C adoption + the build-option DCE all-layer extension (ADR-0073)
- Exit: ROADMAP §1 / §2 P/A / §4.5 / §4.6 / §14 amendments are decided; ADR drafts move to `Status: Accepted`
- Autonomous loop: skip (collab session)

#### §9.12-pre — ADR drafts + 3 spikes (autonomous)

- ADR drafts (5-7 entries):
  - ADR-0070 libc_dependency_policy
  - ADR-0071 phase9_substrate_audit_resolution (Q2 P14 sharpening + Q3 C adoption + Q4 boundary)
  - ADR-0072 comment_as_invariant_rule (Q5)
  - ADR-0073 build_option_dce_substrate (the principle of establishing build-option-based DCE consistently across all layers)
  - ADR-0023 §4.5 amendment (formal adoption of the per-op file pattern)
  - (optional) ADR-0050 amendment (skip-impl one-way ratchet)
- 3 spikes (`private/spikes/`):
  - `q3-zig-inline-switch/` — measure Zig 0.16 compile time + binary size for `inline switch (op) { inline else => |tag| { ... } }` with 581 tags
  - `q3-interp-dispatch-bench/` — cycle difference between `DispatchTable.interp[op]` indirect call vs zware-style `@call(.always_tail, ...)`
  - `q3-build-option-dce-poc/` — implement a representative op (`i32.add`) in the C pattern, then for the 6 builds of `-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2}`:
    - confirm binary size (`-Dwasm=v1_0` is the smallest)
    - confirm symbol table (no Wasm 2.0+ symbols in `-Dwasm=v1_0`)
    - tests pass on all builds
- Exit: 5-7 ADRs land with `Status: Proposed`, 3 spikes report measurements + conclusions via README → hand off to §9.12 collab review

#### §9.12-A — Scaffolding compression + building the enforcement layer

##### Scaffolding compression

- `ROADMAP.md` Phase 0-8 narrative → `.dev/archive/roadmap_phase0_8.md` (-800-1000 LOC)
- Compress `.claude/skills/continue/SKILL.md` — archive past anti-patterns via `LOOP.md` (-300 LOC)
- `.dev/phase8_transition_gate.md` (closed) → `.dev/archive/phase_gates/`
- Inventory `.dev/next-session-agenda.md` (338 LOC)
- Old 5 `private/audit-*.md` → `private/archive/audits/`
- Inventory `private/notes/*.md`
- Archive `private/spikes/break-inner/` / `d134_sigaction_shim/`
- Measure execution time of the existing 8 gates (`zig fmt`, `zone_check`, `file_size_check`, `spill_aware_check`, `zig build lint`, `check_skip_adrs`, `check_adr_history`, `check_lesson_citing`, `check_invariant_comments`) + study consolidation room + noise reduction + extension of skip rules

##### Building the enforcement layer (detailed in Chapter 7; lands here)

- Implement all 9 enforcement items from Chapter 7, and integrate each into gate_commit / pre-push / `audit_scaffolding` extensions
- Initialize `bench/results/skip_impl_history.yaml` (seed current 243 as the baseline)
- Initialize `.dev/p9_completion_progress.yaml` (initial state)

- Exit: cold-start read guide -40%; average gate_commit time -20%; all 9 enforcement items hooked into pre-commit / pre-push; ratchet history + progress tracker yaml seeded

#### §9.12-B — Completion of Q3 C adoption + build-option DCE extended across all layers

##### Per-op file migration of all ops

- Complete remaining Wasm 1.0 placeholders (`control.zig` / `parametric.zig` / `variable.zig`)
- Complete Wasm 2.0 placeholder (`multi_value.zig`)
- Split SIMD-128 ops from `src/engine/codegen/{arm64,x86_64}/op_simd*.zig` into `src/instruction/wasm_2_0/simd_128/<op>.zig` (consistent with the ADR-0023 §4.5 amendment)
- Guarantee via comptime check that every op file exports `pub const op_tag` / `wasm_level` / `enable_features` / `handlers = .{ .validate, .lower, .arm64, .x86_64, .interp }`

##### Central collector + dispatcher

- New `src/ir/dispatch_collector.zig` — `collectAllOpModules()` comptime function
- Rewrite the 5 dispatchers (`validator.zig`, `lower.zig`, `arm64/emit.zig`, `x86_64/emit.zig`, `interp/dispatch.zig`) into the **inline switch + collector consumption** form
- If we hit the inline-switch compile-time wall, split `inline switch` by tag ranges (equivalent to Cranelift `isle-split-match`)

##### Build-option DCE extension

- ZirOp/validator/lower/JIT/interp axes: established above
- **CLI** (`src/cli/args.zig`): rewrite argument registration into declarative form (`args = .{ ... }`); build-option DCE via `comptime` filter
- **C API** (`src/api/wasm.zig` + `include/wasm.h`): declarative form for export functions (`exports = .{ ... }`); `comptime @export` filter; preprocessor gate for `wasm.h`
- **WASI** (`src/wasi/`): declarative form for syscalls; `wasi_level` metadata; `comptime` filter

##### Test

- `-Dwasm=v1_0` / `v2_0` / `v3_0` × `-Dwasi=p1` / `p2` = 6 builds all green
- Build-DCE E2E in `test/build_completeness/` is green

- Exit: `zig build -Dwasm=v1_0 -Dwasi=p1 test-all` through `-Dwasm=v3_0 -Dwasi=p2 test-all` all green; `scripts/check_build_dce.sh` 0; per-op file completeness comptime check passes

#### §9.12-C — Q5 hygiene landings

- New `.claude/rules/comment_as_invariant.md`
- Extend `abi.zig` comptime disjointness check: turn `table_emit_scratch_gprs` / `memory_emit_scratch_gprs` into named-constant arrays + comptime assertion
- D-133 sweep: route hardcoded X10/X11/X12 in arm64 `op_table.zig` / `op_memory.zig` through named constants
- Add "stress axes" section to `.claude/rules/edge_case_testing.md`
- Add grep to `audit_scaffolding §G` (reinforce D-132/D-133 detection)
- Reinforce `.claude/rules/bug_fix_survey.md` + inline `/continue` Step 4 checklist
- New `.claude/rules/runtime_instance_layer.md` (zone rule specific to the Cat III code layer)
- Exit: D-133 closed; comment_as_invariant rule landed; 0 audit-grep detections; rule auto-load confirmed

#### §9.12-D — Q6 libc boundary

- ADR-0070 `libc_dependency_policy.md` (`Status: Accepted`)
- `.claude/rules/libc_boundary.md` (auto-load)
- ROADMAP §14 amendment
- `scripts/check_libc_boundary.sh` + extension of `audit_scaffolding §G.5`
- Sample migration: `std.c.write` / `_exit` / `getenv` / `munmap` ~5-10 sites → `std.posix.*`
- Exit: `bash scripts/check_libc_boundary.sh` 0; test-all green on all hosts

#### §9.12-E — Wasm 2.0 completion 100% (primary exit of Phase 9 completion)

##### Primary tasks

- **SKIP-CROSS-MODULE-IMPORTS 100 modules**: relax the reject condition of `hasUnbindableImports()` + add resolvers for each import-shape class (imports / elem / data / linking / table* / memory* / global)
- **SKIP-NO-LINK-TYPECHECK 26**: implement `Instance.checkImportType()` + `applyAssertUnlinkable` callback
- **SKIP-VALIDATOR-GAP SIMD 50**: support `assert_invalid` for `simd_lane` (lane index range) + `simd_align` (alignment immediate range)
- **`exports/manifest.txt` non-invoke-action 1**: extend the action dispatcher (`get` / `set` directives)
- **D-079 v128 cross-module imports (ii)**: ADR-0052 §3 globals extension

##### 4 comprehensive test tracks (the "comprehensive tests that guarantee" of requirement (2))

- spec corpus (`test-spec-wasm-2.0-assert` + `test-spec-simd`): **skip-impl == 0** (Mac + ubuntunote bit-identical)
- edge_cases corpus (`test-edge-cases`): all PASS — land new fixtures if needed
- realworld corpus (TinyGo / Rust within Wasm 2.0 scope): all PASS (emcc family deferred to D-026 Phase 11)
- differential vs wasmtime (`test-wasmtime-misc-runtime`): all PASS
- Per-ZirOp unit test coverage: all ops covered (`grep -c 'test \"' src/instruction/wasm_{1_0,2_0}/**/*.zig`)

##### Exit criteria (literal)

- `spec_assert_runner_non_simd: N passed, 0 failed, 495 skipped (= 0 skip-impl + 495 skip-adr)` Mac + ubuntunote bit-identical
- `simd_assert_runner: 13301 passed, 0 failed, 390 skipped (= 0 skip-impl + 390 skip-adr)` Mac + ubuntunote bit-identical
- All 4 testsuite tracks (spec / edge_cases / realworld / differential) green
- `scripts/check_skip_impl_ratchet.sh` 0 (= the ratchet stays at 0; later chunks cannot increase it)

#### §9.12-F — Phase-9-eligible debt cohort

| Row | Action |
|---|---|
| D-094 | Discharge x86_64 multi-result indirect-result-buffer, or confirm dissolution by the D-140 / D-148 chain |
| D-090 | lower.zig type-stack walker (validator mirror) |
| D-062 | arm64 v128 9th+ stack overflow path |
| D-141 | file_size_check WARN 20 files — mostly dissolved by Q3 C adoption; remaining items individual ADRs |
| D-081 | emit.zig source split — confirm dissolution by Q3 C adoption |
| D-055 | emit_test_*.zig migration |

- Exit: debt active rows < 15

#### §9.12-G — Phase 10 prep substrate

- Output the Wasm 3.0 slot ↔ Wasm spec number mapping table for ZirOp into `.dev/wasm_3_0_zirop_mapping.md` (machine-generated by `dispatch_collector.zig`)
- Extend the placeholder files under `src/instruction/wasm_3_0/` to cover all Phase 10 features (placeholders for every feature in GC / EH / tail-call / memory64 / multi-memory / typed func refs)
- `src/api/instance.zig` (1424 LOC) health audit + helper extraction (early discharge of D-139): add minimal coverage for c_api Instance-path tests (instantiate / call / drop / destroy / cross-module / multi-result)
- Add CLI `--invoke <fn> <args>` mode (needed for Phase 11 bench)
- Diff check `include/wasm.h` against upstream
- Migrate `bash scripts/zone_check.sh --gate` (info → enforce); confirm 0 zone violations
- New `.dev/architecture/zone_layout.md` (extracted from ROADMAP §A1 + brought up to date)
- Exit: all Phase 10 feature ZirOps are `comptime`-rejected with `Error.UnsupportedOpForBuildLevel` (= in Phase 10 we can start implementation simply by relaxing the `comptime` guard); `zone_check --gate` 0; basic c_api path tests landed

#### §9.12-H — Bench baseline (Mac-only Wasm 2.0 + wasmtime comparison)

- Add `scripts/run_bench.sh --compare=wasmtime` flag (~150 LOC)
- `--capture-rss` via `/usr/bin/time -l` (Mac)
- 26 fixtures × hyperfine `--warmup 3 --runs 5` on Mac aarch64 ReleaseSafe
- Add `runtime: zwasm` / `runtime: wasmtime` distinguished rows in `bench/results/history.yaml`
- D-074 partial resolution (wazero / wasmer / bun / node + the `-Dwith-bench-compare` flag are Phase 11)
- Exit: "p9-close: Wasm-2.0 baseline (Mac aarch64)" row in history.yaml; zwasm vs wasmtime mean_ms ratio documented

#### §9.12-I — ADR + lesson + private/ closure

- D-149 discharge: SHA backfill for the ADR Phase-9 cohort (75 placeholders → 0); commit `chore(adr): SHA backfill — Phase 9 completion cohort`
- ADR Status canonical pass: ~22-25 items `Accepted` → `Closed (Phase X DONE)` (those whose Phase 1-8 is already finished)
- Canonicalize the Status wording in `skip_cross_module_register.md`
- Re-evaluate Status in `skip_cross_module_action.md` (move to `Closed (Phase 9 §9.12-E DONE)` once §9.12-E is complete)
- Lesson backfill: fill in Citing for `2026-05-18-class-c-callee-without-caller-segvs-fac.md`
- Scan for lesson promotion candidates (those with 3+ citations become ADRs)
- Exit: `check_adr_history.sh --gate` 0; `check_lesson_citing.sh` 0; number of `Accepted` ADRs < 30

#### §9.13-0 — Cat IV windowsmini reconcile + cross-platform sweep

- Run reset + `zig build test-all` on windowsmini
- D-084 (Win64 v128 marshal residual)
- D-136 (Win64 SEH bridge for assert_trap recovery)
- D-028 (re-evaluate windowsmini SSH IPC flake)
- Confirm Windows compatibility of the new `std.posix.*` migration from Q6
- Whether the Q3 C wasm_level guard functions for `-Dtarget=x86_64-windows-gnu`
- Confirm whether build-option DCE works on the Windows build
- Exit: windowsmini `test-all` bit-identical across 3 hosts; `skip-impl == 0` on all 3 hosts; gating restored via `should_gate_windows.sh --record`

#### §9.13 — Phase 10 entry gate (collab)

- `.dev/phase10_transition_gate.md` collab review
- Confirm Phase 10 scope / Wasm 3.0 feature order / Track D
- Phase Status widget flip: Phase 9 = DONE, Phase 10 = IN-PROGRESS
- Exit: user [x]

---

## Chapter 6 — Proposed ROADMAP amendments

### 6.1 §9 table

| Row | Status |
|---|---|
| 9.9 | [x] (kept as-is) |
| 9.9-II | [x] `fb063b09` |
| 9.9-III | [x] `2dbd3f15` |
| 9.9-IV | [~] moved to §9.13-0 |
| 9.10 | [~] moved to Phase 11 |
| 9.11 | [x] `f06a3c9b` |
| **9.12** | [ ] (Substrate audit decision gate; collab; ADR Accept only) |
| **9.12-pre** | [ ] (ADR drafts + 3 spikes; autonomous) |
| **9.12-A** | [ ] (Scaffolding compression + building the enforcement layer) |
| **9.12-B** | [ ] (Completion of Q3 C adoption + build-option DCE extended across all layers) |
| **9.12-C** | [ ] (Q5 hygiene landings) |
| **9.12-D** | [ ] (Q6 libc boundary) |
| **9.12-E** | [ ] (Wasm 2.0 completion 100% — skip-impl 243 → 0 + 4 comprehensive test tracks) |
| **9.12-F** | [ ] (Phase-9-eligible debt cohort) |
| **9.12-G** | [ ] (Phase 10 prep substrate) |
| **9.12-H** | [ ] (Bench baseline) |
| **9.12-I** | [ ] (ADR + lesson + private/ closure) |
| 9.13-0 | [ ] (Cat IV windowsmini + cross-platform sweep) |
| 9.13 | [ ] (Phase 10 entry gate; collab) |

### 6.2 Phase Status widget wording

Before amendment:
> | 9 | IN-PROGRESS | Wasm 1.0 + 2.0 (incl. SIMD) completion on 3 hosts (per ADR-0056 + ADR-0065) |

After amendment (applied in a commit after ADR-0071 is Accepted at the §9.12 collab gate; not changed in this session):
> | 9 | IN-PROGRESS | Wasm 1.0 + 2.0 (incl. SIMD) **literal 100%** (skip-impl == 0 across spec + edge_cases + realworld + differential) on 3 hosts + Phase 10 substrate readiness (build-option DCE across all layers; per ADR-0056 + ADR-0065 + ADR-0071 + ADR-0073) |

### 6.3 ADR new / amend

| Action | ADR | Content |
|---|---|---|
| New | **ADR-0070** | `libc_dependency_policy.md` (Q6) |
| New | **ADR-0071** | `phase9_substrate_audit_resolution.md` (Q2 P14 sharpening + Q3 C adoption + Q4 boundary) |
| New | **ADR-0072** | `comment_as_invariant_rule.md` (Q5) |
| New | **ADR-0073** | `build_option_dce_substrate.md` (the principle of establishing build-option DCE consistently across all layers) |
| Amend | ADR-0023 §4.5 | Formal adoption of the per-op file pattern; DispatchTable interp axis required, validator/lower/emit/jit axes = per-op file |
| Amend | ADR-0056 / ADR-0065 | Add revision history |
| Amend | ADR-0050 | Add skip-impl one-way ratchet (D-5 / D-6) |
| Amend | ADR-0062 §9.12 row text | Explicitly note that implementation sub-rows 9.12-A..I have been split out of §9.12 |

### 6.4 ROADMAP §14 forbidden-list amendment

Added item: "Unconscious libc fanout (new `std.c.*` calls without ADR justification or rule exception)" with cite to ADR-0070.

Added item: "Changes in the direction of increasing skip-impl counts (unless justified by ADR)" with cite to ADR-0050 D-5.

### 6.5 §18 amendment-policy applicability

- Adding sub-rows to the §9 table = **routine status update** (§18 ADR not required)
- Phase Status widget wording change = **load-bearing** = covered by ADR-0071
- §14 amendment = **load-bearing** = covered by ADR-0070 + ADR-0050 amend
- §4.5 amend = **load-bearing** = covered by ADR-0023 amend

---

## Chapter 7 — Mechanical enforcement layer that prevents giving up (9 items)

A substrate where "changes in the direction of giving up" are **physically blocked** by gate / lint / `@compileError` / audit. Everything lands in §9.12-A.

### 7.1 Build-option DCE enforcement

| Deliverable | Landing | Fire timing |
|---|---|---|
| `scripts/check_build_dce.sh` | gate_commit + gate_merge | pre-commit (subset) + pre-push (full) |
| `audit_scaffolding §K.1` (new section — Phase 9 completion enforcement) | extension of existing skill | periodic audit |
| `test/build_completeness/` + `test-build-completeness` step | build.zig + test-all | per chunk gate |

Content: build the 6 build-option combinations (`-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2}`) + grep the symbol table + confirm binary size. If `wasm_2_0_*` symbols remain in the `-Dwasm=v1_0` build, FAIL.

### 7.2 Per-op file completeness

| Deliverable | Landing | Fire timing |
|---|---|---|
| `src/ir/dispatch_collector.zig` (new) | comptime check | fires immediately on `zig build` |

Content: enumerate all ZirOp tags; if the corresponding `src/instruction/wasm_X_Y/<op>.zig` is missing → `@compileError`; if any op file is missing one of `op_tag` / `wasm_level` / `handlers = .{... 5 axes ...}` → `@compileError`. The compile-error message includes "what is missing" + "where to add it".

### 7.3 Skip-impl one-way ratchet

| Deliverable | Landing | Fire timing |
|---|---|---|
| `scripts/check_skip_impl_ratchet.sh` | pre-push + CI | pre-push hook |
| `bench/results/skip_impl_history.yaml` | git-tracked | add a row at each chunk close |
| `audit_scaffolding §F.5b` (new) | extension of existing skill | periodic audit |

Content: compare the current commit's skip-impl count to the previous commit; if it increased, FAIL. Exceptions must be justified by ADR + registered in the yaml as `exempt: <ADR-NNNN>`. Increasing skip-impl without an ADR is impossible.

### 7.4 Give-up detection (anti-workaround / anti-fallback)

| Deliverable | Landing | Fire timing |
|---|---|---|
| `.claude/rules/no_fallback_on_failure.md` (new) | auto-load on `src/**/*.zig` | on edit |
| Existing `.claude/rules/no_workaround.md` | reinforce (add wording forbidding SKIP-* increases) | on edit |
| `scripts/check_fallback_patterns.sh` (new) | pre-commit | pre-commit hook |
| `audit_scaffolding §G.6` (new) | extension of existing skill | periodic audit |

Content: forbid silent-degradation patterns such as `catch {}` / `catch \|err\| return null` / `catch \|err\| default` / `catch \|err\| switch (err) { else => skip }`. Errors must always be propagated as named errors, or used only inside an ADR-justified exhaustive switch.

### 7.5 Spike lifecycle enforcement

| Deliverable | Landing | Fire timing |
|---|---|---|
| `.claude/rules/spike_lifecycle.md` (new; extracted from `extended_challenge.md` Step 4 + reinforced) | auto-load on `private/spikes/**` | on edit |
| Existing `scripts/audit_spikes.sh` | reinforce (detect lifecycle violations) | periodic audit |
| Existing `audit_scaffolding §G.4` | extend (confirm reject-lesson landing) | periodic audit |

Content: spikes have Status ∈ {running, merged-into-prod, rejected, archived}; lessons are required on rejected/archived; running > 14d raises an audit flag. "Experiments are fine, but discarding them without recording results is forbidden."

### 7.6 Chunk-close literal exit gate

| Deliverable | Landing | Fire timing |
|---|---|---|
| `scripts/check_subrow_exit.sh` (new) | pre-push hook | pre-push when an `[x]` flip is included |
| Exit criteria for each ROADMAP §9.12-X sub-row | spelled out (automated-checkable form) | edits to existing |
| `audit_scaffolding §K.6` (Phase 9 completion enforcement section) | extension of existing skill | periodic audit |

Content: commits that include a sub-row `[x]` flip are checked for literal satisfaction of the exit criteria. Example: the §9.12-E close commit physically confirms skip-impl == 0; the §9.12-B close commit confirms all build_completeness is green.

### 7.7 Q3 C design consistency audit

| Deliverable | Landing | Fire timing |
|---|---|---|
| `.claude/skills/dispatch_consistency_audit/SKILL.md` (new) | slash-command-capable skill | arbitrary invocation |
| Include in `audit_scaffolding §K.7` (Phase 9 completion enforcement section) | extension of existing skill | periodic audit (fires at boundaries) |

Content: confirm the three-way match of ZirOp tag count = per-op file count = 5-axis handler implementation count; feature_level metadata consistency; sample-check whether DCE per build option works as expected.

### 7.8 Phase 9 completion progress tracker (machine-readable)

| Deliverable | Landing | Fire timing |
|---|---|---|
| `.dev/p9_completion_progress.yaml` | git-tracked | update at each chunk close |
| `scripts/p9_completion_status.sh` (new) | live status | manual + Step 0.5b |
| Existing `.claude/rules/no_handover_predictions.md` | applied | (existing discipline) |

Content: migration progress in a matrix of sub-row × op × layer. `bash scripts/p9_completion_status.sh` outputs **the consistency between the current yaml and source + an overview of remaining work** (the Phase-9-completion edition of the §9.9-era `p9_simd_status.sh`).

### 7.9 Comptime verification of feature-level metadata

| Deliverable | Landing | Fire timing |
|---|---|---|
| `src/ir/feature_level_check.zig` (new) | comptime | fires on `zig build` |
| `.dev/spec_compliance_table.md` | doc | machine-generated by dispatch_collector |

Content: comptime-check each op's `wasm_level` against the Wasm spec; `@compileError` on divergence from the spec definition.

### 7.10 Summary — What becomes physically impossible

| ID | Event made impossible |
|---|---|
| 7.1 | Wasm 2.0/3.0 code sneaking into a `-Dwasm=v1_0` build |
| 7.2 | Adding a new ZirOp tag without a per-op file |
| 7.3 | Changes in the direction of increasing skip-impl count (without an ADR) |
| 7.4 | Silently swallowing errors / escaping via fallback |
| 7.5 | Leaving / deleting spikes without recording results |
| 7.6 | Committing a sub-row [x] flip while exit criteria are unmet |
| 7.7 | Letting dispatch consistency (mismatches among the 3 file axes) slide |
| 7.8 | Writing progress narrative as prediction / fiction (live measurement only) |
| 7.9 | Attaching incorrect feature_level metadata to an op file |

Enter §9.12-B and beyond only after all of these are in a state where gate / lint / `@compileError` / audit fire (= they land in §9.12-A).

---

## Chapter 8 — Incremental workflow + spike operation

### 8.1 Role of spikes

- **Discovery**: localize unknown Zig 0.16 behaviour (e.g. the `inline switch` 581-tag wall), ABI details (the D-148 Codeberg #35343 family), and host-specific behaviour (the D-134 family)
- **Verification**: PoC for a design proposal (E2E check like `q3-build-option-dce-poc`)
- **Comparison**: cycle / size / maintainability comparison between alternative approaches (`q3-interp-dispatch-bench`)

Each spike is self-contained and disposable (= `private/spikes/<name>/`). When taken into production flip the spike Status to `merged-into-prod`; non-adoption requires `rejected` + a lesson (7.5 enforcement).

### 8.2 How to chunk the work

- 1 chunk = 1 op, or 1 layer migration, or 1 enforcement landing (small unit)
- On failure, pinpoint revert; never amend the same commit (per `/continue` LOOP.md discipline)
- Record "how far we got" in machine-readable form via the progress tracker yaml (7.8)
- handover quotes live measurement only; zero prediction (7.8 discipline)

### 8.3 Procedure for backing out a dead end

1. Decide whether it was a spike or real implementation
2. If spike: `Status: rejected` + land a lesson + delete
3. If real implementation: `git revert <chunk-sha>` to pinpoint-revert the commit
4. Add a `"rolled back, ADR-NNNN"` entry to the ratchet history (7.3)
5. Restart from a fresh spike with a different approach

### 8.4 What "spare no effort" means

- Do **not** attempt the "giving up" that the enforcement layer (Chapter 7) physically blocks
- Any movement toward compromise will be stopped at a gate → search for an alternate route via a spike
- Trying 3-5 spikes and adopting the best is acceptable
- "Just skip and move on" is **rejected by the substrate**

---

## Chapter 9 — Proposed approach + a state ready for the next /continue

### 9.1 Items completed in this session (autonomous setup)

1. Promote this master plan to `.dev/phase9_completion_master_plan.md` (git-tracked)
2. Expand ROADMAP §9 sub-rows (§9.12 / §9.12-pre / §9.12-A..I / §9.13-0 / §9.13)
3. Update Phase Status widget wording
4. Refresh handover.md so the next `/continue` can resume autonomously from §9.12-pre
5. Land **skeletons** for ADR-0070 / 0071 / 0072 / 0073 (Status: Proposed; Context + Decision placeholders; References) plus **amend skeletons** for ADR-0050 / ADR-0023 (new Revision history row + amend body draft) under `.dev/decisions/`
6. New rule **skeletons** under `.claude/rules/` (no_fallback_on_failure / spike_lifecycle / comment_as_invariant / libc_boundary / runtime_instance_layer / incremental_substrate_migration)
7. **Skeleton** of `.claude/skills/dispatch_consistency_audit/SKILL.md`
8. New enforcement script **skeletons** under `scripts/` (executable shebang + basic grep/check; full implementation lands during §9.12-A)
9. Seed `bench/results/skip_impl_history.yaml` with the current 243 baseline
10. Seed `.dev/p9_completion_progress.yaml` with the initial state
11. Update `phase9_completion_substrate_audit.md` with tentative Q3 C adoption (substrate audit close pending)
12. `private/notes/` housekeeping (keep older surveys; spike skeletons are created in the next session)

Commit units used in this session:

- **commit 1**: ADR skeletons (0070 / 0071 / 0072 / 0073 + 0050 / 0023 amend drafts)
- **commit 2**: master plan promote + ROADMAP §9.12 sub-row expansion + handover refresh + substrate audit doc update
- **commit 3**: enforcement scaffold (rules + skill + scripts + seed yaml skeletons)

### 9.2 Workflow the next session executes after `/continue`

1. Follow handover's Cold-start procedure and identify §9.12-pre as the active task
2. Start §9.12-pre — populate the ADR drafts (turn skeletons into real ADRs) and implement + measure the 3 spikes
3. After everything lands, fire the §9.12 collab gate → request Q2-Q6 + ADR Accept from the user
4. Once the user Accepts, §9.12-A onwards proceeds autonomously

### 9.3 Confidence

- Chapter 2 ground truth: HIGH (measured live)
- Chapter 3 Q3 C adoption: HIGH (beats alternatives on the design-quality axis)
- Chapter 4 DCE substrate arch: HIGH (to be demonstrated by spike `q3-build-option-dce-poc`)
- Chapter 5 sub-rows + deliverables: HIGH
- Chapter 6 ROADMAP amendments: HIGH (mechanical)
- Chapter 7 enforcement layer: HIGH (each item is an extension of an existing pattern — gate / rule / audit)
- Chapter 8 incremental workflow: HIGH (matches the existing /continue loop operation)
- Chapter 9 setup: HIGH (completed in this session)

---

## Chapter 10 — References

### 10.1 Work files (gitignored, under private/)

- `private/notes/p9-close-bench-survey.md` (v1 + OSS bench infra)
- `private/notes/p9-close-q3-arch-survey.md` (Q3 hypotheses vs OSS, 942 lines)
- `private/notes/p9-close-skip-impl-inventory.md` (breakdown of 243 skip-impl)
- `private/notes/p9-close-inventory.md` (debt + ADR + scaffolding)
- `private/notes/p9-close-phase10-readiness.md` (C API / build flags / ZirOp)
- `private/notes/p9-close-master-design.md` (first draft)
- `private/notes/p9-close-self-review.md` (self-review)
- `private/notes/p9_close_master_plan_ja_v1.md` (v1 = older plan)
- `private/notes/p9_close_master_plan_ja.md` (this file as v2, pre-promote)

### 10.2 git-tracked targets (landed in this session)

- `.dev/phase9_completion_master_plan.md` (committed version of this plan)
- `.dev/ROADMAP.md` (§9 sub-rows + Phase Status widget)
- `.dev/handover.md` (§9.12-pre cold-start)
- `.dev/decisions/0070_libc_dependency_policy.md` (skeleton)
- `.dev/decisions/0071_phase9_substrate_audit_resolution.md` (skeleton)
- `.dev/decisions/0072_comment_as_invariant_rule.md` (skeleton)
- `.dev/decisions/0073_build_option_dce_substrate.md` (skeleton)
- `.dev/phase9_completion_substrate_audit.md` (Q3 C tentative update)
- `.claude/rules/no_fallback_on_failure.md` (skeleton)
- `.claude/rules/spike_lifecycle.md` (skeleton)
- `.claude/rules/comment_as_invariant.md` (skeleton)
- `.claude/rules/libc_boundary.md` (skeleton)
- `.claude/rules/runtime_instance_layer.md` (skeleton)
- `.claude/rules/incremental_substrate_migration.md` (skeleton)
- `.claude/skills/dispatch_consistency_audit/SKILL.md` (skeleton)
- `scripts/check_build_dce.sh` (skeleton, executable)
- `scripts/check_skip_impl_ratchet.sh` (skeleton)
- `scripts/check_fallback_patterns.sh` (skeleton)
- `scripts/check_subrow_exit.sh` (skeleton)
- `scripts/check_libc_boundary.sh` (skeleton)
- `scripts/p9_completion_status.sh` (skeleton)
- `bench/results/skip_impl_history.yaml` (seed; current 243 baseline)
- `.dev/p9_completion_progress.yaml` (initial state)

### 10.3 Existing references

- `.dev/ROADMAP.md` (Phase Status widget near line 1175; §9.12 sub-row table around 1665+)
- `.dev/phase9_completion_substrate_audit.md` (Q2-Q6 question details; ADR-0062 anchor)
- `.dev/phase10_transition_gate.md` (§9.13 hard gate doc)
- `.dev/debt.md` (28 active rows; 6 in `now` status)
- ADR-0023 (src directory structure; §4.5 amend candidate)
- ADR-0029 (skip-impl/skip-adr semantics)
- ADR-0050 (ADR lifecycle / Status canonical)
- ADR-0056 (Phase 9 scope extension)
- ADR-0062 (substrate audit gate anchor)
- ADR-0065 (Wasm 1.0 instance work Phase 9 rescope)
