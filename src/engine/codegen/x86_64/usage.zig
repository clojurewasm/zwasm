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

/// INVARIANT: this enum IS the truth that the x86_64 prologue
/// gates `PUSH R15 / MOV R15, <entry_arg0>` on. Any op whose emit:
///   1. Reads or writes `[R15 + off]` in its emitted bytes, OR
///   2. Invokes a runtime callback (trampoline, host dispatch,
///      memory.grow / table.grow) that itself reads R15, OR
///   3. Generates a trap-stub fixup (the trap stub writes
///      `trap_flag` / `trap_kind` via R15),
/// MUST be listed here. Drift = silent miscompile on Linux x86_64
/// (Mac aarch64 is structurally immune — its prologue always sets
/// X19). See lesson
/// `.dev/lessons/2026-05-28-x86_64-uses-runtime-ptr-eh-gap.md`
/// for the D-180 case study (EH ops missed → JIT read garbage R15
/// from Linux loader base address).
///
/// Detection hook: `bash scripts/check_uses_runtime_ptr.sh`.
///
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
            // §9.9 / 9.9-m-3b: memory.init reads data_segments_ptr +
            // data_dropped_ptr + mem_limit + vm_base from [r15+off].
            .@"memory.init",
            .call,
            .call_indirect,
            // ADR-0112 D4 / 10.TC: return_call emits MOV RDI, R15
            // (emitLoadCalleeRtSameModule) — reads R15. Must be
            // whitelisted so the prologue PUSH-saves R15 (otherwise
            // the MOV reads uninitialised R15 → silent miscompile,
            // D-180-class). The return_call_{indirect,ref} siblings
            // will land here when their emit bodies wire up.
            .return_call,
            // Trap-stub emitters: unreachable + div / rem (i32/i64
            // × s/u) + trunc_trap (i32/i64 × f32/f64 × s/u). All
            // write `[r15+trap_flag_off]` on the trap path; require
            // R15 initialised.
            .@"unreachable",
            // §9.9 / 9.9-m-1b: ref.func loads func_entities_ptr
            // from [r15+off]. Requires R15.
            .@"ref.func",
            // §9.9 / 9.9-m-3a: data.drop / elem.drop load
            // dropped_ptr from [r15+off] then byte-store 1.
            .@"data.drop",
            .@"elem.drop",
            // §9.9 / 9.9-m-2a (per ADR-0058): table.get / table.set
            // / table.size load tables_ptr from [r15+off] then index
            // the TableSlice array (refs / len reads). table.get
            // and table.set also emit trap-stub fixups for the
            // bounds check; all three require R15 initialised.
            .@"table.get",
            .@"table.set",
            .@"table.size",
            // §9.9 / 9.9-m-2b: table.fill — emits trap-stub fixups
            // for the dst+n bounds check; requires R15 initialised.
            .@"table.fill",
            // §9.9 / 9.9-m-2c: table.copy — emits trap-stub fixups
            // for dst+n + src+n bounds checks; requires R15.
            .@"table.copy",
            // §9.9 / 9.9-m-2c-init: table.init — same trap-fixup
            // surface (src+n vs seg.len, dst+n vs tables[x].len).
            .@"table.init",
            // §9.9 / 9.9-l-1b-d093-d48 (D-122/D-125): table.grow
            // loads `table_grow_fn` ptr from `[r15+off]` and CALLs
            // through it (mirror of memory.grow's ADR-0059 callout).
            // Without R15 initialised, the LDR reads garbage and
            // CALL jumps to an invalid address (SEGV).
            .@"table.grow",
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
            // Phase 10 EH (ADR-0114 D6 + ADR-0119) — `throw` /
            // `throw_ref` emit `MOVABS R10, trampoline; CALL R10`;
            // the trampoline reads `[R15 + eh_table_off]` etc. to
            // run `dispatchThrow`. Without R15 initialised, those
            // reads see whatever was in R15 at process startup
            // (typically Linux loader base, e.g. 0x7ffff7ffd000)
            // and the EH dispatch silently misroutes (e2e fixture
            // returns 0 instead of catching).
            //
            // `try_table` doesn't emit any R15-dependent bytes
            // directly, but its semantic completion relies on the
            // throw site reaching the trampoline; including it
            // here is defensive — a try_table with no inner throw
            // is a valid Wasm shape and would unnecessarily emit
            // R15 setup, but the cost is 13 bytes (probe + sentinel)
            // and the asymmetric "throw forces R15, try_table
            // doesn't" rule is harder to maintain correctly.
            .throw,
            .throw_ref,
            .try_table,
            => return true,
            else => {},
        }
    }
    return false;
}
