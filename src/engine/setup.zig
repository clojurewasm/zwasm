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
const Error = runner_mod.Error;
const CompiledWasm = runner_mod.CompiledWasm;

pub const RuntimeOwned = struct {
    rt: entry.JitRuntime,
    memory: []u8,
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

    pub fn deinit(self: *RuntimeOwned, allocator: Allocator) void {
        if (self.memory.len > 0) allocator.free(self.memory);
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

/// Build a JitRuntime + populate its host_dispatch table + init
/// linear memory from data segments. Shared between `runI32Export`
/// and `runVoidExport`. The caller owns the returned `memory` and
/// `dispatch` slices via `RuntimeOwned.deinit`.
pub fn setupRuntime(
    allocator: Allocator,
    compiled: *const CompiledWasm,
    wasm_bytes: []const u8,
) Error!RuntimeOwned {
    const dispatch = try allocator.alloc(usize, compiled.num_imports);
    errdefer allocator.free(dispatch);
    for (dispatch) |*slot| slot.* = @intFromPtr(&hostDispatchTrap);

    var memory: []u8 = &.{};
    errdefer if (memory.len > 0) allocator.free(memory);

    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try parser.parse(ta, wasm_bytes);

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
            const min_pages: u64 = memories.items[0].min;
            const total_bytes: u64 = min_pages * page_size;
            if (total_bytes > 256 * 1024 * 1024) {
                return Error.UnsupportedEntrySignature;
            }
            memory = try allocator.alloc(u8, @intCast(total_bytes));
            @memset(memory, 0);
        }
    }

    if (module.find(.data)) |s| {
        var datas = try sections.decodeData(ta, s.body);
        defer datas.deinit();
        for (datas.items) |seg| {
            if (seg.kind != .active) continue;
            const off = rv.evalConstI32Expr(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
            if (off < 0) return Error.UnsupportedEntrySignature;
            const off_u: u64 = @intCast(off);
            if (off_u + seg.bytes.len > memory.len) {
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
    if (module.find(.global)) |s| {
        var globals_buf = try sections.decodeGlobals(ta, s.body);
        defer globals_buf.deinit();
        globals_count = @intCast(globals_buf.items.len);
    }
    // §9.9 / 9.9-m-2a: parse the table section into per-table
    // descriptors. `table_size` is retained as the table-0 entry
    // count (call_indirect's `funcptrs_buf` + `typeidxs_buf` are
    // table-0-only specialisations); the new `tables_descs` array
    // generalises this to all declared tables for `table.get` /
    // `table.set` / `table.size` (m-2a) and later m-2b/c ops.
    var table_size: u32 = 0;
    const TableMeta = struct { min: u32, max: ?u32, is_funcref: bool };
    var table_metas: []TableMeta = &.{};
    if (module.find(.table)) |s| {
        var tables_buf = try sections.decodeTables(ta, s.body);
        defer tables_buf.deinit();
        if (tables_buf.items.len > 0) {
            table_size = tables_buf.items[0].min;
            table_metas = try ta.alloc(TableMeta, tables_buf.items.len);
            for (tables_buf.items, 0..) |t, i| {
                table_metas[i] = .{ .min = t.min, .max = t.max, .is_funcref = (t.elem_type.isFuncref()) };
            }
        }
    }
    // Cap to keep allocator pressure bounded; fixtures with large
    // declared globals / tables surface as UnsupportedEntrySignature.
    if (globals_count > 4096) return Error.UnsupportedEntrySignature;
    if (table_size > 4096) return Error.UnsupportedEntrySignature;

    const Value = @import("../runtime/value.zig").Value;
    const globals_buf = try allocator.alloc(Value, if (globals_count == 0) 1 else globals_count);
    errdefer allocator.free(globals_buf);
    @memset(globals_buf, .{ .bits128 = 0 });

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
    var total_table_refs: usize = 0;
    for (table_metas) |tm| total_table_refs += tm.min;
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
            tables_descs[i] = .{
                .refs = table_refs.ptr + ref_offset,
                .len = tm.min,
                .max = tm.max orelse entry.table_no_max,
                .funcptrs = fp_init,
            };
            ref_offset += tm.min;
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
    const FuncEntity = @import("../runtime/instance/func.zig").FuncEntity;
    const total_funcs = compiled.func_sigs.len;
    const func_entities = try allocator.alloc(FuncEntity, total_funcs);
    errdefer allocator.free(func_entities);
    // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
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
        fe.* = .{ .runtime = undefined, .func_idx = @intCast(i), .typeidx = canon_ti, .funcptr = funcptr };
    }

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
                    // ref.null funcref — leave the slot null + sentinel typeidx.
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
                for (seg.funcidxs, 0..) |fidx, k| {
                    if (fidx == std.math.maxInt(u32)) {
                        elem_refs_arena[off + k] = Value.null_ref;
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

    return .{
        .rt = .{
            .vm_base = if (memory.len > 0) memory.ptr else @ptrFromInt(@as(usize, 0x1000)),
            .mem_limit = memory.len,
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
        },
        .memory = memory,
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
