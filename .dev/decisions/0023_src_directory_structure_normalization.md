# 0023 — Normalise src/ directory structure and naming

- **Status**: Accepted
- **Date**: 2026-05-04
- **Author**: Shota / structural drift inventory + Q1-Q10 design dialogue
- **Tags**: roadmap, refactor, naming, structure, modularity, phase7

## Context

zwasm v2's current `src/` directory layout has drifted significantly
from ROADMAP §4.5 / §5 plans, and several decisions have been made
ad-hoc during Phase 1-7 implementation rather than re-evaluated
against the project's design principles. Concretely:

- `src/feature/` was planned as the home for per-spec-feature
  dispatch-table registration (§4.5), but the implementation flowed
  the opposite direction into `src/interp/ext_2_0/`. `src/feature/`
  contains a single near-empty file (`mvp/mod.zig`).
- `src/runtime/` was planned to contain 11 files (Module / Instance
  / Store / Engine / Memory / Table / Global / Trap / Float / Value
  / GC), but only 2 files materialised (`diagnostic.zig` /
  `jit_abi.zig`). The Runtime struct and most runtime-state types
  live scattered across `interp/mod.zig`, `frontend/parser.zig`,
  and `c_api/instance.zig`.
- `src/c_api/instance.zig` reached 2216 LOC, violating ROADMAP §A2
  hard cap (2000 LOC) without an ADR.
- `src/jit/` and `src/jit_arm64/` sit flat side-by-side; the
  shared / arch-specific relationship is not visible from naming.
- `src/util/` contains only `dbg + leb128` and is otherwise a
  semantically vacuous bucket.
- `src/c_api_lib.zig` (a top-level file) sits adjacent to
  `src/c_api/` (a directory) in an unusual two-level mixing.

The post-mortem of how these drifts accumulated is captured in
`private/2026-05-04-naming-and-structure-drift-inventory.md`.
ROADMAP §5 was a planning-time prediction that did not survive
contact with implementation; if left unchanged it will compound
when Phase 8 introduces x86_64 emit, AOT, GC, EH, threads, and
later proposals.

This ADR redefines the `src/` final shape, drawing on:

- WASM Core Specification §4.2 (Runtime Structure) and §5.4
  (Instructions) for runtime-state and instruction-category
  vocabulary
- WebAssembly/<proposal-name> repo names as the canonical
  reference for proposal subsystem naming
- wasm-c-api `wasm.h` types as the canonical reference for the C
  ABI surface
- LLVM `lib/CodeGen/` and Cranelift `cranelift/codegen/` as the
  industry idiom for the code-generation subtree
- ClojureWasmFromScratch's "see the final shape on day 1"
  principle (CW v2 P2)
- Build-flag granularity expected for v0.1.0+ (per-Wasm-version,
  per-engine, per-feature, per-WASI-level toggles)

## Decision

### Design principles

The following principles are adopted as the rationale for every
naming and placement choice in this ADR, and are referenced by
subsequent ADRs that touch directory structure.

- **P-A Single source of truth**: each concept lives in exactly
  one location under `src/`.
- **P-B Pipeline visibility**: the compiler pipeline (parse →
  validate → IR → analyze → {interp | codegen} → execute) is
  readable directly from the directory hierarchy.
- **P-C Engine sibling parity**: execution engines (interp,
  codegen-arm64, codegen-x86_64, codegen-aot) are placed as
  siblings at one hierarchy level; no one engine is structurally
  privileged over another.
- **P-D Vertical slicing for VM-capability extensions**:
  subsystems that introduce new runtime-state types, new
  type-system axes, ABI changes, or wholesale changes to JIT
  output shape are placed under `feature/<X>/` as
  self-contained subtrees.
- **P-E Horizontal slicing for stateless opcode additions**:
  opcode families that add new instructions but do not change
  the VM's capability model live under
  `instruction/wasm_X_Y/<category>.zig`.
- **P-F Naming non-redundancy**: parent directory names are not
  repeated in file names. Exception: package representative
  files (`runtime/runtime.zig`, `instance/instance.zig`) are
  permitted as a Zig idiom.
- **P-G Vague bucket prohibition**: parent directory names like
  `util/`, `helpers/`, `common/`, `misc/`, `lib/`, `core/` are
  forbidden. `support/` is permitted only for a small number of
  specific helper files when no more specific home exists.
- **P-H Future-state accommodation**: directories for subsystems
  that will land in Phase 8-16 (AOT, GC, EH, threads,
  stack_switching, Component Model, etc.) are reserved at
  structure-confirmation time. Reserved directories contain only
  a `README.md` naming the target Phase.
- **P-I Cross-cutting concerns get their own dir**: diagnostics
  and tracing-style cross-cutting concerns are placed in their
  own top-level directory, following Ousterhout's deep-module
  principle (small interface, large implementation, used
  everywhere).
- **P-J Build-flag mappable structure**: directory hierarchy
  maps 1:1 with build flags (`-Dwasm`, `-Dengine`, `-Daot`,
  `-Denable=<feature>`, `-Dwasi`, `-Dapi`) such that a single
  flag setting excludes a single subtree from the build.
- **P-K WASM/WASI industry-vocabulary alignment**: directory
  and file names take the WASM Core Spec / wasm-c-api / WASI /
  WebAssembly/<proposal-name> vocabulary as the default. Length
  yields to explicitness; opaque abbreviations (e.g. `eh`, `p1`)
  are forbidden in favour of the official full name. Industry-
  conventional short names (e.g. `gc`) are permitted.

### Naming reference table

| Concept | Source | zwasm naming |
|---|---|---|
| Instructions (§5.4) — 8 categories | WASM Core Spec | `instruction/wasm_X_Y/<category>.zig` |
| Numeric / Reference / Vector / Parametric / Variable / Table / Memory / Control | §5.4 sub-section titles | `wasm_1_0/` file-name axis |
| Runtime Structure (§4.2) | WASM Core Spec | `runtime/` subtree |
| Module / Module Instance / Memory Instance / Table Instance / Global Instance / Function Instance / Store / Frame | §4.2 | `runtime/` + `runtime/instance/*.zig` |
| Trap | §4.4 | `runtime/trap.zig` |
| Engine / Store / Module / Instance / Trap / Func / Memory / Table / Global / Val | wasm-c-api `wasm.h` | `runtime/{engine, store, module, value, trap}.zig` + `runtime/instance/*.zig` |
| WASI preview1 | WASI 0.1 spec | `wasi/preview1.zig` (full official name) |
| Sign Extension Operations | proposal: WebAssembly/sign-extension-ops | `instruction/wasm_2_0/sign_extension.zig` |
| Non-trapping Float-to-Int | proposal: WebAssembly/nontrapping-float-to-int-conversions | `instruction/wasm_2_0/nontrap_conversion.zig` |
| Multi-value | proposal: WebAssembly/multi-value | `instruction/wasm_2_0/multi_value.zig` |
| Bulk Memory | proposal: WebAssembly/bulk-memory-operations | `instruction/wasm_2_0/bulk_memory.zig` |
| Reference Types | proposal: WebAssembly/reference-types | `instruction/wasm_2_0/reference_types.zig` |
| SIMD-128 | proposal: WebAssembly/simd | `feature/simd_128/` (vertical) |
| Garbage Collection | proposal: WebAssembly/gc | `feature/gc/` (industry-conventional 2-letter short name) |
| Exception Handling | proposal: WebAssembly/exception-handling | `feature/exception_handling/` (full name) |
| Tail Call | proposal: WebAssembly/tail-call | `feature/tail_call/` |
| Function References | proposal: WebAssembly/function-references | `feature/function_references/` (full name) |
| memory64 | proposal: WebAssembly/memory64 | `feature/memory64/` |
| Threads | proposal: WebAssembly/threads | `feature/threads/` (reserved) |
| Stack Switching | proposal: WebAssembly/stack-switching | `feature/stack_switching/` (reserved) |
| Component Model | proposal: WebAssembly/component-model | `feature/component/` (reserved) |
| Extended Const | proposal: WebAssembly/extended-const | `instruction/wasm_3_0/extended_const.zig` (no new opcodes; doc-comment-only file) |
| Relaxed SIMD | proposal: WebAssembly/relaxed-simd | `feature/simd_128/relaxed.zig` (folded into SIMD subsystem) |
| Wide Arithmetic | proposal: WebAssembly/wide-arithmetic | `instruction/wasm_3_0/wide_arith.zig` |
| Custom Page Sizes | proposal: WebAssembly/custom-page-sizes | `instruction/wasm_3_0/custom_page_sizes.zig` |

File names are derived by taking the official `WebAssembly/<proposal-name>`
repo slug and replacing `-` with `_` (snake_case per §A11).

### The src/ tree

```
src/
│
├── parse/                      WASM Binary Format → structured Module
│   ├── parser.zig              top-level parse driver
│   ├── sections.zig            type / function / import / global / table / data / element decoders
│   └── ctx.zig                 ParseContext (was parse_ctx.zig)
│
├── validate/                   static validation (type stack + control stack)
│   └── validator.zig           validation rules (production > 800 LOC permits _tests.zig split)
│
├── ir/                         Zwasm Intermediate Representation + analysis passes
│   ├── zir.zig                 ZirOp catalogue + ZirInstr + ZirFunc
│   ├── dispatch.zig            DispatchTable type (was ir/dispatch_table.zig; redundant prefix dropped)
│   ├── lower.zig               wasm-op → ZirOp lowering (was frontend/lowerer.zig)
│   ├── verifier.zig            ZIR.verify(); invoked after every analysis pass
│   └── analysis/
│       ├── loop_info.zig       branch_targets / loop_headers / loop_end
│       ├── liveness.zig        per-vreg live ranges
│       └── const_prop.zig      bounded const folding
│
├── runtime/                    WASM Spec §4.2 "Runtime Structure" — host-side state types
│   ├── runtime.zig             Runtime central handle: { io, gpa, engine, stores, config, vtable }
│   ├── engine.zig              Engine (wasm-c-api wasm_engine_t)
│   ├── store.zig               Store (wasm-c-api wasm_store_t; Instance container)
│   ├── module.zig              parsed Module (migrated from frontend/parser.zig's Module struct)
│   ├── value.zig               Value extern union (i32 / i64 / f32 / f64 / funcref / externref)
│   ├── trap.zig                Trap (zwasm-internal; api/trap_surface.zig marshals to wasm_trap_t)
│   ├── frame.zig               Frame (call frame: locals + operand stack + return PC + parent)
│   └── instance/               WASM Spec §4.2 "Instances" — instance-side runtime state
│       ├── instance.zig        Instance (instantiated module, container; absorbs the post-split body of c_api/instance.zig 2216 LOC)
│       ├── memory.zig          Memory Instance + memory.copy / fill / init helpers
│       ├── table.zig           Table Instance + table.copy / init / fill helpers
│       ├── global.zig          Global Instance
│       ├── func.zig            FuncEntity (ADR-0014 §6.K.1: instance-bearing funcref)
│       ├── element.zig         Element segment state (table.init / elem.drop target)
│       └── data.zig            Data segment state (memory.init / data.drop target)
│
├── instruction/                WASM Spec §5.4 instruction categories — stateless opcode implementations
│   ├── wasm_1_0/               Wasm 1.0 MVP — file axis follows §5.4 sub-section titles
│   │   ├── numeric_int.zig     i32 / i64 const + ALU + cmp + bit
│   │   ├── numeric_float.zig   f32 / f64 const + arith + cmp
│   │   ├── numeric_conversion.zig wrap / extend / trunc / convert / promote / demote / reinterpret
│   │   ├── parametric.zig      drop / select / select_typed
│   │   ├── variable.zig        local.get / set / tee + global.get / set
│   │   ├── memory.zig          load / store + memory.size / grow (32-bit; 64-bit lives in feature/memory64/)
│   │   └── control.zig         unreachable / nop / block / loop / if / else / end / br / br_if / br_table / return / call / call_indirect
│   │
│   ├── wasm_2_0/               Wasm 2.0 released — file axis follows proposal names (the spec history before 2.0 had no proposal granularity)
│   │   ├── sign_extension.zig  i32.extend8_s / 16_s / i64.extend{8, 16, 32}_s
│   │   ├── nontrap_conversion.zig i32 / i64 .trunc_sat_f32 / f64 _s / _u
│   │   ├── multi_value.zig     blocktype extension (mostly metadata)
│   │   ├── bulk_memory.zig     memory.copy / fill / init / data.drop / table.copy / init / elem.drop
│   │   └── reference_types.zig ref.null / is_null / func / table.get / set / size / grow / fill
│   │
│   └── wasm_3_0/               Wasm 3.0 simple ops (state-less)
│       ├── extended_const.zig  no new opcodes (const expression extension only); doc-comment-only file
│       ├── wide_arith.zig      i64.add128 / sub128 / mul_wide_s / _u
│       └── custom_page_sizes.zig memory.discard + memarg page-size variant
│
├── feature/                    VM capability extensions — subsystems with new state, new type-system axes, ABI changes, or JIT-shape changes
│   ├── simd_128/               SIMD-128 (Wasm 2.0; relaxed_simd folded in)
│   │   ├── register.zig        register entry: pub fn register(*DispatchTable)
│   │   ├── ops.zig             v128 ops (load / store / splat / lane / arith / cmp / conv)
│   │   ├── register_class.zig  v128 register class (NEON / SSE4.1; independent of GPR / FPR)
│   │   ├── lane.zig            lane shuffle / extract / replace primitives
│   │   ├── nan_propagation.zig f32x4 / f64x2 NaN propagation per Wasm spec
│   │   ├── relaxed.zig         relaxed-simd ops (Wasm 3.0 addition)
│   │   ├── arm64.zig           NEON emit
│   │   └── x86_64.zig          SSE4.1 emit
│   │
│   ├── gc/                     Wasm 3.0 — managed heap
│   │   ├── register.zig
│   │   ├── ops.zig             struct.* / array.* / ref.test / ref.cast / ref.i31 / i31.get_*
│   │   ├── heap.zig            HeapHeader + 8-byte aligned tagged pointer
│   │   ├── arena.zig           initial arena tier (bulk free; later folded into mark_sweep)
│   │   ├── mark_sweep.zig      mark-sweep collector
│   │   ├── roots.zig           root set (operand stack + locals + globals + tables)
│   │   ├── type_hierarchy.zig  struct / array subtyping + recursive types
│   │   ├── arm64.zig
│   │   └── x86_64.zig
│   │
│   ├── exception_handling/     Wasm 3.0 — structured non-local control
│   │   ├── register.zig
│   │   ├── ops.zig             try_table / throw / throw_ref
│   │   ├── tag.zig             Exception tag (type + signature)
│   │   ├── unwind.zig          frame unwinding mechanism
│   │   ├── landing_pad.zig     JIT landing-pad metadata
│   │   ├── arm64.zig
│   │   └── x86_64.zig
│   │
│   ├── tail_call/              Wasm 3.0 — tail-call optimisation
│   │   ├── register.zig
│   │   ├── ops.zig             return_call / return_call_indirect / return_call_ref
│   │   ├── frame_replace.zig   interp-side frame replacement
│   │   ├── arm64.zig           epilogue variant emit
│   │   └── x86_64.zig
│   │
│   ├── function_references/    Wasm 3.0 — typed function references + null tracking
│   │   ├── register.zig
│   │   ├── ops.zig             call_ref / ref.as_non_null / br_on_null / br_on_non_null
│   │   ├── typed_ref.zig       typed function reference representation
│   │   ├── null_tracking.zig   validator extension (nullable vs non-null)
│   │   ├── arm64.zig
│   │   └── x86_64.zig
│   │
│   ├── memory64/               Wasm 3.0 — 64-bit memory addressing
│   │   ├── register.zig
│   │   ├── ops.zig             memarg.is_64 dispatched load / store / grow / size
│   │   ├── bounds_check_64.zig 64-bit bounds check primitive
│   │   ├── arm64.zig
│   │   └── x86_64.zig
│   │
│   ├── threads/                Phase 4 proposal, post-v0.2.0 — reserved slot
│   │   └── README.md
│   │
│   ├── stack_switching/        Phase 3 proposal, post-v0.2.0 — reserved slot
│   │   └── README.md
│   │
│   └── component/              Component Model — reserved slot
│       └── README.md
│
├── engine/                     engine sibling parity (interp / codegen-{arm64, x86_64, aot})
│   ├── runner.zig              public entry: invokes ZirFunc via runtime.vtable; dispatches to interp or codegen (was jit/run_wasm.zig + interp/mvp.invoke)
│   │
│   ├── interp/                 threaded-code interpreter
│   │   ├── loop.zig            dispatch loop (was dispatch.zig; renamed to avoid collision with ir/dispatch.zig)
│   │   └── trap_audit.zig      trap detection audit machinery
│   │
│   └── codegen/                JIT + AOT shared compiler pipeline
│       ├── shared/             arch-neutral codegen infrastructure
│       │   ├── regalloc.zig    greedy-local + spill (ADR-0018)
│       │   ├── reg_class.zig   GPR / FPR / SIMD / inst_ptr / vm_ptr / simd_base classification
│       │   ├── linker.zig      BL fixup patcher
│       │   ├── compile.zig     per-function compile orchestrator (was jit/compile_func.zig)
│       │   ├── entry.zig       call gate into JIT-compiled code
│       │   ├── prologue.zig    arch-iface trait + concrete dispatch
│       │   └── jit_abi.zig     JitRuntime ABI offsets (ADR-0017; was runtime/jit_abi.zig)
│       │
│       ├── arm64/              ARM64 emit (Mac aarch64)
│       │   ├── emit.zig        orchestrator (post-7.5d ≤ 1000 LOC)
│       │   ├── op_const.zig    one of the 7.5d sub-b 9-module split
│       │   ├── op_alu.zig      i32 / i64 ALU + comparisons + shifts
│       │   ├── op_memory.zig   load / store + memory.size / grow + bounds check
│       │   ├── op_control.zig  block / loop / br / br_table / if / else / end + D-027 merge logic
│       │   ├── op_call.zig     call + call_indirect + arg / result marshal
│       │   ├── bounds_check.zig f32 / f64 → i32 / i64 bounds check primitives
│       │   ├── inst.zig        instruction encoder primitives
│       │   ├── abi.zig         AAPCS64 calling convention tables
│       │   ├── prologue.zig    ARM64 prologue layout helper (ADR-0021 sub-a)
│       │   └── label.zig       Label / Fixup / FixupKind / merge_top_vreg
│       │
│       ├── x86_64/             x86_64 emit (Linux / Windows) — implementation begins at Phase 7.6
│       │   ├── emit.zig        orchestrator (mirrors arm64/ shape)
│       │   ├── op_const.zig
│       │   ├── op_alu.zig
│       │   ├── op_memory.zig
│       │   ├── op_control.zig
│       │   ├── op_call.zig
│       │   ├── bounds_check.zig
│       │   ├── inst.zig
│       │   ├── abi.zig         System V (Linux) + Win64 (Windows) calling conventions
│       │   ├── prologue.zig
│       │   └── label.zig
│       │
│       └── aot/                AOT — Phase 8+ skeleton, Phase 12 finalisation
│           ├── format.zig      .cwasm header + serialization format
│           └── linker.zig      AOT relocation
│
├── wasi/                       WASI preview1 implementation
│   ├── preview1.zig            preview1 entry + register (was p1.zig; full official name)
│   ├── host.zig                capability table (preopens / args / environ via std.process.Init)
│   ├── fd.zig                  fd_read / write / close / seek / tell + path_open + fdstat
│   ├── clocks.zig              clock_time_get + random_get + poll_oneoff
│   └── proc.zig                proc_exit + args_get / sizes_get + environ_get / sizes_get
│
├── api/                        wasm-c-api compatible C ABI (was c_api/)
│   ├── wasm.zig                wasm.h impl: wasm_engine_* / wasm_store_* / wasm_module_* / wasm_instance_* / wasm_func_*
│   ├── wasi.zig                wasi.h impl (wasm-c-api compatible WASI extension)
│   ├── zwasm.zig               zwasm.h ext: allocator inj / fuel / timeout / cancel / fast invoke
│   ├── vec.zig                 wasm_*_vec_t lifecycle helpers
│   ├── trap_surface.zig        Trap → wasm_trap_t marshal
│   └── cross_module.zig        cross-module funcref dispatch
│
├── cli/                        CLI subcommands + Juicy Main (CLI exe entry)
│   ├── main.zig                CLI exe entry; receives std.process.Init (per ADR-0024 D-4)
│   ├── run.zig                 zwasm run <wasm-file>
│   ├── compile.zig             zwasm compile (Phase 12)
│   ├── validate.zig            zwasm validate
│   ├── inspect.zig             zwasm inspect
│   ├── features.zig            zwasm features
│   ├── wat.zig                 zwasm wat (Phase 11)
│   ├── wasm.zig                zwasm wasm (Phase 11)
│   └── diag_print.zig          render Diagnostic to terminal output
│
├── platform/                   OS abstractions
│   ├── jit_mem.zig             RWX memory: mmap (POSIX) / VirtualAlloc (Windows)
│   ├── signal.zig              Phase 7+: SIGSEGV → trap conversion
│   ├── fs.zig                  Phase 11: WASI fs adapter
│   └── time.zig                WASI 0.1 clock adapter
│
├── diagnostic/                 cross-cutting (Ousterhout deep module)
│   ├── diagnostic.zig          threadlocal Diag + setDiag / clearDiag (was runtime/diagnostic.zig)
│   └── trace.zig               Phase 7+: trace ringbuffer per ADR-0016 M3
│
├── support/                    minimal specific helpers
│   ├── dbg.zig                 dev-only logger (current name retained; intent is "debug print only")
│   └── leb128.zig              encoding helper (used by parse + codegen/aot; neutral position)
│
└── zwasm.zig                   library root + zone re-export hub + self-import surface (per ADR-0024 D-1/D-2). Used as `core.root_source_file` for libzwasm.a (and future shared/wasm libs); CLI exe imports it via `addImport("zwasm", core)`.
```

`feature/<X>/register.zig` exposes `pub fn register(*DispatchTable)`.
The function registers the feature's opcode implementation pieces
(parser hook / validator hook / interp handler / arm64 emit /
x86_64 emit) into the central DispatchTable.

`instruction/wasm_X_Y/<category>.zig` likewise carries
`pub fn register(*DispatchTable)`.

`extended_const.zig` and similar files for proposals that add no
new opcodes are doc-comment-only files (Zig allows source files
containing only a `//!` module-level comment with no
declarations).

### Build flag mapping (P-J)

| Build flag | Excluded subtree |
|---|---|
| `-Dwasm=1.0` | `instruction/wasm_2_0/`, `instruction/wasm_3_0/`, `feature/{simd_128, gc, exception_handling, tail_call, function_references, memory64}/` |
| `-Dwasm=2.0` | `instruction/wasm_3_0/`, `feature/{gc, exception_handling, tail_call, function_references, memory64}/` (simd_128 stays included) |
| `-Dwasm=3.0` (default) | nothing |
| `-Dengine=interp` | `engine/codegen/` entire subtree |
| `-Dengine=jit` | `engine/interp/` |
| `-Dengine=both` (default) | nothing |
| `-Daot=true` | (includes) `engine/codegen/aot/` |
| `-Daot=false` (current default) | `engine/codegen/aot/` |
| `-Denable=<feature>` | per-feature toggle within `feature/` |
| `-Dwasi=preview1` (default) | nothing |
| `-Dwasi=none` | `wasi/`, `platform/{fs, time}.zig` |
| `-Dapi=c` (default) | nothing |
| `-Dapi=none` | `api/` |

Each `feature/<X>/register.zig` reads build flags at comptime
and may no-op `register(*DispatchTable)` when the feature is
excluded. Concrete `build.zig` wiring (per-module comptime
exclude / addModule branching) is decided at implementation
time.

### ROADMAP amendments

In the same commit that lands this ADR, the following ROADMAP
sections are amended in place per §18.2:

| ROADMAP section | Change |
|---|---|
| §4.1 (Four-zone layered) | Path overhaul: `interp / jit / jit_arm64 / wasi / c_api` → `engine/{interp, codegen}, wasi, api`, etc. |
| §4.2 (ZIR catalogue) | No change (still `ir/zir.zig`) |
| §4.3 (engine pipeline) | Pipeline diagram redrawn with new paths |
| §4.4 (wasm-c-api ABI) | `c_api/*` → `api/*` |
| §4.5 (feature modules) | Replaced with the instruction/ vs feature/ two-level model from this ADR |
| §4.7 (Runtime handle) | Path: `interp/mod.zig:Runtime` → `runtime/runtime.zig:Runtime` |
| §4.10 (GC subsystem) | `runtime/gc/` → `feature/gc/` (vertical aggregation) |
| §5 (directory layout) | Replaced with the tree from this ADR |
| §A1 (Zone deps) | Zone count remains 4; internal path strings updated |
| §A2 (file size) | Add tests-split rubric: production code ≤ 800 LOC requires inline tests; production > 800 LOC with combined > 1000 LOC permits `<file>_tests.zig` split; production > 2000 LOC is a §A2 hard-cap violation requiring an ADR |
| §A3 (cross-arch ban) | `jit_arm64 ↔ jit_x86` → `engine/codegen/arm64 ↔ engine/codegen/x86_64` |
| §A11 (snake_case) | No change |
| §14 (forbidden) | No change |
| §15 (future decisions) | Phase 7 end-of-phase Phase 8 / 11 / 13 ordering question is re-evaluated after this ADR lands |

The §A2 rubric for tests-split is finalised by this ADR.
`scripts/file_size_check.sh` updates to enforce the split
boundary are tracked separately as implementation work.

### Implementation order

The work items below are listed in dependency order. Commit
granularity, three-host gate timing, and intermediate sequencing
are decided at implementation time; the count of items is not
the count of commits.

1. Land this ADR + ROADMAP amendments (§4.1, §4.2, §4.3, §4.4,
   §4.5, §4.7, §4.10, §5, §A1, §A2, §A3) in one commit per
   §18.2 four-step.
2. Evict the existing `runtime/` files: `runtime/diagnostic.zig`
   → `diagnostic/diagnostic.zig`; `runtime/jit_abi.zig` →
   `engine/codegen/shared/jit_abi.zig`.
3. Create `runtime/runtime.zig`, extracting the Runtime struct
   from `interp/mod.zig`. `interp/mod.zig` shrinks to a thin
   entry.
4. Create `runtime/{module, value, trap, frame, engine, store}.zig`
   by extracting concepts from frontend / interp / c_api.
5. Create `runtime/instance/instance.zig` by splitting the
   2216-LOC `c_api/instance.zig`. The instance struct and
   instantiation logic move into `runtime/instance/instance.zig`;
   the wasm-c-api binding layer stays in `api/wasm.zig` (or
   `api/instance_binding.zig` if the binding warrants its own
   file).
6. Create `runtime/instance/{memory, table, global, func, element,
   data}.zig` by extracting the per-instance types.
7. Create `parse/`, `validate/`, `ir/analysis/` by dismantling
   the legacy `frontend/`: parser / sections / ctx → `parse/`;
   validator → `validate/`; lowerer → `ir/lower.zig`; loop_info
   / liveness / const_prop → `ir/analysis/`.
8. Create `instruction/{wasm_1_0, wasm_2_0, wasm_3_0}/` by
   relocating the legacy `interp/{mvp_*.zig, ext_2_0/}` content.
   `extended_const.zig` is placed as a doc-comment-only file.
9. Create the `feature/` skeleton: 6 active subsystems
   (`simd_128, gc, exception_handling, tail_call,
   function_references, memory64`) and 3 reserved slots
   (`threads, stack_switching, component`). Reserved slots
   contain only `README.md` naming the target Phase. v0.1.0 has
   no existing v2 SIMD code — `feature/simd_128/register.zig`
   is a stub only; full SIMD implementation lands in a future
   Phase per ROADMAP §11.
10. Create `engine/{runner.zig, interp/, codegen/{shared, arm64,
    x86_64, aot}/}`: relocate `jit/*` → `engine/codegen/shared/`;
    `jit_arm64/*` → `engine/codegen/arm64/`; `interp/{dispatch,
    trap_audit}.zig` → `engine/interp/{loop, trap_audit}.zig`.
    Create `engine/runner.zig` consolidating the previous
    `jit/run_wasm.zig` and `interp/mvp.invoke` entries.
11. Create `api/`: relocate `c_api/*` and rename per the table:
    `c_api/wasm_c_api.zig` → `api/wasm.zig`; the binding-layer
    residue from `c_api/instance.zig` (after step 5) goes to
    `api/wasm.zig` or `api/instance_binding.zig`; `c_api_lib.zig`
    deleted (its comptime force-include role is subsumed by
    the new `src/zwasm.zig` library root per ADR-0024 D-2; the
    rename mentioned in the original §7 item 11 text is
    superseded).
12. Reorganise `cli/`: `cli/diag_print.zig` is retained;
    `compile.zig`, `wat.zig`, `wasm.zig` slots are created with
    placeholder bodies for Phase 11 / 12.
13. Rename `wasi/p1.zig` → `wasi/preview1.zig` and update
    references.
14. Extend `platform/` with `signal.zig`, `fs.zig`, `time.zig`
    slots (placeholder bodies for Phase 7+ / Phase 11
    landing).
15. Establish `diagnostic/` and `support/`: `util/dbg.zig` →
    `support/dbg.zig`; `util/leb128.zig` → `support/leb128.zig`;
    `runtime/diagnostic.zig` → `diagnostic/diagnostic.zig`
    (already covered by step 2). `cli/diag_print.zig` stays in
    `cli/`.
16. Move `src/jit_arm64/emit.zig` (verbatim, the 4008-LOC
    monolith) to `src/engine/codegen/arm64/emit.zig` as part of
    item 10's relocation. Move
    `src/jit_arm64/{abi, inst, prologue}.zig` likewise.
    Relativise the remaining ~128 byte-offset test sites in the
    relocated `emit.zig` using the existing `prologue.zig` helper
    (this is the bulk completion of ADR-0021 row 7.5d sub-a, which
    landed only 4 demonstration sites). The 9-module content
    split (ADR-0021 row 7.5d sub-b) follows in a **separate task
    after 7.5e closes**, on the new path. Do not perform the
    content split inside 7.5e — that conflates the structural
    reorg with the file-content refactor.
17. Sync `handover.md` and update path citations in related
    ADRs (ADR-0017 / 0018 / 0019 / 0021).
18. Sweep the codebase for stale references and update
    `scripts/zone_check.sh` to recognise the new path
    structure.

The three-host gate (Mac native + OrbStack Ubuntu + windowsmini
SSH) is run at appropriate boundaries to keep blast radius
manageable. Big-bang commits are forbidden.

## Alternatives considered

### Alternative A — Pipeline-First (compiler-textbook layout)

Place all opcode handlers under `interp/handler/<wasm_X_Y>/<category>.zig`
flat, with no vertical `feature/` directory. The compiler
pipeline (parse → validate → ir → engine) maps to dirs
straightforwardly.

**Why rejected**: P-D is sacrificed. State-heavy subsystems
(GC, EH, threads) would have to spread their state across
multiple pipeline-stage directories — heap.zig in some
`feature_state/`, ops handlers in `interp/handler/` and
`codegen/<arch>/op_*.zig`. The cross-cutting nature of these
subsystems is exactly what `feature/<X>/` exists to localise.

### Alternative B — Feature-First (vertical-only)

Realise ROADMAP §4.5's vertical idea fully: every feature
(including stateless ones like sign_extension and sat_trunc)
gets its own `feature/<f>/` subtree with parser /
validator / interp / arm64 / x86_64 files. No `instruction/`
directory.

**Why rejected**: stateless opcode families with 3-10 ops would
get 4-5 thin files each (20-50 LOC apiece), exploding the file
count to 100+ for marginal benefit. The vertical-everywhere
discipline does not pay off when there is no per-feature state
or type-system extension.

### Alternative C — Engine-First (wasmtime-like)

Each engine (interp, codegen-arm64, codegen-x86_64, codegen-aot)
is a self-contained subtree with its own per-feature handlers
inside (e.g. `engine/codegen/arm64/op_simd.zig`,
`engine/interp/handler/ext_2_0.zig`). State-heavy subsystems
get a separate `feature_state/` directory.

**Why rejected**: Wasm 2.0 SIMD and similar cross-engine
subsystems would split across three locations
(`engine/jit/arm64/op_simd.zig`,
`engine/interp/handler/ext_2_0.zig`, `feature_state/simd_lane/`).
The naming `feature_state/` is arbitrary — the only honest
basis for separating `feature/` from `feature_state/` is "does
it carry state?", which is exactly the criterion we use to
distinguish `feature/` from `instruction/` in the adopted
shape.

### Alternative E — Maximum Modularity (per-package isolation)

Treat each major component as an independently-publishable
package under `src/pkg/`, with `src/bin/zwasm.zig` and
`src/bin/zwasm_dylib.zig` assembling the entry points. Maximum
decoupling, suitable for a v0.2.0 ecosystem in which third
parties consume zwasm pieces.

**Why rejected**: over-engineered for v0.1.0. The single-binary
project does not need crate-like isolation today, and the
`pkg/` prefix obscures the natural directory hierarchy. Keep
this on file as a possible v0.2.0+ direction once an external
consumer materialises.

## Consequences

### Positive

- The ROADMAP §4.5 / §5 plan-vs-implementation drift is closed,
  and the ROADMAP itself is brought into alignment with the new
  shape (no aspirational text outliving the implementation).
- The `c_api/instance.zig` 2216-LOC §A2 hard-cap violation is
  discharged via the structural split, without requiring a
  separate ADR.
- The emit.zig 9-module split (ADR-0021 row 7.5d sub-b) lands
  naturally on the new path `engine/codegen/arm64/`, avoiding
  the rework that would be required by splitting first and
  relocating later.
- All Phase 8-16 future-state subsystems (`threads,
  stack_switching, component, aot, signal, fs, time`) have
  reserved slots, eliminating the temptation to invent ad-hoc
  homes for them.
- WASM-spec-vocabulary alignment lets new readers map directly
  between the WebAssembly Core Spec, proposal repos, and the
  zwasm source tree.
- Build flags map 1:1 with subtrees, making per-feature and
  per-engine binaries trivial to produce.
- The `runtime/{runtime, module, instance/instance}.zig` shape
  matches WASM Spec §4.2 directly; the location of every
  runtime-state type is unambiguous.

### Negative

- The structural change requires path-citation updates in all
  prior ADRs (ADR-0017 / 0018 / 0019 / 0021).
- Reserved slots under `feature/{threads, stack_switching,
  component}/` are README-only; their existence may mislead a
  reader into expecting implementations. Each reserved
  README.md must explicitly state "Phase N implementation;
  empty reserve".
- Within `instruction/`, `wasm_1_0/` uses §5.4 instruction
  category names while `wasm_{2,3}_0/` uses proposal names.
  This axis-shift across versions is a faithful reflection of
  the spec's history (proposal granularity did not exist
  pre-2.0) but is non-uniform and must be documented for
  future contributors.

### Neutral / follow-ups

- Each `feature/<X>/register.zig` carries the canonical
  `pub fn register(*DispatchTable)` entry. The contract is
  documented in the file's `//!` module-level comment.
- The §A2 tests-split rubric (production / tests size triggers)
  is finalised here. `scripts/file_size_check.sh` updates to
  enforce the new boundary follow as implementation work.
- The reserved `feature/component/` slot is a v0.2.0 target;
  Component Model implementation is not yet scoped.
- The exact split boundary between `runtime/instance/instance.zig`
  and `api/wasm.zig` (when dismantling the 2216-LOC
  `c_api/instance.zig`) is decided at implementation time:
  instantiation logic and instance lifetime move into the
  runtime side; wasm-c-api binding glue stays in the api side.

## References

- WebAssembly Core Specification §4.2 (Runtime Structure)
- WebAssembly Core Specification §5.4 (Instructions)
- wasm-c-api `wasm.h` (`include/wasm.h`)
- WASI preview1 spec
- WebAssembly proposal repos (sign-extension-ops, multi-value,
  bulk-memory-operations, reference-types, simd, gc,
  exception-handling, tail-call, function-references, memory64,
  threads, stack-switching, component-model, extended-const,
  relaxed-simd, wide-arithmetic, custom-page-sizes,
  nontrapping-float-to-int-conversions)
- LLVM `lib/CodeGen/` naming convention
- Cranelift `cranelift/codegen/` naming convention
- ClojureWasmFromScratch ROADMAP §5 / §P2 ("see the final shape on day 1")
- ADR-0014 (FuncEntity instance-bearing funcref)
- ADR-0017 (JitRuntime ABI)
- ADR-0018 (regalloc reserved set + spill)
- ADR-0019 (x86_64 in Phase 7)
- ADR-0021 (emit-split sub-gate)
- ROADMAP §4 / §5 / §A1 / §A2 / §A3 / §14 / §18

## §4.5 amend — per-op file migration plan (added 2026-05-19)

> Added by the 2026-05-19 Phase 9 completion substrate audit cycle, per
> ADR-0071 Q3 (Hypothesis C adoption) + ADR-0073 (all-layer build-option
> DCE substrate). This subsection extends the original §4.5 design
> (DispatchTable feature modules) with the per-op file pattern that
> §9.12-B implements.

### Sharpening of §4.5

The original ADR-0023 §3 reference table placed instruction handlers
at `instruction/wasm_X_Y/<category>.zig` (one file per category — `numeric.zig`,
`memory.zig`, `control.zig`, etc.). The 2026-05-19 substrate audit re-shapes
this to **`instruction/wasm_X_Y/<op>.zig` (one file per op)**, with each op file
exporting the canonical 5-axis handler aggregate:

```zig
// Canonical per-op file shape — src/instruction/wasm_X_Y/<op>.zig
const std = @import("std");
const ir = @import("../../ir.zig");
const WasmLevel = @import("../../build_options.zig").WasmLevel;

pub const op_tag: ir.ZirOp = .i32_add;
pub const wasm_level: WasmLevel = .v1_0;
pub const wasi_level: ?@import("../../build_options.zig").WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_i32_add,
    .lower    = lower_i32_add,
    .arm64    = emit_arm64_i32_add,
    .x86_64   = emit_x86_64_i32_add,
    .interp   = interp_i32_add,
};

fn validate_i32_add(ctx: *ValidatorCtx) !void { ... }
fn lower_i32_add(ctx: *LowerCtx) !void { ... }
fn emit_arm64_i32_add(ctx: *Arm64EmitCtx) !void { ... }
fn emit_x86_64_i32_add(ctx: *X86_64EmitCtx) !void { ... }
fn interp_i32_add(ctx: *InterpCtx) !void { ... }
```

The 4 dispatcher files (`validator.zig`, `lower.zig`,
`engine/codegen/arm64/emit.zig`, `engine/codegen/x86_64/emit.zig`)
become 5-line `inline switch` consumers (one per axis); the 5th axis
(`engine/interp/dispatch.zig`) is already in the central-table shape
and gains the same `inline switch + comptime filter` pattern.

### Source of truth: `dispatch_collector.zig`

A new file `src/ir/dispatch_collector.zig` is the single comptime
collector. It imports every op file at comptime, validates the
per-op-file completeness invariants (exported `op_tag` / `wasm_level` /
`handlers`; all 5 axes present; non-stub bodies), filters by
`build_options.wasm_level` / `wasi_level` / `enable_features`, and
returns the inline-switch dispatcher per axis.

```zig
// Sketch — src/ir/dispatch_collector.zig
pub fn dispatcher(comptime axis: AxisTag) AxisHandler(axis) {
    return struct {
        fn dispatch(op: ir.ZirOp, ctx: *AxisCtx(axis)) !void {
            return inline switch (op) {
                inline else => |tag| blk: {
                    const op_mod = comptime opModuleFor(tag);
                    if (comptime op_mod.wasm_level > build_options.wasm_level)
                        return error.UnsupportedOpForBuildLevel;
                    break :blk @field(op_mod.handlers, @tagName(axis))(ctx);
                },
            };
        }
    }.dispatch;
}
```

Build-option DCE works because the `comptime` guard at the head of each
inline arm is statically false for filtered-out ops; Zig 0.16 elides
the corresponding switch-arm body (verified by spike `q3-build-option-
dce-poc/`).

### Migration plan (per-op file landing, §9.12-B)

The migration from the current state (4 dispatcher monoliths × 581
arms each, plus the half-state `src/instruction/wasm_X_Y/<category>.zig`
files) to the per-op file shape proceeds in §9.12-B as follows:

1. **Bootstrap `dispatch_collector.zig`** with the comptime per-op-file
   completeness check. Initially the check `@compileError`s on every
   ZirOp because no op file exists yet. Land this in a single
   commit alongside the first migrated op (`i32_add`, the spike
   reference).
2. **Migrate ops in cohorts grouped by category** (existing
   `<category>.zig` content → N per-op files). Each cohort is one
   chunk; chunk close requires the cohort's ops to compile-and-pass
   under the new dispatch_collector path.
3. **Switch each dispatcher** (validator → lower → arm64 emit →
   x86_64 emit) to `dispatch_collector.dispatcher(...)` lookup once
   all ops are migrated. This is 4 small commits.
4. **Delete the legacy `src/instruction/wasm_X_Y/<category>.zig`
   files** in a sweep commit at §9.12-B close; the per-op files
   replace them.
5. **`src/feature/<feature>/register.zig`** — the placeholder
   feature modules remain in place but only carry the interp-axis
   `register()` (DispatchTable.interp population for runtime-late
   features like GC slot routing). validator / lower / emit axes
   for those features live in `src/instruction/wasm_X_Y/<op>.zig`
   (= the per-op files), not in `feature/`. This is the new
   division of labour.

The §9.12-B exit criterion includes "all 581 ZirOp tags have a
corresponding `src/instruction/wasm_X_Y/<op>.zig` file passing
`dispatch_collector.zig`'s comptime check". Phase 10's first Wasm
3.0 feature work then proceeds by adding files; no dispatcher edit
is needed.

### Why this differs from the original §3 reference-table

Original (2026-05-04): `instruction/wasm_X_Y/<category>.zig` with the
implicit assumption that each category file holds a `switch`
internally over ops in that category, called from the dispatcher.

Amended (2026-05-19): no category file. Each op gets its own file
(naming pattern `<op_lowercase>.zig`). The category-level grouping
exists only as a directory subdivision (optional) under
`wasm_X_Y/`, not as a code-bearing file. The original mistake was
treating "category" as a code-organisation unit; "op" is the right
unit because it matches the 5-axis-per-op concept and gives 1-file =
1-op = full lifecycle visibility.

### Per-axis zone resolution — ADR-0074 (added 2026-05-19, §9.12-B / B9)

The "1-file = 1-op = full 5-axis lifecycle" framing above conflicts
with the zone direction invariant (Zone 1 cannot import Zone 2).
The arm64 / x86_64 emit handlers' bodies need Zone 2 codegen ctx
types (`Arm64EmitCtx`, `X86_64EmitCtx`) which cannot be referenced
from `src/instruction/` (Zone 1). ADR-0074 resolves this by
**splitting the per-op file along the axis boundary**:

| Axis     | Zone | Path                                                            |
|----------|------|-----------------------------------------------------------------|
| validate | 1    | `src/instruction/wasm_X_Y/<op>.zig`                             |
| lower    | 1    | `src/instruction/wasm_X_Y/<op>.zig`                             |
| interp   | 1    | `src/instruction/wasm_X_Y/<op>.zig`                             |
| arm64    | 2    | `src/engine/codegen/arm64/ops/wasm_X_Y/<op>.zig`                |
| x86_64   | 2    | `src/engine/codegen/x86_64/ops/wasm_X_Y/<op>.zig`               |

The Zone 1 file remains the **identity anchor** (exports `op_tag`,
`wasm_level`, `wasi_level`, `enable_features`, IR-axis handlers).
Zone 2 sibling files import the Zone 1 file for `op_tag` metadata.
Comptime DCE is preserved on all 5 axes because each collector
(Zone 1 IR-axis collector + Zone 2 codegen collector) sees its
handler bodies at the same zone. See ADR-0074 for full alternatives
analysis.

The `handlers = .{ .validate, .lower, .arm64, .x86_64, .interp }`
aggregate shown in the §4.5 amend sketch above is REVISED:
- Zone 1 per-op file: `handlers = .{ .validate, .lower, .interp }`
  (IR-axis handlers only).
- Zone 2 per-arch op file: `pub fn emit(ctx: *ArchEmitCtx) !void`
  (single arch handler per file).

## Revision history

| Date       | Commit       | Why-class | Summary                                                                                                                                                                                                                                                                                                                          |
|------------|--------------|-----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-05-04 | `<backfill>` | initial   | Adopted; consolidated Q1-Q10 design dialogue.                                                                                                                                                                                                                                                                                    |
| 2026-05-05 | `<backfill>` | gap       | Amended by ADR-0024 (post-implementation): the §3 reference-table row for `api/lib_export.zig` is removed, `main.zig` moves to `src/cli/main.zig`, and a new `src/zwasm.zig` library root is added. ADR-0024 explains why the original ADR's directory shape couldn't serve as a Zig 0.16 lib `Module.root_source_file` directly. |
| 2026-05-11 | `e85bd561` | gap       | **`interp/loop.zig` rename was withdrawn** (per 2026-05-11 ADR audit, SUMMARY §3.3 / batch_B). Decision §"The src/ tree" listed `interp/loop.zig` as the new name (motivated by avoiding collision with `ir/dispatch.zig`). Implementation kept the original `interp/dispatch.zig` because `ir/dispatch.zig` was simultaneously renamed to `ir/dispatch_table.zig`, removing the collision. `src/zwasm.zig`'s test-discovery block imports `interp/dispatch.zig`. Honest record only; no design change. |
| 2026-05-19 | `<backfill>` | scope     | **§4.5 amend — per-op file pattern formally adopted** (Phase 9 completion substrate audit Q3 adoption; per ADR-0071 + ADR-0073). See dedicated section "§4.5 amend — per-op file migration plan" above. Key change: `instruction/wasm_X_Y/<category>.zig` → `instruction/wasm_X_Y/<op>.zig` (one file per op), each exporting `op_tag` / `wasm_level` / `wasi_level` / `enable_features` / `handlers = .{ .validate, .lower, .arm64, .x86_64, .interp }`. Central `src/ir/dispatch_collector.zig` (new) generates the `inline switch` dispatcher per axis with comptime build-option filter. `src/feature/<f>/register.zig` retains only the interp-axis registration. |
| 2026-05-19 | `<backfill>` | gap       | **Per-axis zone resolution sub-section added** (§9.12-B / B9). The 5-axis-in-one-file sketch from the same-day amend above conflicts with the Zone 1 ↔ Zone 2 boundary (per-op file at `src/instruction/` is Zone 1; `Arm64EmitCtx` / `X86_64EmitCtx` live at Zone 2). [ADR-0074](0074_per_op_file_zone_split.md) (Accepted 2026-05-19) splits the per-op file along the axis boundary: Zone 1 keeps validate / lower / interp; Zone 2 gets per-arch per-op files at `src/engine/codegen/<arch>/ops/wasm_X_Y/<op>.zig`. The §4.5 amend section above is updated with the revised `handlers` aggregate shape. Comptime DCE on all 5 axes is preserved. |
