//! Per-function ZIR usage prescans for x86_64 emit.
//!
//! Extracted from `emit.zig` per §9.9 / 9.9-m-5 (line-count
//! discipline after D-087/088/089 whitelist extension). Sibling
//! to `rbp_disp.zig` (form-selectors) under the x86_64 namespace.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`). Imported by `emit.zig`
//! only; no upward dependencies.

const zir = @import("../../../ir/zir.zig");

const ZirOp = zir.ZirOp;
const ZirFunc = zir.ZirFunc;

/// Returns `true` when the function emits any op that requires
/// R15 to hold the runtime pointer at execution time. R15 is
/// loaded in the prologue and used by:
///
/// - Memory ops (load / store / size / grow / copy / fill —
///   all sizes + v128 family) — vm_base / mem_limit reload via
///   `[R15+...]`.
/// - Globals (`global.get` / `global.set`) — globals table base
///   via `[R15+...]`.
/// - Call / call_indirect — funcptr / sig-table base via R15.
/// - Trap-stub-emitting ops (`unreachable`, div / rem trap
///   stubs, trunc_trap stubs) — write `1` to
///   `[R15+trap_flag_off]` on trap path. Without R15 set,
///   the store hits a garbage address; the runner-side
///   trap_flag check sees 0 (no trap) AND adjacent memory
///   corruption manifests as glibc dl-fini assertions at
///   process exit on Linux x86_64. D-087/088/089 cohort
///   (§9.9 / 9.9-m-5 per ADR-0056) discharged by adding the
///   div / rem / trunc_trap ops to this whitelist.
///
/// **Same-class grep target**: when adding a new ZirOp that
/// emits a trap-stub fixup (or otherwise references R15), add
/// it BOTH here AND at the op's emit site. Forgetting either
/// surfaces as silent miscompile (Mac aarch64 unaffected; x86_64
/// looks fine until the runtime trap path executes).
pub fn usesRuntimePtr(func: *const ZirFunc) bool {
    for (func.instrs.items) |ins| {
        switch (ins.op) {
            // Memory family (scalar + v128).
            .@"i32.load",
            .@"i32.load8_s",
            .@"i32.load8_u",
            .@"i32.load16_s",
            .@"i32.load16_u",
            .@"i32.store",
            .@"i32.store8",
            .@"i32.store16",
            .@"i64.load",
            .@"i64.load8_s",
            .@"i64.load8_u",
            .@"i64.load16_s",
            .@"i64.load16_u",
            .@"i64.load32_s",
            .@"i64.load32_u",
            .@"i64.store",
            .@"i64.store8",
            .@"i64.store16",
            .@"i64.store32",
            .@"f32.load",
            .@"f64.load",
            .@"f32.store",
            .@"f64.store",
            .@"v128.load",
            .@"v128.store",
            .@"v128.load8_splat",
            .@"v128.load16_splat",
            .@"v128.load32_splat",
            .@"v128.load64_splat",
            .@"v128.load32_zero",
            .@"v128.load64_zero",
            .@"v128.load8_lane",
            .@"v128.load16_lane",
            .@"v128.load32_lane",
            .@"v128.load64_lane",
            .@"v128.store8_lane",
            .@"v128.store16_lane",
            .@"v128.store32_lane",
            .@"v128.store64_lane",
            .@"v128.load8x8_s",
            .@"v128.load8x8_u",
            .@"v128.load16x4_s",
            .@"v128.load16x4_u",
            .@"v128.load32x2_s",
            .@"v128.load32x2_u",
            // Globals / memory metadata / calls.
            .@"global.get",
            .@"global.set",
            .@"memory.size",
            .@"memory.grow",
            .@"memory.copy",
            .@"memory.fill",
            .call,
            .call_indirect,
            // Trap-stub emitters: unreachable + div / rem (i32/i64
            // × s/u) + trunc_trap (i32/i64 × f32/f64 × s/u). All
            // write `[r15+trap_flag_off]` on the trap path; require
            // R15 initialised.
            .@"unreachable",
            .@"i32.div_s",
            .@"i32.div_u",
            .@"i32.rem_s",
            .@"i32.rem_u",
            .@"i64.div_s",
            .@"i64.div_u",
            .@"i64.rem_s",
            .@"i64.rem_u",
            .@"i32.trunc_f32_s",
            .@"i32.trunc_f32_u",
            .@"i32.trunc_f64_s",
            .@"i32.trunc_f64_u",
            .@"i64.trunc_f32_s",
            .@"i64.trunc_f32_u",
            .@"i64.trunc_f64_s",
            .@"i64.trunc_f64_u",
            => return true,
            else => {},
        }
    }
    return false;
}
