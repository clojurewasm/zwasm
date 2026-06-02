// AUTO-EXTRACTED from src/engine/runner.zig at ADR-0079 Step 1 (close-plan §6 (g)).
// Carve-out: `RuntimeOwned` + `setupRuntime` + `hostDispatchTrap`. Re-export
// from runner.zig keeps the public surface stable.
//
// Zone 2 (`src/engine/`); same import boundaries as runner.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

const parser = @import("../parse/parser.zig");
const sections = @import("../parse/sections.zig");
const jit_dispatch = @import("../wasi/jit_dispatch.zig");
const entry = @import("codegen/shared/entry.zig");
const linker = @import("codegen/shared/linker.zig");
const canonical_type = @import("codegen/shared/canonical_type.zig");
const rv = @import("runner_validate.zig");

const runner_mod = @import("runner.zig");
const instantiate = @import("../runtime/instance/instantiate.zig");
const heap_mod = @import("../feature/gc/heap.zig");
const gc_type_info = @import("../feature/gc/type_info.zig");
const Error = runner_mod.Error;
const CompiledWasm = runner_mod.CompiledWasm;

pub const RuntimeOwned = struct {
    rt: entry.JitRuntime,
    // Linear memory is owned by a pinned heap `MemGrowCtx` (reached via
    // `rt.host_state`) so `memory.grow` can realloc-move the backing
    // buffer and have BOTH the JIT (`rt.vm_base` reload) and `deinit` see
    // the current pointer (RuntimeOwned itself moves by value into
    // JitInstance, so a field pointer here would dangle). D-215.
    mem_ctx: ?*MemGrowCtx = null,
    dispatch: []usize,
    globals: []@import("../runtime/value.zig").Value,
    funcptrs: []u64,
    typeidxs: []u32,
    // §9.9 / 9.9-m-1b: per-module FuncEntity array backing JIT
    // `ref.func`. JIT computes `&func_entities[idx]` for each
    // ref.func op; only the address matters for ref.is_null /
    // ref.eq / select_typed [funcref] semantics. Struct contents
    // (FuncEntity.runtime, .func_idx) are not exercised on this
    // code path (no full Runtime; interp uses its own allocation).
    func_entities: []@import("../runtime/instance/func.zig").FuncEntity,
    // §9.9 / 9.9-m-3a: parallel data/elem segment "dropped"
    // flag arrays. bool stored as u8 (matches extern struct
    // layout the JIT expects).
    data_dropped: []u8,
    elem_dropped: []u8,
    // §9.9 / 9.9-m-3b: per-data-segment SegmentSlice descriptors
    // backing JIT `memory.init`. Each entry's `ptr` aliases the
    // module's parsed `.data` section bytes (held by the caller
    // via `wasm_bytes`); the lifetime contract is that
    // `wasm_bytes` outlives `RuntimeOwned` (callers pass module
    // bytes that persist across the call).
    data_segments: []entry.SegmentSlice,
    // §9.9 / 9.9-m-2a: per-table descriptors + contiguous refs
    // arena backing JIT `table.get` / `table.set` / `table.size`.
    // `tables_descriptors[k].refs` points into `table_refs`; the
    // two slices have matching lifetimes (both freed at deinit).
    tables_descriptors: []entry.TableSlice,
    table_refs: []u64,
    // §9.9 / 9.9-m-2c-init: per-element-segment ElemSlice descriptors
    // + contiguous u64 arena holding the pre-computed funcref values.
    elem_segments: []entry.ElemSlice,
    elem_refs: []u64,
    // §9.9 / 9.9-l-1b-d093-d42 (D-112): per-table call_indirect
    // dispatch descriptors + extra (non-table-0) funcptr/typeidx
    // arena. Table 0's TableJitCallInfo entry reuses `funcptrs` /
    // `typeidxs` above; tables 1..N point into the contiguous
    // `extra_funcptrs` / `extra_typeidxs` arenas via per-table
    // offsets computed at setup time.
    tables_jit_ci: []entry.TableJitCallInfo,
    extra_funcptrs: []u64,
    extra_typeidxs: []u32,
    // 10.G GC-on-JIT: dedicated arena holding the per-run GC Heap +
    // GcTypeInfos (rt.gc_heap / gc_type_infos_ptr alias into it).
    // Null for non-GC modules. One arena.deinit frees the slab + the
    // materialised type table.
    gc_arena: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(self: *RuntimeOwned, allocator: Allocator) void {
        if (self.gc_arena) |a| {
            a.deinit();
            allocator.destroy(a);
        }
        if (self.mem_ctx) |c| {
            // The ctx OWNS the (possibly grown) linear-memory buffer —
            // free the CURRENT pointer (memory.grow realloc-moves it).
            if (c.memory.len > 0) allocator.free(c.memory);
            allocator.destroy(c);
        }
        allocator.free(self.dispatch);
        allocator.free(self.globals);
        allocator.free(self.funcptrs);
        allocator.free(self.typeidxs);
        if (self.func_entities.len > 0) allocator.free(self.func_entities);
        if (self.data_dropped.len > 0) allocator.free(self.data_dropped);
        if (self.elem_dropped.len > 0) allocator.free(self.elem_dropped);
        if (self.data_segments.len > 0) allocator.free(self.data_segments);
        allocator.free(self.tables_descriptors);
        allocator.free(self.table_refs);
        if (self.elem_segments.len > 0) allocator.free(self.elem_segments);
        if (self.elem_refs.len > 0) allocator.free(self.elem_refs);
        allocator.free(self.tables_jit_ci);
        if (self.extra_funcptrs.len > 0) allocator.free(self.extra_funcptrs);
        if (self.extra_typeidxs.len > 0) allocator.free(self.extra_typeidxs);
    }
};

/// Host-side context for `memory.grow` (D-215). Pinned on the heap; a
/// pointer lives in `JitRuntime.host_state` so the C-ABI `jitMemoryGrow`
/// trampoline can realloc the buffer. Owns the linear-memory slice (freed
/// by `RuntimeOwned.deinit`).
pub const MemGrowCtx = struct {
    allocator: Allocator,
    memory: []u8,
    max_pages: u64,
};

/// Real `memory_grow_fn` (replaces `defaultMemoryGrowReject`). Grows the
/// linear memory by `delta_pages`, returning the OLD page count or -1 on
/// failure (max exceeded / OOM) — Wasm `memory.grow` semantics. Reallocs
/// the backing buffer (may move it) and updates `rt.vm_base` + `rt.mem_limit`
/// so the JIT body's post-call base reload sees the new buffer (arm64
/// reloads X28/X27; x86_64 reloads per-access). D-215.
///
/// Note: the trampoline ABI returns i32. memory64 `memory.grow` yields i64;
/// the -1 failure sentinel needs the result sign-extended to i64 at the call
/// site (D-215 Part B) — success values (old page count) fit i32 here.
pub fn jitMemoryGrow(rt: *entry.JitRuntime, delta_pages: u32) callconv(.c) i32 {
    const ctx: *MemGrowCtx = @ptrCast(@alignCast(rt.host_state orelse return -1));
    const page: u64 = 65536;
    const old_len = ctx.memory.len;
    const old_pages = old_len / page;
    const new_pages = old_pages + @as(u64, delta_pages);
    if (new_pages > ctx.max_pages) return -1;
    const new_bytes: usize = std.math.cast(usize, new_pages * page) orelse return -1;
    const grown = ctx.allocator.realloc(ctx.memory, new_bytes) catch return -1;
    @memset(grown[old_len..new_bytes], 0);
    ctx.memory = grown;
    rt.vm_base = grown.ptr;
    rt.mem_limit = new_bytes;
    return @bitCast(@as(u32, @truncate(old_pages)));
}

/// Real `table_grow_fn` (replaces `defaultTableGrowReject`) for D-224.
/// Grows a non-funcref table by `delta`, filling the new slots with `init`
/// and returning the OLD size (or -1 on failure). No realloc: setup
/// pre-allocates each non-funcref table's `refs` arena up to its capacity
/// (`.max`), so growth just fills pre-allocated slots + bumps `.len` — the
/// `TableSlice` descriptor is updated in place (table.get reads it fresh, so
/// no JIT base reload, unlike memory.grow). funcref tables stay rejected
/// (grown slots would need a funcptrs mirror that resolves the funcref
/// operand to a native entry — out of this chunk's scope).
pub fn jitTableGrow(rt: *entry.JitRuntime, tableidx: u32, init: u64, delta: u32) callconv(.c) i32 {
    if (tableidx >= rt.tables_count) return -1;
    const descs: [*]entry.TableSlice = @constCast(rt.tables_ptr);
    const d = &descs[tableidx];
    if (@intFromPtr(d.funcptrs) != 0) return -1; // funcref → unsupported here
    const old_len = d.len;
    const new_len: u64 = @as(u64, old_len) + @as(u64, delta);
    if (new_len > d.max) return -1; // exceeds pre-allocated capacity (= .max)
    var i: u32 = old_len;
    while (i < old_len + delta) : (i += 1) d.refs[i] = init;
    d.len = @intCast(new_len);
    return @bitCast(old_len);
}

/// Build a JitRuntime + populate its host_dispatch table + init
/// linear memory from data segments. Shared between `runI32Export`
/// and `runVoidExport`. The caller owns the returned `memory` and
/// `dispatch` slices via `RuntimeOwned.deinit`.
pub fn setupRuntime(
    allocator: Allocator,
    compiled: *const CompiledWasm,
    wasm_bytes: []const u8,
) Error!RuntimeOwned {
    return setupRuntimeLinked(allocator, compiled, wasm_bytes, &.{});
}

/// D-225 — `setupRuntime` + cross-module imported-global resolution. The
/// importing module's setup-time const-expr evals (defined-global init +
/// table explicit-init-expr) can `global.get N` an IMPORTED global; the
/// caller (spec runner / linker) passes the resolved import values in
/// import order via `imported_global_vals` so e.g. `(ref.i31 (global.get
/// $env.g))` reads 42 instead of nothing. Plain `setupRuntime` passes `&.{}`
/// (no imports). Emitted-code `global.get` of an import is a SEPARATE gap
/// (the JIT global model excludes import slots — see D-225 survey).
pub fn setupRuntimeLinked(
    allocator: Allocator,
    compiled: *const CompiledWasm,
    wasm_bytes: []const u8,
    imported_global_vals: []const u64,
) Error!RuntimeOwned {
    const dispatch = try allocator.alloc(usize, compiled.num_imports);
    errdefer allocator.free(dispatch);
    for (dispatch) |*slot| slot.* = @intFromPtr(&hostDispatchTrap);

    var memory: []u8 = &.{};
    errdefer if (memory.len > 0) allocator.free(memory);
    // D-215 — memory.grow upper bound (pages). Declared max if present,
    // else the spec address-space limit per idx_type. 0 = no memory section.
    var mem_max_pages: u64 = 0;

    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try parser.parse(ta, wasm_bytes);

    // D-225 — `[]*Value` view of the resolved imported-global values, in
    // import order, for the setup-time const-expr evals' `global.get N`
    // (N < num_global_imports). ta-allocated: read only during setup.
    const Value = @import("../runtime/value.zig").Value;
    const imp_global_ptrs: []const *Value = blk: {
        if (imported_global_vals.len == 0) break :blk &.{};
        const cells = try ta.alloc(Value, imported_global_vals.len);
        const ptrs = try ta.alloc(*Value, imported_global_vals.len);
        for (imported_global_vals, 0..) |v, i| {
            cells[i] = .{ .bits64 = v };
            ptrs[i] = &cells[i];
        }
        break :blk ptrs;
    };

    if (module.find(.import)) |s| {
        if (compiled.num_imports > 0) {
            var imports_buf = try sections.decodeImports(ta, s.body);
            defer imports_buf.deinit();
            jit_dispatch.populateDispatch(dispatch, imports_buf.items);
        }
    }

    if (module.find(.memory)) |s| {
        var memories = try sections.decodeMemory(ta, s.body);
        defer memories.deinit();
        if (memories.items.len > 0) {
            const page_size: u64 = 65536;
            const mem0 = memories.items[0];
            const min_pages: u64 = mem0.min;
            const total_bytes: u64 = min_pages * page_size;
            if (total_bytes > 256 * 1024 * 1024) {
                return Error.UnsupportedEntrySignature;
            }
            memory = try allocator.alloc(u8, @intCast(total_bytes));
            @memset(memory, 0);
            // D-215 — grow ceiling: declared max, else the spec page
            // limit (2^16 for mem32 [4 GiB], 2^48 for mem64).
            mem_max_pages = mem0.max orelse if (mem0.idx_type == .i64)
                (@as(u64, 1) << 48)
            else
                65536;
        }
    }

    if (module.find(.data)) |s| {
        var datas = try sections.decodeData(ta, s.body);
        defer datas.deinit();
        for (datas.items) |seg| {
            if (seg.kind != .active) continue;
            // D-219 — accepts i64.const offsets for memory64. `off_u >
            // memory.len` first so `off_u + len` can't overflow u64.
            const off_u = rv.evalConstOffsetU64(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
            if (off_u > memory.len or off_u + seg.bytes.len > memory.len) {
                return Error.UnsupportedEntrySignature;
            }
            @memcpy(memory[@intCast(off_u)..][0..seg.bytes.len], seg.bytes);
        }
    }

    // Decode globals + tables for placeholder arrays. Realistic
    // values are needed because fixtures' JIT bodies reach for
    // global.get / call_indirect bodies that reference these
    // offsets even when the bounds check would short-circuit
    // — `globals_base = undefined` previously caused 0xaaaa...
    // segfaults in the realworld corpus invocation path.
    var globals_count: u32 = 0;
    var decoded_globals: ?sections.Globals = null;
    defer if (decoded_globals) |*g| g.deinit();
    if (module.find(.global)) |s| {
        decoded_globals = try sections.decodeGlobals(ta, s.body);
        globals_count = @intCast(decoded_globals.?.items.len);
    }
    // §9.9 / 9.9-m-2a: parse the table section into per-table
    // descriptors. `table_size` is retained as the table-0 entry
    // count (call_indirect's `funcptrs_buf` + `typeidxs_buf` are
    // table-0-only specialisations); the new `tables_descs` array
    // generalises this to all declared tables for `table.get` /
    // `table.set` / `table.size` (m-2a) and later m-2b/c ops.
    var table_size: u32 = 0;
    // `init_expr` (D-225): Wasm 3.0 table-with-explicit-init-expr
    // (`0x40 0x00 reftype limits constexpr`) — raw const-expr bytes for the
    // initial element value (empty = default null fill). Slices into the
    // table section body (ta-owned, outlives `tables_buf.deinit`).
    const TableMeta = struct { min: u32, max: ?u32, is_funcref: bool, init_expr: []const u8 };
    var table_metas: []TableMeta = &.{};
    if (module.find(.table)) |s| {
        var tables_buf = try sections.decodeTables(ta, s.body);
        defer tables_buf.deinit();
        if (tables_buf.items.len > 0) {
            table_size = tables_buf.items[0].min;
            table_metas = try ta.alloc(TableMeta, tables_buf.items.len);
            for (tables_buf.items, 0..) |t, i| {
                table_metas[i] = .{ .min = t.min, .max = t.max, .is_funcref = (t.elem_type.isFuncref()), .init_expr = t.init_expr };
            }
        }
    }
    // Cap to keep allocator pressure bounded; fixtures with large
    // declared globals / tables surface as UnsupportedEntrySignature.
    if (globals_count > 4096) return Error.UnsupportedEntrySignature;
    if (table_size > 4096) return Error.UnsupportedEntrySignature;

    const globals_buf = try allocator.alloc(Value, if (globals_count == 0) 1 else globals_count);
    errdefer allocator.free(globals_buf);
    @memset(globals_buf, .{ .bits128 = 0 });

    // 10.G GC-on-JIT (ADR-0128 §2): materialise the GC heap + type table
    // for modules with a GC type section BEFORE the global-init loop, so
    // gc const-expr globals (struct.new / array.new) can allocate into it
    // (D-223). The JIT struct.new* / jitGcAlloc trampoline shares this
    // slab. All GC allocations live in a dedicated arena (freed at deinit).
    var gc_arena: ?*std.heap.ArenaAllocator = null;
    var gc_heap_typed: ?*heap_mod.Heap = null;
    var gc_type_infos_typed: ?*gc_type_info.GcTypeInfos = null;
    errdefer if (gc_arena) |a| {
        a.deinit();
        allocator.destroy(a);
    };
    if (module.needs_gc_heap) {
        if (module.find(.type)) |ts| {
            const ga = try allocator.create(std.heap.ArenaAllocator);
            ga.* = std.heap.ArenaAllocator.init(allocator);
            gc_arena = ga;
            const gaa = ga.allocator();
            var gc_types = try sections.decodeTypes(ta, ts.body);
            defer gc_types.deinit();
            const gti = try gaa.create(gc_type_info.GcTypeInfos);
            // v128 struct/array fields are deferred (ADR-0116 §3a) — map to
            // the runI32Export "unsupported shape" error rather than widen
            // the runner Error set with a GC-internal variant.
            gti.* = gc_type_info.materialiseGcTypes(gaa, gc_types) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnsupportedFieldSize => return error.UnsupportedEntrySignature,
            };
            const heap = try gaa.create(heap_mod.Heap);
            heap.* = heap_mod.Heap.init(gaa);
            gc_heap_typed = heap;
            gc_type_infos_typed = gti;
        }
    }
    const gc_heap_ptr: ?*anyopaque = gc_heap_typed;
    const gc_type_infos_ptr: ?*anyopaque = gc_type_infos_typed;

    // Build `func_entities` BEFORE the global-init loop so `ref.func N`
    // const-expr globals resolve to a non-null funcref (`&func_entities[N]`)
    // rather than the D-223 placeholder null (D-225 sub-fix: ref_func
    // `is_null-v` etc.). Only depends on `dispatch` + `compiled` + `module`
    // (all built above); the element-section loop below also consumes it.
    const FuncEntity = @import("../runtime/instance/func.zig").FuncEntity;
    const total_funcs = compiled.func_sigs.len;
    const func_entities = try allocator.alloc(FuncEntity, total_funcs);
    errdefer allocator.free(func_entities);
    var fe_canon_types: ?sections.Types = null;
    defer if (fe_canon_types) |*t| t.deinit();
    if (module.find(.type)) |ts| fe_canon_types = try sections.decodeTypes(ta, ts.body);
    for (func_entities, 0..) |*fe, i| {
        const f_off = compiled.module.func_offsets[i];
        const funcptr: usize = if (f_off == linker.IMPORT_SENTINEL_OFFSET)
            (if (i < dispatch.len) dispatch[i] else 0)
        else
            @intFromPtr(compiled.module.block.bytes.ptr + f_off);
        const raw_ti = compiled.func_typeidxs[i];
        const canon_ti: u32 = if (fe_canon_types) |t| canonical_type.canonicalTypeidx(t.items, raw_ti) else raw_ti;
        fe.* = .{ .runtime = undefined, .func_idx = @intCast(i), .typeidx = canon_ti, .funcptr = funcptr, .raw_typeidx = raw_ti };
    }

    // Evaluate each defined global's init-expr so e.g. `__stack_pointer`
    // holds its real value. This simplified setup previously left globals
    // at 0, which made shadow-stack modules' `SP - n` wrap to a huge OOB
    // address → trap (surfaced by the rust_data realworld fixture: real
    // rustc/clang -O code spills to the shadow stack). Non-const inits
    // (rare in these fixtures) fall back to 0. GC const-exprs (struct.new /
    // array.new) reach `evalGlobalInitGc` via the UnsupportedConstExpr
    // fallback and allocate on the heap materialised above (D-223). D-225:
    // `func_entities` (built above) now resolves `ref.func` globals to a
    // non-null funcref.
    if (decoded_globals) |g| {
        const gti_val: ?gc_type_info.GcTypeInfos = if (gc_type_infos_typed) |t| t.* else null;
        for (g.items, 0..) |gd, i| {
            globals_buf[i] = instantiate.evalConstExprValue(gd.init_expr) catch |e| blk: {
                if (e == error.UnsupportedConstExpr) {
                    break :blk instantiate.evalGlobalInitGc(gd.init_expr, gc_heap_typed, gti_val, func_entities, imp_global_ptrs) catch .{ .bits128 = 0 };
                }
                break :blk .{ .bits128 = 0 };
            };
        }
    }

    const funcptrs_buf = try allocator.alloc(u64, if (table_size == 0) 1 else table_size);
    errdefer allocator.free(funcptrs_buf);
    @memset(funcptrs_buf, 0);
    const typeidxs_buf = try allocator.alloc(u32, if (table_size == 0) 1 else table_size);
    errdefer allocator.free(typeidxs_buf);
    // Sentinel `maxInt(u32)` for "no function in this slot" — the
    // JIT-emitted call_indirect type-check `cmp w16, #expected`
    // never matches this, so an unset slot traps cleanly via the
    // bounds_fixups path instead of through a NULL `blr`.
    @memset(typeidxs_buf, std.math.maxInt(u32));

    // §9.9 / 9.9-m-2a (per ADR-0058): generalised per-table storage.
    // Each declared table gets a `TableSlice` descriptor with `refs`
    // pointing into a single contiguous `table_refs` arena. Each
    // entry is `Value.ref`-encoded u64 (FuncEntity pointer for
    // funcref, host handle for externref, or `null_ref` sentinel).
    // Initialised to `null_ref`; the element-section loop below
    // mirrors writes from `funcptrs_buf` into the corresponding
    // `table_refs` slot (using the FuncEntity-ptr encoding, NOT
    // the native-code-ptr encoding used by `funcptrs_buf`).
    // D-224 — table.grow capacity: pre-allocate non-funcref tables up to
    // their declared `max` (capped) so `jitTableGrow` can bump `.len` into
    // pre-allocated slots without realloc (the shared arena can't realloc one
    // slice). funcref tables stay at `min` (grow needs a funcptrs mirror for
    // grown slots → still rejected). `.max` is set to this capacity so the
    // grow fn's cap-check == the actual pre-allocated size.
    const grow_cap: u32 = 65536;
    const growCapacity = struct {
        fn f(tm: anytype, cap: u32) u32 {
            if (tm.is_funcref) return tm.min;
            const m = tm.max orelse return tm.min;
            return @min(m, cap);
        }
    }.f;
    var total_table_refs: usize = 0;
    for (table_metas) |tm| total_table_refs += growCapacity(tm, grow_cap);
    const tables_descs = try allocator.alloc(entry.TableSlice, if (table_metas.len == 0) 1 else table_metas.len);
    errdefer allocator.free(tables_descs);
    const table_refs = try allocator.alloc(u64, if (total_table_refs == 0) 1 else total_table_refs);
    errdefer allocator.free(table_refs);
    @memset(table_refs, Value.null_ref);
    // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
    {
        var ref_offset: usize = 0;
        for (table_metas, 0..) |tm, i| {
            const fp_init: [*]allowzero u64 = if (tm.is_funcref) funcptrs_buf.ptr else @ptrFromInt(0);
            const cap = growCapacity(tm, grow_cap);
            tables_descs[i] = .{
                .refs = table_refs.ptr + ref_offset,
                .len = tm.min,
                // D-224: `.max` = pre-allocated capacity (funcref keeps its
                // declared max; grow rejects it via the funcptrs check).
                .max = if (tm.is_funcref) (tm.max orelse entry.table_no_max) else cap,
                .funcptrs = fp_init,
            };
            ref_offset += cap;
        }
        if (table_metas.len == 0) {
            tables_descs[0] = .{
                .refs = table_refs.ptr,
                .len = 0,
                .max = entry.table_no_max,
                .funcptrs = funcptrs_buf.ptr,
            };
        }
    }

    // D-225 — Wasm 3.0 table-with-explicit-init-expr
    // (`(table N M reftype constexpr)`): the const-expr value initialises
    // ALL `min` slots (setup previously left them null → `table.get` of an
    // i31ref/ref table trapped on i31.get/use). evalConstExprValue handles
    // ref.null/numeric; evalGlobalInitGc handles ref.i31 / ref.func /
    // struct.new / array.new (with the heap + func_entities built above).
    // `global.get` of an IMPORTED global in the init-expr is not yet
    // resolved here (imported_globals = &.{}) — the cross-module piece.
    {
        const gti_val: ?gc_type_info.GcTypeInfos = if (gc_type_infos_typed) |t| t.* else null;
        for (table_metas, 0..) |tm, i| {
            if (tm.init_expr.len == 0) continue;
            const v = instantiate.evalConstExprValue(tm.init_expr) catch
                instantiate.evalGlobalInitGc(tm.init_expr, gc_heap_typed, gti_val, func_entities, imp_global_ptrs) catch continue;
            // A table init-expr always yields a reftype; `.ref` (== `.bits64`
            // offset in the extern union) holds the ref-encoded u64.
            const raw: u64 = v.ref;
            const d = tables_descs[i];
            var k: u32 = 0;
            while (k < tm.min) : (k += 1) d.refs[k] = raw;
        }
    }

    // §9.9 / 9.9-l-1b-d093-d42 (D-112): per-table call_indirect
    // dispatch (table 0 reuses funcptrs/typeidxs; k>0 → extras).
    var extra_total_slots: usize = 0;
    if (table_metas.len > 1) {
        for (table_metas[1..]) |tm| extra_total_slots += tm.min;
    }
    const tables_jit_ci_buf = try allocator.alloc(entry.TableJitCallInfo, if (table_metas.len == 0) 1 else table_metas.len);
    errdefer allocator.free(tables_jit_ci_buf);
    const extra_funcptrs_buf = try allocator.alloc(u64, if (extra_total_slots == 0) 1 else extra_total_slots);
    errdefer allocator.free(extra_funcptrs_buf);
    @memset(extra_funcptrs_buf, 0);
    const extra_typeidxs_buf = try allocator.alloc(u32, if (extra_total_slots == 0) 1 else extra_total_slots);
    errdefer allocator.free(extra_typeidxs_buf);
    @memset(extra_typeidxs_buf, std.math.maxInt(u32));
    {
        tables_jit_ci_buf[0] = .{ .funcptr_base = funcptrs_buf.ptr, .typeidx_base = typeidxs_buf.ptr };
        if (table_metas.len > 1) {
            var off: usize = 0;
            for (table_metas[1..], 1..) |tm, k| {
                tables_jit_ci_buf[k] = .{
                    .funcptr_base = extra_funcptrs_buf.ptr + off,
                    .typeidx_base = extra_typeidxs_buf.ptr + off,
                };
                // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
                if (tm.is_funcref) tables_descs[k].funcptrs = extra_funcptrs_buf.ptr + off;
                off += tm.min;
            }
        }
    }
    // Per-table starting offsets into extra_funcptrs/typeidxs.
    // 16-table cap → fixed stack array; over-cap modules trap.
    if (table_metas.len > 16) return Error.UnsupportedEntrySignature;
    var extra_offs: [16]usize = [_]usize{0} ** 16;
    if (table_metas.len > 1) {
        var off: usize = 0;
        for (table_metas[1..], 1..) |tm, k| {
            extra_offs[k] = off;
            off += tm.min;
        }
    }

    // §9.9 / 9.9-m-1b: per-module FuncEntity array, allocated
    // above the element-section loop so the loop populates refs
    // (FuncEntity-ptr) in the same pass as funcptrs_buf.
    // Wasm spec §4.5.7 (table.init / element-segment instantiation)
    // — populate the table with funcref entries from the element
    // section. Without this, `call_indirect` loads a NULL funcptr
    // and SEGVs at PC=0 (D-049 root cause). Active segments only;
    // passive / declarative segments live in the runtime element
    // index space, not the table itself, and reach the runtime via
    // `table.init` ops which v0.1.0's JIT path doesn't emit yet.
    //
    // §9.9 / 9.9-m-2a: the same loop populates `tables_descs[k].refs`
    // (`table_refs` arena slice) with `Value.fromFuncRef` encoding
    // (`@intFromPtr(&func_entities[fidx])`) for JIT `table.get`.
    // `funcptrs_buf` keeps the native-code-ptr encoding for
    // `call_indirect`'s fast path; the two views are coherent at
    // setup time but diverge if `table.set` runs post-instantiation
    // (a known follow-up tracked as part of the m-2 cluster).
    if (module.find(.element)) |s| {
        var elems = try sections.decodeElement(ta, s.body);
        defer elems.deinit();
        // D-111: canonicalize typeidx so call_indirect's structural
        // FuncType match (Wasm spec §3.4.6 + §4.4.10.1) works on
        // the bytewise typeidx compare. Decode the type section
        // once for the loop.
        const canon_types_section = module.find(.type);
        var canon_types: ?sections.Types = null;
        defer if (canon_types) |*t| t.deinit();
        if (canon_types_section) |ts| {
            canon_types = try sections.decodeTypes(ta, ts.body);
        }
        for (elems.items) |seg| {
            if (seg.kind != .active) continue;
            if (seg.tableidx >= tables_descs.len) continue;
            const off = rv.evalConstI32Expr(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
            if (off < 0) return Error.UnsupportedEntrySignature;
            const base: usize = @intCast(off);
            const tbl = tables_descs[seg.tableidx];
            if (base + seg.funcidxs.len > tbl.len) return Error.UnsupportedEntrySignature;
            // Wasm 3.0 GC (D-221 + D-218): an i31ref/eqref/anyref active elem
            // segment carries i31-ENCODED values in `funcidxs` (decoder:
            // i32ToI31Truncate == runtime Value.fromI31Truncate), NOT funcidxs.
            // Write them straight into `tbl.refs` (table.get returns them;
            // i31.get_{s,u} decode them) and SKIP the funcref funcptr/typeidx
            // wiring below — whose `tbl_funcptrs.len` guard wrongly rejects an
            // i31-only table (its `funcptrs_buf` isn't sized for it). The
            // discriminator mirrors the decoder's `head_ok` (abstract i31/eq/any
            // only; concrete `(ref $func)` tables still carry funcidxs).
            // (global.get-marker items [bit31] → later chunk; left null.)
            const seg_is_i31 = seg.elem_type == .ref and switch (seg.elem_type.ref.heap_type) {
                .abstract => |a| a == .i31 or a == .eq or a == .any,
                .concrete => false,
            };
            if (seg_is_i31) {
                for (seg.funcidxs, 0..) |fidx, i| {
                    if (fidx == std.math.maxInt(u32)) {
                        tbl.refs[base + i] = Value.null_ref;
                    } else if ((fidx & 0x80000000) == 0) {
                        tbl.refs[base + i] = fidx;
                    }
                }
                continue;
            }
            // §9.9 / 9.9-l-1b-d093-d42: per-table funcptr/typeidx
            // slice. Table 0 writes into the legacy flat
            // `funcptrs_buf` / `typeidxs_buf` (which back the
            // JitRuntime scalar `funcptr_base` / `typeidx_base`
            // fields); tables 1+ write into their slice within the
            // `extra_funcptrs` / `extra_typeidxs` arenas. The JIT
            // emit (arm64/x86_64 op_call.emitCallIndirect) selects
            // the right slice via `tables_jit_ci_ptr[table_idx]`.
            const is_table0 = (seg.tableidx == 0);
            const tbl_funcptrs: []u64 = if (is_table0)
                funcptrs_buf
            else
                extra_funcptrs_buf[extra_offs[seg.tableidx] .. extra_offs[seg.tableidx] + table_metas[seg.tableidx].min];
            const tbl_typeidxs: []u32 = if (is_table0)
                typeidxs_buf
            else
                extra_typeidxs_buf[extra_offs[seg.tableidx] .. extra_offs[seg.tableidx] + table_metas[seg.tableidx].min];
            if (base + seg.funcidxs.len > tbl_funcptrs.len) return Error.UnsupportedEntrySignature;
            for (seg.funcidxs, 0..) |fidx, i| {
                if (fidx == std.math.maxInt(u32)) {
                    // ref.null — leave the slot null + sentinel typeidx.
                    tbl.refs[base + i] = Value.null_ref;
                    continue;
                }
                if (fidx >= compiled.func_sigs.len) return Error.UnsupportedEntrySignature;
                tbl.refs[base + i] = @intFromPtr(&func_entities[fidx]);
                const f_off = compiled.module.func_offsets[fidx];
                const raw_typeidx = compiled.func_typeidxs[fidx];
                tbl_typeidxs[base + i] = if (canon_types) |t|
                    canonical_type.canonicalTypeidx(t.items, raw_typeidx)
                else
                    raw_typeidx;
                if (f_off == linker.IMPORT_SENTINEL_OFFSET) {
                    // Imported function in a table — host-call dispatch
                    // through `host_dispatch_base` is required to invoke
                    // it. v0.1.0's JIT call_indirect path doesn't emit
                    // that trampoline; leave funcptr null so an attempt
                    // to call it traps via NULL deref instead of running
                    // arbitrary host code.
                    continue;
                }
                tbl_funcptrs[base + i] = @intFromPtr(compiled.module.block.bytes.ptr + f_off);
            }
        }
    }

    // §9.9 / 9.9-m-3a: data / elem segment dropped-flag arrays.
    // Each is a bool[] sized to the module's segment count;
    // initialised to false (segment not yet dropped). JIT data.drop
    // / elem.drop write byte stores; JIT memory.init (m-3b) reads
    // before computing seg_len. For modules without segments, the
    // arrays are zero-length (no allocation, ptr = undefined).
    // §9.9 / 9.9-m-3b: parallel data_segments descriptor array.
    // Each entry's `ptr` aliases the parsed module's `.data`
    // section bytes via the resident `wasm_bytes` slice — the
    // segment's `bytes` field already points into that buffer
    // (no copy). `len` is the segment's byte count; the JIT
    // overrides to 0 via the `data_dropped_ptr` flag.
    var data_dropped_count: u32 = 0;
    var data_segments_buf: []entry.SegmentSlice = &.{};
    errdefer if (data_segments_buf.len > 0) allocator.free(data_segments_buf);
    if (module.find(.data)) |s| {
        var datas_buf = try sections.decodeData(ta, s.body);
        defer datas_buf.deinit();
        data_dropped_count = @intCast(datas_buf.items.len);
        if (data_dropped_count > 0) {
            data_segments_buf = try allocator.alloc(entry.SegmentSlice, data_dropped_count);
            for (datas_buf.items, 0..) |seg, i| {
                data_segments_buf[i] = .{
                    .ptr = if (seg.bytes.len == 0) @as([*]const u8, undefined) else seg.bytes.ptr,
                    .len = seg.bytes.len,
                };
            }
        }
    }
    const data_dropped = try allocator.alloc(u8, data_dropped_count);
    errdefer allocator.free(data_dropped);
    @memset(data_dropped, 0);
    // Wasm 2.0 §4.5.5: active data segments are consumed at
    // instantiation — applyActiveDataSegments has already copied
    // their bytes into linear memory; subsequent `memory.init`
    // against them must trap on n>0 because the segment's
    // effective size is 0. Mirror of d-49's elem-segment fix.
    if (module.find(.data)) |s_drop| {
        var datas_drop = try sections.decodeData(ta, s_drop.body);
        defer datas_drop.deinit();
        for (datas_drop.items, 0..) |seg, i| {
            if (seg.kind == .active) data_dropped[i] = 1;
        }
    }

    // §9.9 / 9.9-m-2c-init: per-element-segment ElemSlice arena.
    // Each segment gets its own pre-computed `[]u64` of Value.ref
    // values (FuncEntity ptr encoding for funcref; Value.null_ref
    // for null entries). The ElemSlice descriptors point into a
    // single contiguous arena sized to the sum of all
    // seg.funcidxs.len. JIT `table.init` indexes the descriptors
    // with stride 16, reads `refs[src..src+n]`, and writes into
    // the target table's u64[] storage.
    var elem_dropped_count: u32 = 0;
    var elem_segments_buf: []entry.ElemSlice = &.{};
    errdefer if (elem_segments_buf.len > 0) allocator.free(elem_segments_buf);
    var elem_refs_arena: []u64 = &.{};
    errdefer if (elem_refs_arena.len > 0) allocator.free(elem_refs_arena);
    if (module.find(.element)) |s| {
        var elems_buf = try sections.decodeElement(ta, s.body);
        defer elems_buf.deinit();
        elem_dropped_count = @intCast(elems_buf.items.len);
        if (elem_dropped_count > 0) {
            var total_refs: usize = 0;
            for (elems_buf.items) |seg| total_refs += seg.funcidxs.len;
            elem_segments_buf = try allocator.alloc(entry.ElemSlice, elem_dropped_count);
            elem_refs_arena = try allocator.alloc(u64, if (total_refs == 0) 1 else total_refs);
            var off: usize = 0;
            for (elems_buf.items, 0..) |seg, i| {
                const seg_len: u32 = @intCast(seg.funcidxs.len);
                elem_segments_buf[i] = .{
                    .refs = elem_refs_arena.ptr + off,
                    .len = seg_len,
                };
                // D-218: i31ref/eqref/anyref elem segments carry i31-ENCODED
                // values, NOT funcidxs — store them directly (table.init reads
                // them; i31.get decodes), mirroring the active elem-init +
                // compile-time guards. Else the encoded value (e.g. (999<<1)|1)
                // trips `>= func_sigs.len` → UnsupportedEntrySignature.
                const seg_is_i31 = seg.elem_type == .ref and switch (seg.elem_type.ref.heap_type) {
                    .abstract => |a| a == .i31 or a == .eq or a == .any,
                    .concrete => false,
                };
                for (seg.funcidxs, 0..) |fidx, k| {
                    if (fidx == std.math.maxInt(u32)) {
                        elem_refs_arena[off + k] = Value.null_ref;
                    } else if (seg_is_i31) {
                        elem_refs_arena[off + k] = if ((fidx & 0x80000000) == 0) fidx else Value.null_ref;
                    } else if (fidx >= compiled.func_sigs.len) {
                        return Error.UnsupportedEntrySignature;
                    } else {
                        elem_refs_arena[off + k] = @intFromPtr(&func_entities[fidx]);
                    }
                }
                off += seg_len;
            }
        }
    }
    const elem_dropped = try allocator.alloc(u8, elem_dropped_count);
    errdefer allocator.free(elem_dropped);
    @memset(elem_dropped, 0);
    // Wasm 2.0 §4.5.4: active + declarative elem segments are
    // consumed at instantiation — their effective size becomes 0
    // for any subsequent `table.init`. Re-walk the section to
    // mark them dropped. Passive segments stay live until an
    // explicit `elem.drop`.
    if (module.find(.element)) |s_drop| {
        var elems_drop = try sections.decodeElement(ta, s_drop.body);
        defer elems_drop.deinit();
        for (elems_drop.items, 0..) |seg, i| {
            if (seg.kind != .passive) elem_dropped[i] = 1;
        }
    }

    // D-215 — pin the linear-memory buffer in a heap ctx so memory.grow
    // can realloc-move it. Owns `memory` from here on (freed via deinit).
    const mem_ctx = try allocator.create(MemGrowCtx);
    errdefer allocator.destroy(mem_ctx);
    mem_ctx.* = .{ .allocator = allocator, .memory = memory, .max_pages = mem_max_pages };

    return .{
        .rt = .{
            .vm_base = if (memory.len > 0) memory.ptr else @ptrFromInt(@as(usize, 0x1000)),
            .mem_limit = memory.len,
            .host_state = mem_ctx,
            .memory_grow_fn = jitMemoryGrow,
            .funcptr_base = funcptrs_buf.ptr,
            .table_size = table_size,
            .typeidx_base = typeidxs_buf.ptr,
            .trap_flag = 0,
            .globals_base = globals_buf.ptr,
            .globals_count = globals_count,
            .host_dispatch_base = dispatch.ptr,
            .host_dispatch_count = compiled.num_imports,
            .func_entities_ptr = @ptrCast(func_entities.ptr),
            .func_entities_count = @intCast(total_funcs),
            .data_dropped_ptr = data_dropped.ptr,
            .data_dropped_count = data_dropped_count,
            .elem_dropped_ptr = elem_dropped.ptr,
            .elem_dropped_count = elem_dropped_count,
            .data_segments_ptr = if (data_segments_buf.len == 0) @as([*]const entry.SegmentSlice, undefined) else data_segments_buf.ptr,
            .data_segments_count = @intCast(data_segments_buf.len),
            .tables_ptr = tables_descs.ptr,
            .tables_count = @intCast(table_metas.len),
            .table_grow_fn = jitTableGrow, // D-224 (non-funcref tables)
            .elem_segments_ptr = if (elem_segments_buf.len == 0) @as([*]const entry.ElemSlice, undefined) else elem_segments_buf.ptr,
            .elem_segments_count = @intCast(elem_segments_buf.len),
            .tables_jit_ci_ptr = tables_jit_ci_buf.ptr,
            .tables_jit_ci_count = @intCast(tables_jit_ci_buf.len),
            // Phase 10.E IT-6 cycle 3c — EH dispatcher fields. The
            // trampoline reads ptr+count via `[X19/R15 + off]` to
            // materialize `ExceptionTable` + `CodeMap` slices for
            // `dispatchThrow`. Modules without try_table get an
            // empty table (ptr null, count 0); the .uncaught path
            // fires immediately.
            .eh_table_entries = if (compiled.exception_table.entries.len > 0)
                compiled.exception_table.entries.ptr
            else
                null,
            .eh_table_count = @intCast(compiled.exception_table.entries.len),
            .eh_code_map_entries = if (compiled.module.code_map_entries.len > 0)
                compiled.module.code_map_entries.ptr
            else
                null,
            .eh_code_map_count = @intCast(compiled.module.code_map_entries.len),
            // 10.G GC-on-JIT: the jitGcAlloc trampoline reads these to
            // allocate; null for non-GC modules.
            .gc_heap = gc_heap_ptr,
            .gc_type_infos_ptr = gc_type_infos_ptr,
        },
        .mem_ctx = mem_ctx,
        .dispatch = dispatch,
        .globals = globals_buf,
        .funcptrs = funcptrs_buf,
        .typeidxs = typeidxs_buf,
        .func_entities = func_entities,
        .data_dropped = data_dropped,
        .elem_dropped = elem_dropped,
        .data_segments = data_segments_buf,
        .tables_descriptors = tables_descs,
        .table_refs = table_refs,
        .elem_segments = elem_segments_buf,
        .elem_refs = elem_refs_arena,
        .tables_jit_ci = tables_jit_ci_buf,
        .extra_funcptrs = extra_funcptrs_buf,
        .extra_typeidxs = extra_typeidxs_buf,
        .gc_arena = gc_arena,
    };
}

/// Default host-import trap trampoline (chunk 7.9-d). C-ABI
/// function pointer planted into every `host_dispatch_base[i]`
/// slot when no real WASI handler has been installed. Sets
/// `rt.trap_flag = 1` and returns 0 (sentinel). The entry shim's
/// post-return inspection of `rt.trap_flag` distinguishes this
/// trap from a real i32 return value of 0.
///
/// The trampoline takes the JitRuntime ptr as its first arg
/// (matching the JIT-side calling convention's
/// `entry_arg0 = runtime_ptr` reservation). Subsequent Wasm args
/// are passed in arg-regs 1..N but are ignored — the trampoline
/// has no per-import signature, only a fail-safe sink. This
/// works because the C ABI on both AAPCS64 and SysV / Win64
/// permits a callee to read fewer args than the caller passed
/// without faulting.
pub fn hostDispatchTrap(rt: *entry.JitRuntime) callconv(.c) u64 {
    rt.trap_flag = 1;
    return 0;
}

// ============================================================
// Tests
// ============================================================
