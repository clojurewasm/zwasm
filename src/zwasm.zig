//! zwasm — WebAssembly runtime, library root.
//!
//! Per ADR-0024 D-1/D-2: this file is the `root_source_file` of
//! the `core` Module that build.zig shares across the static lib
//! (`libzwasm.a`), the future shared lib / wasm lib targets, and
//! every test runner. The CLI exe (`zwasm` binary) lives in a
//! separate module rooted at `src/cli/main.zig` that imports
//! this module by name.
//!
//! ## Self-import surface (Bun pattern, ADR-0024 D-3)
//!
//! `core.addImport("zwasm", core)` in build.zig wires the
//! self-import. Any leaf file inside `src/` can write
//! `@import("zwasm").<zone>.<symbol>` to reach the unified
//! re-export hub regardless of how nested it is. Cross-zone
//! refactorings then update one re-export line below instead
//! of touching every leaf's `@import("../<zone>/<file>.zig")`.
//!
//! ## Two-tier import rule (ADR-0024 D-3)
//!
//! - Within-zone sibling: `@import("value.zig")` (relative)
//! - Within-zone parent:  `@import("../runtime.zig")` (relative)
//! - Cross-zone reference: `@import("zwasm").<zone>` (named)
//! - stdlib / builtin / build_options: `@import("std")` etc.
//!
//! ## Library zone classification
//!
//! `src/zwasm.zig` itself sits at "library surface" level — it
//! re-exports Zone 1+ symbols only (no Zone 2/3 export
//! dependencies leak through the surface). zone_check.sh
//! treats it as Zone 1.

pub const version = "0.0.0-pre";

// ============================================================
// Force-analyse the C-ABI binding files so their `pub export
// fn wasm_*` symbols land in `libzwasm.a` (per ADR-0024 D-2's
// note about subsuming the former `api/lib_export.zig` role).
// `pub const` re-exports below are not enough — Zig only emits
// `export` symbols from compilation units that the analysis
// pass actually visits, and a top-level `pub const` is lazily
// referenced from outside. This `comptime` block forces eager
// analysis at module-root semantics time, mirroring the
// pre-ADR-0023 `c_api_lib.zig` mechanism.
// ============================================================
comptime {
    _ = @import("api/wasm.zig");
    _ = @import("api/wasi.zig");
    _ = @import("api/trap_surface.zig");
    _ = @import("api/vec.zig");
    _ = @import("api/instance.zig");
    _ = @import("api/cross_module.zig");
}

// ============================================================
// Zone re-exports — the public surface for both the library
// archive and the self-import (`@import("zwasm")`) inside leaf
// files.
// ============================================================

// Zone 0
pub const support = struct {
    pub const dbg = @import("support/dbg.zig");
    pub const leb128 = @import("support/leb128.zig");
};
pub const platform = struct {
    pub const jit_mem = @import("platform/jit_mem.zig");
    // signal / fs / time are placeholders per ADR-0023 §3 P-H.
};

// Zone 1
pub const ir = struct {
    pub const zir = @import("ir/zir.zig");
    pub const dispatch_table = @import("ir/dispatch_table.zig");
    pub const lower = @import("ir/lower.zig");
    pub const verifier = @import("ir/verifier.zig");
    pub const analysis = struct {
        pub const loop_info = @import("ir/analysis/loop_info.zig");
        pub const liveness = @import("ir/analysis/liveness.zig");
        pub const const_prop = @import("ir/analysis/const_prop.zig");
    };
};
pub const parse = struct {
    pub const parser = @import("parse/parser.zig");
    pub const sections = @import("parse/sections.zig");
    pub const ctx = @import("parse/ctx.zig");
};
pub const validate = struct {
    pub const validator = @import("validate/validator.zig");
};
pub const runtime = @import("runtime/runtime.zig");
pub const diagnostic = @import("diagnostic/diagnostic.zig");
pub const feature = struct {
    pub const mvp = @import("feature/mvp/mod.zig");
    // Active feature register entries — placeholders until the
    // per-feature implementation lands per ROADMAP §11.
    pub const simd_128 = @import("feature/simd_128/register.zig");
    pub const gc = @import("feature/gc/register.zig");
    pub const exception_handling = @import("feature/exception_handling/register.zig");
    pub const tail_call = @import("feature/tail_call/register.zig");
    pub const function_references = @import("feature/function_references/register.zig");
    pub const memory64 = @import("feature/memory64/register.zig");
};

// Zone 2
pub const interp = struct {
    pub const mvp = @import("interp/mvp.zig");
    pub const dispatch = @import("interp/dispatch.zig");
    pub const trap_audit = @import("interp/trap_audit.zig");
};
pub const instruction = struct {
    pub const wasm_1_0 = struct {
        pub const numeric_int = @import("instruction/wasm_1_0/numeric_int.zig");
        pub const numeric_float = @import("instruction/wasm_1_0/numeric_float.zig");
        pub const numeric_conversion = @import("instruction/wasm_1_0/numeric_conversion.zig");
        pub const memory = @import("instruction/wasm_1_0/memory.zig");
        // control / parametric / variable are placeholder skeletons
        // per ADR-0023 §7 item 8 (full split deferred).
    };
    pub const wasm_2_0 = struct {
        pub const sign_extension = @import("instruction/wasm_2_0/sign_extension.zig");
        pub const nontrap_conversion = @import("instruction/wasm_2_0/nontrap_conversion.zig");
        pub const bulk_memory = @import("instruction/wasm_2_0/bulk_memory.zig");
        pub const reference_types = @import("instruction/wasm_2_0/reference_types.zig");
        pub const table_ops = @import("instruction/wasm_2_0/table_ops.zig");
    };
};
pub const engine = struct {
    pub const runner = @import("engine/runner.zig");
    pub const codegen = struct {
        pub const shared = struct {
            pub const reg_class = @import("engine/codegen/shared/reg_class.zig");
            pub const regalloc = @import("engine/codegen/shared/regalloc.zig");
            pub const linker = @import("engine/codegen/shared/linker.zig");
            pub const entry = @import("engine/codegen/shared/entry.zig");
            pub const compile = @import("engine/codegen/shared/compile.zig");
            pub const jit_abi = @import("engine/codegen/shared/jit_abi.zig");
        };
        pub const arm64 = struct {
            pub const inst = @import("engine/codegen/arm64/inst.zig");
            pub const abi = @import("engine/codegen/arm64/abi.zig");
            pub const prologue = @import("engine/codegen/arm64/prologue.zig");
            pub const label = @import("engine/codegen/arm64/label.zig");
            pub const emit = @import("engine/codegen/arm64/emit.zig");
        };
    };
};
pub const wasi = struct {
    pub const preview1 = @import("wasi/preview1.zig");
    pub const host = @import("wasi/host.zig");
    pub const fd = @import("wasi/fd.zig");
    pub const clocks = @import("wasi/clocks.zig");
    pub const proc = @import("wasi/proc.zig");
};

// Zone 3
pub const api = struct {
    pub const wasm = @import("api/wasm.zig");
    pub const wasi_binding = @import("api/wasi.zig");
    pub const trap_surface = @import("api/trap_surface.zig");
    pub const vec = @import("api/vec.zig");
    pub const cross_module = @import("api/cross_module.zig");
    pub const instance = @import("api/instance.zig");
};
pub const cli = struct {
    pub const run = @import("cli/run.zig");
    pub const diag_print = @import("cli/diag_print.zig");
};

// ============================================================
// Test loader — pulled by every artifact that uses `core` as
// its `root_module` (lib / test runners). Keeps the unit-test
// surface in one place; mirrors what `src/main.zig` previously
// did but is decoupled from the CLI exe entry.
// ============================================================

test {
    _ = @import("support/leb128.zig");
    _ = @import("support/dbg.zig");
    _ = @import("diagnostic/diagnostic.zig");
    _ = @import("cli/diag_print.zig");
    _ = @import("ir/zir.zig");
    _ = @import("ir/dispatch_table.zig");
    _ = @import("engine/codegen/shared/reg_class.zig");
    _ = @import("engine/codegen/shared/regalloc.zig");
    _ = @import("engine/codegen/arm64/inst.zig");
    _ = @import("engine/codegen/arm64/abi.zig");
    _ = @import("engine/codegen/arm64/emit.zig");
    _ = @import("engine/codegen/arm64/emit_test.zig");
    _ = @import("platform/jit_mem.zig");
    _ = @import("engine/codegen/shared/linker.zig");
    _ = @import("engine/codegen/shared/entry.zig");
    _ = @import("engine/codegen/shared/jit_abi.zig");
    _ = @import("engine/codegen/shared/compile.zig");
    _ = @import("engine/runner.zig");
    _ = @import("ir/analysis/loop_info.zig");
    _ = @import("ir/analysis/liveness.zig");
    _ = @import("ir/verifier.zig");
    _ = @import("ir/analysis/const_prop.zig");
    _ = @import("parse/parser.zig");
    _ = @import("validate/validator.zig");
    _ = @import("validate/validator_tests.zig");
    _ = @import("ir/lower.zig");
    _ = @import("ir/lower_tests.zig");
    _ = @import("parse/ctx.zig");
    _ = @import("feature/mvp/mod.zig");
    _ = @import("parse/sections.zig");
    _ = @import("runtime/runtime.zig");
    _ = @import("runtime/value.zig");
    _ = @import("runtime/trap.zig");
    _ = @import("runtime/frame.zig");
    _ = @import("interp/dispatch.zig");
    _ = @import("interp/mvp.zig");
    _ = @import("instruction/wasm_1_0/memory.zig");
    _ = @import("interp/trap_audit.zig");
    _ = @import("instruction/wasm_2_0/sign_extension.zig");
    _ = @import("instruction/wasm_2_0/nontrap_conversion.zig");
    _ = @import("instruction/wasm_2_0/bulk_memory.zig");
    _ = @import("instruction/wasm_2_0/reference_types.zig");
    _ = @import("instruction/wasm_2_0/table_ops.zig");
    _ = @import("api/wasm.zig");
    _ = @import("wasi/preview1.zig");
    _ = @import("wasi/host.zig");
    _ = @import("wasi/proc.zig");
    _ = @import("wasi/fd.zig");
    _ = @import("wasi/clocks.zig");
    _ = @import("cli/run.zig");
}
