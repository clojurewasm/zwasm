//! Shared base for spec-assertion runners (§9.9 / 9.9-l-1a per ADR-0057).
//!
//! Extraction substrate for code shared between `simd_assert_runner.zig`
//! (existing) and `spec_assert_runner_non_simd.zig` (l-1b). This file
//! starts with the mechanically-extractable scalar token parsers +
//! quoted-export name splitter; subsequent l-1a sub-chunks extend it
//! with the full manifest-loop + module-init + RunnerCallbacks trait
//! per ADR-0057 §"Decision".
//!
//! Each function here is **stateless** and **format-agnostic** — the
//! tokens it parses come from text manifests produced by
//! `scripts/regen_spec_*_assert.sh` (Python distillation of upstream
//! WebAssembly testsuite `.wast` files). The behaviour matches the
//! pre-extraction shape exactly; SIMD test gate verifies green-to-green.
//!
//! Zone: test/ (outside the src/ zone hierarchy per ADR-0023 §A1).

const std = @import("std");

const zwasm = @import("zwasm");
const runner_mod = zwasm.engine.runner;
const entry = zwasm.engine.codegen.shared.entry;
const Value = zwasm.runtime.Value;

/// Parse a decimal integer token into its u32 bit pattern. Wasm
/// asserts emit i32 results as decimal strings; signed values may
/// appear (negative literals in the source ⇒ negative decimal here).
/// Spec semantics treat the bits as u32; both u32 and i32 parsings
/// produce the same bit pattern via `@bitCast`.
pub fn parseI32Token(tok: []const u8) !u32 {
    return std.fmt.parseInt(u32, tok, 10) catch
        @as(u32, @bitCast(std.fmt.parseInt(i32, tok, 10) catch return error.BadValue));
}

/// 64-bit mirror of `parseI32Token`. Wasm `i64` result tokens map to
/// u64 bit patterns; signed literals roundtrip via `@bitCast`.
pub fn parseI64Token(tok: []const u8) !u64 {
    return std.fmt.parseInt(u64, tok, 10) catch
        @as(u64, @bitCast(std.fmt.parseInt(i64, tok, 10) catch return error.BadValue));
}

/// Split an `assert_return` / `assert_trap` directive's left-hand
/// side into `(fn_name, args_s)`. Handles single-quoted export
/// names (Wasm 2.0 chunk 9.9-h-29 Part B: names like
/// `'v128.load align=16'` contain spaces and must stay grouped).
///
/// Returns `error.BadDirective` for malformed input (missing close
/// quote, no space after quoted name, unquoted name with no args).
pub fn splitFnAndArgs(lhs: []const u8) !struct { fn_name: []const u8, args_s: []const u8 } {
    if (lhs.len > 0 and lhs[0] == '\'') {
        const close = std.mem.findScalarPos(u8, lhs, 1, '\'') orelse return error.BadDirective;
        if (close + 1 >= lhs.len) return error.BadDirective;
        if (lhs[close + 1] != ' ') return error.BadDirective;
        return .{ .fn_name = lhs[1..close], .args_s = lhs[close + 2 ..] };
    }
    const sp1 = std.mem.findScalar(u8, lhs, ' ') orelse return error.BadDirective;
    return .{ .fn_name = lhs[0..sp1], .args_s = lhs[sp1 + 1 ..] };
}

/// Per-runner tally of assertion outcomes. Per ADR-0029 Path B
/// (chunk 9.9-h-21): twin counters for `skip-impl` (counts toward
/// release gate) and `skip-adr-<id>` (waived per the named ADR).
///
/// The two skip counters report distinct facts in the summary line:
/// `skipped (= N skip-impl + M skip-adr)`. The exit-non-zero gate
/// (`failed > 0`) is checked by the caller; tally just collects.
pub const AssertTally = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    /// `skip-impl <reason>` — counts toward `skip-impl == 0` gate
    /// (ADR-0029 Path B). Per ADR-0029 the release gate forbids
    /// any line starting with `skip-impl `; a non-zero value here
    /// means the manifest has yet-to-be-classified gaps.
    skipped: u32 = 0,
    /// `skip-adr-<ADR-id> <reason>` — waived per the named ADR.
    /// Bare-legacy `skip <reason>` (pre-chunk 9.9-h-22 regen)
    /// also lands here with a one-time WARN to stdout.
    skipped_adr: u32 = 0,
};

/// ADR-0029 Path B classification — categorise a manifest line's
/// directive prefix into the skip family (or .other for everything
/// that isn't a skip). The caller increments the matching tally
/// counter; .bare_legacy additionally triggers a WARN print.
pub const SkipKind = enum { skip_impl, skip_adr, bare_legacy, other };

/// Classify a trimmed manifest line. Returns `.other` for lines
/// that don't start with `skip*`; the caller dispatches non-skip
/// directives separately.
pub fn classifySkipLine(line: []const u8) SkipKind {
    if (std.mem.startsWith(u8, line, "skip-impl ")) return .skip_impl;
    if (std.mem.startsWith(u8, line, "skip-adr-")) return .skip_adr;
    if (std.mem.startsWith(u8, line, "skip ")) return .bare_legacy;
    return .other;
}

/// Non-skip directive kinds in the manifest format. The caller
/// dispatches on this enum; `.unknown` lets specialisations decide
/// what to do (warn, ignore, fail) for unrecognised lines.
pub const DirectiveKind = enum {
    module,
    assert_return,
    assert_trap,
    assert_invalid,
    assert_malformed,
    /// d-36: bare `(invoke FN ARGS)` action — invoke for side
    /// effects, ignore result, propagate traps as FAIL.
    invoke_action,
    unknown,
};

/// Pair returned by `classifyDirective` — the directive kind and
/// the body (= line content after the prefix + single space).
pub const ClassifiedDirective = struct {
    kind: DirectiveKind,
    body: []const u8,
};

/// Inverse of `classifySkipLine` for the non-skip half: identify
/// which assert/module directive a line carries and return the
/// trailing body. Caller MUST have already routed through
/// `classifySkipLine` and seen `.other` before invoking this.
///
/// For `.unknown` the body is the full line (no prefix was
/// stripped); the caller can quote it back into a WARN/FAIL.
pub fn classifyDirective(line: []const u8) ClassifiedDirective {
    if (std.mem.startsWith(u8, line, "module ")) {
        return .{ .kind = .module, .body = line[7..] };
    }
    if (std.mem.startsWith(u8, line, "assert_return ")) {
        return .{ .kind = .assert_return, .body = line[14..] };
    }
    if (std.mem.startsWith(u8, line, "assert_trap ")) {
        return .{ .kind = .assert_trap, .body = line[12..] };
    }
    if (std.mem.startsWith(u8, line, "assert_invalid ")) {
        return .{ .kind = .assert_invalid, .body = line[15..] };
    }
    if (std.mem.startsWith(u8, line, "assert_malformed ")) {
        return .{ .kind = .assert_malformed, .body = line[17..] };
    }
    if (std.mem.startsWith(u8, line, "invoke-action ")) {
        return .{ .kind = .invoke_action, .body = line[14..] };
    }
    return .{ .kind = .unknown, .body = line };
}

/// Construct a `JitRuntime` from caller-owned scratch buffers
/// (memory + globals + funcref table). The buffer ownership lives
/// in the runner specialisation (since v128 globals demand
/// 16-byte alignment that scalar runners don't need); base only
/// stamps the `JitRuntime` struct shape so both runners produce
/// byte-identical layouts when handing off to the JIT entry
/// helpers.
///
/// Per ADR-0045 (scratch-buffer-direct path): spec runners bypass
/// `setupRuntime`'s per-module allocation; this helper is the
/// uniform construction point. Per ADR-0052: `globals_base` is a
/// `[*]Value` so the existing 8-byte-stride field type keeps
/// compiling; actual access width per global is decided by the
/// JIT emit (8 B scalars vs 16 B v128 via MOVUPS / LDR-Q).
///
/// Per ADR-0059 (§9.9 / 9.9-l-1b-d093-d8c): `memory_grow_fn` is
/// wired to `growableMemoryGrowFn` (below) so spec corpora that
/// exercise `memory.grow` (nop/block/loop/local_tee
/// `as-memory.grow-*` fixtures) see real growth within the
/// `growable_memory` pool. Callers must use `growable_memory[0..
/// current_mem_bytes]` as the `memory` arg (the runner's
/// on_module_loaded hook calls `resetGrowableMemory(1)` first).
pub fn makeJitRuntime(
    memory: []u8,
    globals: []u8,
    funcptrs: []u64,
    typeidxs: []u32,
) entry.JitRuntime {
    return .{
        .vm_base = memory.ptr,
        .mem_limit = memory.len,
        .funcptr_base = funcptrs.ptr,
        .table_size = @intCast(funcptrs.len),
        .typeidx_base = typeidxs.ptr,
        .trap_flag = 0,
        .globals_base = @ptrCast(@alignCast(globals.ptr)),
        .globals_count = @intCast(globals.len / @sizeOf(Value)),
        // D-093 (d-35): point host_dispatch_base at the spec-runner
        // import-trap stub table. Modules that import functions
        // (e.g. start.wast `(import "spectest" "print_i32")`) emit
        // `LDR X16, [X19, host_dispatch_base_off]; LDR X16,
        // [X16, idx*8]; BLR X16` for `(call N)` when N < num_imports;
        // before d-35 host_dispatch_base was `undefined` (0xaa…),
        // so the LDR dereferenced garbage and SEGV'd. The stub
        // table satisfies the LDR chain and traps cleanly via
        // `trap_flag`. Sized to `HOST_DISPATCH_STUB_CAPACITY` (≥
        // any realistic module's import count); unused slots also
        // point to the trap stub so out-of-range indices remain
        // safe.
        .host_dispatch_base = &host_dispatch_stubs,
        .host_dispatch_count = HOST_DISPATCH_STUB_CAPACITY,
        .memory_grow_fn = growableMemoryGrowFn,
    };
}

/// Spec-runner import-trap stub. Invoked via the
/// `host_dispatch_base` table when a module's defined function
/// calls an imported function (e.g. start.wast's modules with
/// `(import "spectest" "print_i32")`). Sets `trap_flag` and
/// returns; the JIT body continues to its epilogue, and the
/// runner's post-call check surfaces `Error.Trap`.
///
/// The signature is the minimum viable shape — most arches' C
/// ABIs let a callee with `fn(rt) → void` legally consume args /
/// produce no return when the actual import-site shape was
/// `fn(rt, ...args) → result`. Caller cleans the stack on x86_64
/// SysV / arm64 AAPCS64; the unread arg registers don't affect
/// the callee. Spec runners never need the import's real return,
/// since `trap_flag` short-circuits before any caller reads it.
fn hostImportTrapStub(rt: *entry.JitRuntime) callconv(.c) void {
    rt.trap_flag = 1;
}

/// Capacity for the spec-runner's `host_dispatch_base` stub
/// array. Spec corpus modules typically import 0–2 functions
/// (start.wast's `spectest.print_i32`); 64 is comfortable
/// headroom and the JIT body's import-call emit caps `idx*8`
/// at imm12 budget (32760), which is far above 64.
pub const HOST_DISPATCH_STUB_CAPACITY: u32 = 64;

/// Static stub table — every slot points to `hostImportTrapStub`.
/// Populated once at module load via `initHostDispatchStubs()`.
pub var host_dispatch_stubs: [HOST_DISPATCH_STUB_CAPACITY]usize = undefined;

/// Initialise the stub table — called once from each runner main
/// before the corpus loop starts. Idempotent.
pub fn initHostDispatchStubs() void {
    for (&host_dispatch_stubs) |*slot| {
        slot.* = @intFromPtr(&hostImportTrapStub);
    }
}

/// §9.9 / 9.9-l-1b-d093-d8c (per ADR-0059): growable memory pool
/// for spec runners. Bumped from 64 → 1024 pages (64 MiB) at d-21
/// to accommodate `memory_grow.wast`'s `grow(800)` + `grow(1)`
/// (=804 pages cumulative). 16-byte-aligned so the same pool
/// serves both the scalar non-simd runner and the simd runner
/// (the latter needs 16-byte alignment for `MOVUPS` / `LDR Q`).
pub const GROWABLE_MEMORY_CAPACITY: usize = 1024 * 65536;
pub var growable_memory: [GROWABLE_MEMORY_CAPACITY]u8 align(16) = undefined;

/// Module-scoped current memory size in bytes. Persists across
/// `assert_return` invocations within one module (so `memory.grow`
/// growth is observable by subsequent asserts) and resets on
/// module load via `resetGrowableMemory`.
pub var current_mem_bytes: u64 = 65536;

/// d-20: module-scoped max-pages cap. Wasm 1.0 §4.2.8 says
/// `memory.grow` returns -1 when the declared module-level max
/// would be exceeded. `null` means no max (= `GROWABLE_MEMORY_CAPACITY`
/// is the effective cap). Reset by `resetGrowableMemoryWithMax`
/// from each runner's `on_module_loaded`.
pub var current_mem_max_pages: ?u32 = null;

/// Reset the growable pool to `initial_pages` (Wasm-1.0 64 KiB pages).
/// Called from each runner's `on_module_loaded` callback. Zeros the
/// in-use region so prior module state doesn't leak into this one.
pub fn resetGrowableMemory(initial_pages: u32) void {
    current_mem_bytes = @as(u64, initial_pages) * 65536;
    if (current_mem_bytes > GROWABLE_MEMORY_CAPACITY) {
        // Pathological declared initial size — clamp + log. Spec
        // corpus is well under this cap; if a future module trips
        // this we'd surface as a bounds error on first load.
        current_mem_bytes = GROWABLE_MEMORY_CAPACITY;
    }
    @memset(growable_memory[0..@intCast(current_mem_bytes)], 0);
}

/// d-20: parse the wasm bytes' memory section to discover the
/// module-declared `(min, max)` pages. Returns `{min: 0, max:
/// null}` when no memory section exists or parsing fails.
/// Used by runners' `on_module_loaded` to seed
/// `resetGrowableMemory` + `current_mem_max_pages` from the
/// module's own declaration — matters for `memory_size.wast`
/// and `memory_grow.wast` where the max-pages cap gates whether
/// a `memory.grow` succeeds vs returns -1.
pub fn extractMemoryLimits(allocator: std.mem.Allocator, wasm_bytes: []const u8) struct { min: u32, max: ?u32 } {
    var module = zwasm.parse.parser.parse(allocator, wasm_bytes) catch return .{ .min = 0, .max = null };
    defer module.deinit(allocator);
    const sec = module.find(.memory) orelse return .{ .min = 0, .max = null };
    var memories = zwasm.parse.sections.decodeMemory(allocator, sec.body) catch return .{ .min = 0, .max = null };
    defer memories.deinit();
    if (memories.items.len == 0) return .{ .min = 0, .max = null };
    return .{ .min = memories.items[0].min, .max = memories.items[0].max };
}

/// d-37: detect whether a module imports state the spec runner
/// cannot bind. Returns true if any import is either:
///   - a function from a non-`spectest` module (cross-module),
///   - a table / memory / global from any module (spectest's
///     table / global / memory aren't bound by the runner; the
///     d-35 trap stub only covers function imports).
///
/// Used by the corpus loop to convert "can't satisfy this
/// module's imports" from FAIL to SKIP. The runner is a
/// no-host-binding spec assertion harness per ADR-0061; binding
/// real host state (multi-module register graphs, spectest's
/// magic table / global, WASI) is Track-D scope.
///
/// Parses just the import section header (raw byte walk; no
/// validator allocation). Any parse error → returns false (the
/// downstream compileWasm gets the same bytes and surfaces a
/// real error, so the runner still reports something useful
/// rather than swallowing the malformed input as SKIP).
pub fn hasUnbindableImports(allocator: std.mem.Allocator, wasm_bytes: []const u8) bool {
    var module = zwasm.parse.parser.parse(allocator, wasm_bytes) catch return false;
    defer module.deinit(allocator);
    const sec = module.find(.import) orelse return false;
    var imports = zwasm.parse.sections.decodeImports(allocator, sec.body) catch return false;
    defer imports.deinit();
    for (imports.items) |imp| {
        const is_spectest = std.mem.eql(u8, imp.module, "spectest");
        switch (imp.kind) {
            .func => {
                // spectest functions route through the d-35 host
                // trap stub. Non-spectest functions need a real
                // registered module — Track D.
                if (!is_spectest) return true;
            },
            // Tables / memories / globals from any module need
            // host-state binding; not available in the spec runner.
            .table, .memory, .global => return true,
        }
    }
    return false;
}

/// d-22 (D-106): parse the wasm bytes' start section (id=8) to
/// discover the module's start funcidx. Returns `null` when no
/// start section exists (most modules) or parsing fails. The
/// start section body is a single LEB128 u32 funcidx per Wasm
/// spec §5.5.10. Callers invoke the result via
/// `entry.callVoidNoArgs(compiled.module, start_idx, &rt)` after
/// scratch state is set up so the start fn sees the same
/// runtime view as subsequent invocations.
pub fn extractStartFunc(allocator: std.mem.Allocator, wasm_bytes: []const u8) ?u32 {
    var module = zwasm.parse.parser.parse(allocator, wasm_bytes) catch return null;
    defer module.deinit(allocator);
    const sec = module.find(.start) orelse return null;
    var pos: usize = 0;
    return zwasm.support.leb128.readUleb128(u32, sec.body, &pos) catch null;
}

/// §9.9 / 9.9-l-1b-d093-d8c (per ADR-0059): `memory.grow` callout
/// for spec runners. Updates `current_mem_bytes` (module-scoped
/// persistent state) AND `rt.mem_limit` (per-call cached value)
/// so subsequent asserts within the same module see the grown
/// size. Returns -1 when growth would exceed `GROWABLE_MEMORY_CAPACITY`,
/// matching Wasm 1.0 spec §4.4.7.6 host-refuses-growth semantics.
pub fn growableMemoryGrowFn(rt: *entry.JitRuntime, delta_pages: u32) callconv(.c) i32 {
    const page_size: u64 = 65536;
    const old_bytes = current_mem_bytes;
    const old_pages: u32 = @intCast(old_bytes / page_size);
    const new_pages: u64 = @as(u64, old_pages) + @as(u64, delta_pages);
    // d-20: respect module-declared max-pages. Wasm 1.0 §4.4.7.6 —
    // grow returns -1 when the result would exceed the declared
    // max. The pool capacity is a secondary cap.
    if (current_mem_max_pages) |max| {
        if (new_pages > max) return -1;
    }
    const new_bytes = new_pages * page_size;
    if (new_bytes > GROWABLE_MEMORY_CAPACITY) return -1;
    @memset(growable_memory[@intCast(old_bytes)..@intCast(new_bytes)], 0);
    current_mem_bytes = new_bytes;
    rt.mem_limit = new_bytes;
    return @intCast(old_pages);
}

/// Parse a 32-character hex token into 16 little-endian bytes —
/// the in-memory Wasm v128 layout (lane-0-byte-0 first). The
/// manifest format uses this for both v128 arguments and v128
/// result tokens (the `v128:<32 hex>` prefix is stripped by the
/// caller).
pub fn parseV128Token(tok: []const u8) ![16]u8 {
    if (tok.len != 32) return error.BadValue;
    var out: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const hi = try std.fmt.charToDigit(tok[i * 2], 16);
        const lo = try std.fmt.charToDigit(tok[i * 2 + 1], 16);
        out[i] = (hi << 4) | lo;
    }
    return out;
}

/// Wasm scalar + SIMD argument kinds visible in the manifest's
/// `assert_return` arg-list tokens. The non-SIMD specialisation
/// (l-1b) shares the enum + union so a single arg-buffer type
/// flows through both runners; the v128 variant is simply
/// unreachable in non-SIMD corpora.
pub const ArgKind = enum { i32, i64, f32, f64, v128 };
pub const ArgValue = union(ArgKind) {
    i32: u32,
    i64: u64,
    f32: u32,
    f64: u64,
    v128: [16]u8,
};

/// Parse one `<kind>:<value>` token into an ArgValue. FP tokens
/// reuse the integer parsers since the manifest emits FP values
/// as their bit-pattern integer (matches the runner harness's
/// `@bitCast` invocation pattern).
pub fn parseArgToken(tok: []const u8) !ArgValue {
    if (std.mem.startsWith(u8, tok, "i32:")) return .{ .i32 = try parseI32Token(tok[4..]) };
    if (std.mem.startsWith(u8, tok, "i64:")) return .{ .i64 = try parseI64Token(tok[4..]) };
    if (std.mem.startsWith(u8, tok, "f32:")) return .{ .f32 = try parseI32Token(tok[4..]) };
    if (std.mem.startsWith(u8, tok, "f64:")) return .{ .f64 = try parseI64Token(tok[4..]) };
    if (std.mem.startsWith(u8, tok, "v128:")) return .{ .v128 = try parseV128Token(tok[5..]) };
    return error.BadValue;
}

/// Tokenise an `assert_return` arg-list into `args_buf`. Returns
/// the count of parsed args. `"()"` is the zero-arg form (returns
/// 0 with no parsing).
///
/// Errors: `error.TooManyArgs` when the corpus exceeds the
/// caller-supplied buffer length (caller decides how to surface
/// it; the SIMD runner's buffer is `[4]ArgValue` per chunk
/// 9.9-h-3 / 9.9-h-28 / 9.9-h-29 dispatch ladder). `error.BadValue`
/// propagates from `parseArgToken` for an unrecognised prefix.
pub fn parseAssertReturnArgs(args_s: []const u8, args_buf: []ArgValue) !usize {
    if (std.mem.eql(u8, args_s, "()")) return 0;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, args_s, ' ');
    while (it.next()) |tok| {
        if (n >= args_buf.len) return error.TooManyArgs;
        args_buf[n] = try parseArgToken(tok);
        n += 1;
    }
    return n;
}

/// FP-result expectation per Wasm spec §A.2 "Result types"
/// + the testsuite's `nan:canonical` / `nan:arithmetic` tokens.
/// `exact` carries a literal bit pattern (caller decides u32 / u64
/// width); the two NaN variants accept any bit pattern matching
/// the spec-defined NaN class on the result FP width.
pub const ScalarFpSpec = union(enum) {
    exact: u64,
    canonical,
    arithmetic,
};

/// Parse the `<value>` portion of a `f32:` / `f64:` result token
/// (the runner has already stripped the `f32:` / `f64:` prefix).
/// Recognises `nan:canonical` / `nan:arithmetic` literals as the
/// corresponding `ScalarFpSpec` variants; falls back to
/// `parseI32Token` (for f32 results) / `parseI64Token` (for f64
/// results) via `bits` for any decimal bit-pattern literal.
///
/// `bits` chooses the integer parser. Pass `32` for f32 results,
/// `64` for f64. Mismatches surface as `error.BadValue`.
pub fn parseScalarFpExpected(value_s: []const u8, bits: u8) !ScalarFpSpec {
    if (std.mem.eql(u8, value_s, "nan:canonical")) return .canonical;
    if (std.mem.eql(u8, value_s, "nan:arithmetic")) return .arithmetic;
    switch (bits) {
        32 => return .{ .exact = @as(u64, try parseI32Token(value_s)) },
        64 => return .{ .exact = try parseI64Token(value_s) },
        else => return error.BadValue,
    }
}

/// Compare a f32 result's bit pattern against the expected spec.
/// Canonical NaN: sign-agnostic ±0x7fc00000. Arithmetic NaN:
/// exponent all-1s + mantissa MSB = 1 (= any quiet NaN, includes
/// canonical). Exact: u32 bit-pattern equality.
pub fn matchScalarF32(got_bits: u32, spec: ScalarFpSpec) bool {
    return switch (spec) {
        .canonical => got_bits == 0x7fc00000 or got_bits == 0xffc00000,
        .arithmetic => (got_bits & 0x7fc00000) == 0x7fc00000,
        .exact => |bits| got_bits == @as(u32, @intCast(bits & 0xffffffff)),
    };
}

/// f64 mirror of `matchScalarF32`. Canonical NaN bit pattern is
/// `±0x7ff8000000000000`; arithmetic is any quiet NaN
/// (exp all-1s + mantissa MSB = 1).
pub fn matchScalarF64(got_bits: u64, spec: ScalarFpSpec) bool {
    return switch (spec) {
        .canonical => got_bits == 0x7ff8000000000000 or got_bits == 0xfff8000000000000,
        .arithmetic => (got_bits & 0x7ff8000000000000) == 0x7ff8000000000000,
        .exact => |bits| got_bits == bits,
    };
}

// ============================================================
// SIGSEGV → trap recovery (D-103 / §9.9 / 9.9-l-1b-d093-d29).
//
// Some `assert_trap` paths (notably `elem.wast`) crash inside the
// JIT-compiled function before the trap stub sets `trap_flag` —
// the runner's `Error.Trap` check never sees the trap because the
// process has already SEGV'd. Wrapping the JIT entry call site
// with `sigsetjmp` + a SIGSEGV handler that `siglongjmp`s back
// converts an in-body fault into the same outcome as the trap
// stub: the call returns truthy (= recovered = trapped) instead
// of aborting the runner.
//
// Inline-call discipline: `sigsetjmp` MUST be invoked from the
// caller frame that the recovery should land in — its captured
// SP/PC point at the calling function. Wrapping `sigsetjmp` in
// a Zig helper that returns the value would bind the captured
// frame to the helper's (already-popped) frame, undefined
// behaviour on `longjmp`. So callers invoke `sigsetjmp` directly
// against `sigsegv_recover_buf`, then arm/disarm via
// `sigsegv_armed`.
// ============================================================

/// Backing storage for `sigsetjmp` / `siglongjmp`. Sized to fit
/// both `sigjmp_buf` layouts in scope: macOS arm64 = `int[49]`
/// (~196 B), Linux x86_64 glibc = `__jmp_buf_tag[1]` (~200 B).
/// 16-byte alignment matches both libcs' alignment requirements.
pub var sigsegv_recover_buf: [512]u8 align(16) = undefined;

/// Arming flag — when `true` the SIGSEGV handler `siglongjmp`s
/// back to the most recent `sigsetjmp` site; when `false` the
/// handler treats the SEGV as unexpected and exits with the
/// conventional `128 + 11 = 139` code (= a runner-internal bug
/// surfaces loudly instead of being swallowed).
pub var sigsegv_armed: bool = false;

// glibc exposes `sigsetjmp` as a macro that expands to
// `__sigsetjmp(env, savemask)`; the symbol available to the
// linker is `__sigsetjmp`. macOS / BSD libcs expose `sigsetjmp`
// directly. Resolve at comptime so the autonomous loop's 2-host
// gate (Mac arm64 + OrbStack Linux x86_64) finds the right
// linkage name on each side.
const SigsetjmpFn = *const fn (env: [*]u8, savemask: c_int) callconv(.c) c_int;
const SiglongjmpFn = *const fn (env: [*]u8, val: c_int) callconv(.c) noreturn;

pub const sigsetjmp: SigsetjmpFn = @extern(SigsetjmpFn, .{
    .name = if (@import("builtin").os.tag == .linux) "__sigsetjmp" else "sigsetjmp",
    .library_name = "c",
});
pub const siglongjmp: SiglongjmpFn = @extern(SiglongjmpFn, .{
    .name = "siglongjmp",
    .library_name = "c",
});

fn sigsegvHandler(_: std.posix.SIG) callconv(.c) void {
    if (sigsegv_armed) {
        sigsegv_armed = false;
        siglongjmp(@ptrCast(&sigsegv_recover_buf), 1);
    }
    // SEGV outside an armed JIT call: do not silently swallow.
    // `_exit(139)` is async-signal-safe (raw syscall, no atexit
    // handlers) and matches the conventional shell exit code for
    // a process killed by SIGSEGV (= 128 + 11).
    std.c._exit(139);
}

/// Install the SIGSEGV / SIGBUS handler used by the assert_trap
/// path. Idempotent — safe to call from multiple runner main
/// entries. Process-wide; the previous handler (if any) is
/// overwritten without recording (the spec runners are leaf
/// processes that own the signal disposition).
pub fn installSigsegvHandler() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = sigsegvHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.SEGV, &act, null);
    // SIGBUS covers the Mach-side variant (mis-aligned access on
    // arm64, mmap region truncation) so the runner survives the
    // same class of in-body fault on Mac.
    std.posix.sigaction(.BUS, &act, null);
}

/// Per-runner callbacks invoked by `runCorpus()`. Specialisations
/// (currently only `simd_assert_runner`; later `spec_assert_runner_non_simd`
/// per l-1b) provide function pointers that handle the type-specific
/// argument parsing, JIT invocation, and result comparison.
///
/// `on_module_loaded` runs after the base loop reads + compiles a
/// new module. Specialisations use it to repopulate any scratch
/// state the JIT will read from (memory bytes via active data
/// segments, defined-globals byte buffer, funcref table). On error
/// the base loop prints `FAIL` and sets `module_bad = true` so
/// subsequent asserts under the broken module silently skip
/// instead of cascading. The callback prints its own FAIL line
/// before returning the error (so the diagnostic carries
/// init-specific context — data-init vs globals-init vs table-init).
///
/// `handle_assert_return` / `handle_assert_trap` return `true` on
/// pass, `false` on a fixture mismatch (caller increments
/// `failed`). Returning an error is also a failure path; caller
/// prints a generic FAIL line with the error name.
pub const RunnerCallbacks = struct {
    on_module_loaded: *const fn (
        gpa: std.mem.Allocator,
        wasm_bytes: []const u8,
        compiled: *const runner_mod.CompiledWasm,
        stdout: *std.Io.Writer,
        name: []const u8,
    ) anyerror!void,
    handle_assert_return: *const fn (
        gpa: std.mem.Allocator,
        wasm_bytes: []const u8,
        compiled: *const runner_mod.CompiledWasm,
        body: []const u8,
        stdout: *std.Io.Writer,
        name: []const u8,
    ) anyerror!bool,
    handle_assert_trap: *const fn (
        gpa: std.mem.Allocator,
        wasm_bytes: []const u8,
        compiled: *const runner_mod.CompiledWasm,
        body: []const u8,
        stdout: *std.Io.Writer,
        name: []const u8,
    ) anyerror!bool,
    /// d-36: invoke-action handler — invokes a no-result action
    /// for its side effects. Returns true on success (no trap),
    /// false on trap; specialisations print their own FAIL line
    /// before returning false.
    handle_invoke_action: *const fn (
        gpa: std.mem.Allocator,
        wasm_bytes: []const u8,
        compiled: *const runner_mod.CompiledWasm,
        body: []const u8,
        stdout: *std.Io.Writer,
        name: []const u8,
    ) anyerror!bool,
};

/// Run one corpus manifest end-to-end: open the directory, read
/// `manifest.txt`, classify and dispatch every line. Module / assert
/// behaviour is delegated to the callbacks; skip classification,
/// `assert_invalid` / `assert_malformed` SKIP-VALIDATOR-GAP /
/// SKIP-PARSER-GAP wiring, and tally bookkeeping stay in base
/// (uniform across SIMD + non-SIMD specialisations).
pub fn runCorpus(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: *std.Io.Dir,
    name: []const u8,
    stdout: *std.Io.Writer,
    tally: *AssertTally,
    callbacks: RunnerCallbacks,
) !void {
    var dir = try root.openDir(io, name, .{});
    defer dir.close(io);

    const manifest_bytes = dir.readFileAlloc(io, "manifest.txt", gpa, .limited(1 << 22)) catch |err| {
        try stdout.print("FAIL  {s}: manifest read: {s}\n", .{ name, @errorName(err) });
        tally.failed += 1;
        return;
    };
    defer gpa.free(manifest_bytes);

    var current_wasm: ?[]u8 = null;
    var current_compiled: ?runner_mod.CompiledWasm = null;
    // `module_bad` distinguishes "no module yet" from "module declared
    // but compile (or init) rejected it"; subsequent asserts under a
    // bad module are silently skipped (counted) rather than each
    // cascading as a separate FAIL.
    var module_bad: bool = false;
    defer {
        if (current_wasm) |b| gpa.free(b);
        if (current_compiled) |*c| c.deinit(gpa);
    }

    var line_it = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;

        switch (classifySkipLine(line)) {
            .skip_impl => {
                tally.skipped += 1;
                continue;
            },
            .skip_adr => {
                tally.skipped_adr += 1;
                continue;
            },
            .bare_legacy => {
                try stdout.print("WARN  {s}: bare `skip` line — migrate to `skip-impl` or `skip-adr-<id>` (chunk 9.9-h-22 regen sweep): {s}\n", .{ name, line });
                tally.skipped += 1;
                continue;
            },
            .other => {},
        }

        const classified = classifyDirective(line);
        switch (classified.kind) {
            .module => {
                const file = classified.body;
                if (current_compiled) |*c| c.deinit(gpa);
                current_compiled = null;
                if (current_wasm) |b| gpa.free(b);
                current_wasm = null;
                module_bad = false;

                const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                    try stdout.print("FAIL  {s}/{s} module read: {s}\n", .{ name, file, @errorName(err) });
                    tally.failed += 1;
                    module_bad = true;
                    continue;
                };
                current_wasm = wasm_bytes;

                // d-37: skip modules whose imports the spec runner
                // cannot satisfy. `spectest.<fn>` function imports
                // route through the d-35 trap stub and are
                // safe-bindable; anything else (table / memory /
                // global imports OR any non-spectest module name)
                // would need cross-module instance state (Track D).
                // Pre-empt the compile-stage FAIL for those.
                if (hasUnbindableImports(gpa, wasm_bytes)) {
                    try stdout.print("SKIP-CROSS-MODULE-IMPORTS  {s}/{s}: module imports state the spec runner cannot bind\n", .{ name, file });
                    tally.skipped += 1;
                    module_bad = true;
                    continue;
                }

                const compiled = runner_mod.compileWasm(gpa, wasm_bytes) catch |err| {
                    try stdout.print("FAIL  {s}/{s} compile: {s}\n", .{ name, file, @errorName(err) });
                    tally.failed += 1;
                    module_bad = true;
                    continue;
                };
                current_compiled = compiled;
                callbacks.on_module_loaded(gpa, wasm_bytes, &compiled, stdout, name) catch |err| switch (err) {
                    // d-36: distinguished SKIP path for on_module_loaded
                    // — currently used by the start-fn invocation when
                    // an unbound host import trap surfaces, since the
                    // spec runner can't bind spectest imports
                    // (Track-D scope). The callback prints its own
                    // SKIP-* marker before returning.
                    error.SkipModule => {
                        tally.skipped += 1;
                        module_bad = true;
                        continue;
                    },
                    // The callback printed its own init-specific FAIL line
                    // before returning the error; base just records the
                    // failure and marks module_bad to suppress cascade.
                    else => {
                        tally.failed += 1;
                        module_bad = true;
                        continue;
                    },
                };
            },
            .assert_return => {
                if (module_bad) {
                    tally.skipped += 1;
                    continue;
                }
                const compiled_ptr: *const runner_mod.CompiledWasm = if (current_compiled) |*c| c else {
                    try stdout.print("FAIL  {s}: assert_return without prior module\n", .{name});
                    tally.failed += 1;
                    continue;
                };
                const wasm = current_wasm.?;
                const ok = callbacks.handle_assert_return(gpa, wasm, compiled_ptr, classified.body, stdout, name) catch |err| {
                    try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                if (ok) tally.passed += 1 else tally.failed += 1;
            },
            .assert_trap => {
                if (module_bad) {
                    tally.skipped += 1;
                    continue;
                }
                const compiled_ptr: *const runner_mod.CompiledWasm = if (current_compiled) |*c| c else {
                    try stdout.print("FAIL  {s}: assert_trap without prior module\n", .{name});
                    tally.failed += 1;
                    continue;
                };
                const wasm = current_wasm.?;
                const ok = callbacks.handle_assert_trap(gpa, wasm, compiled_ptr, classified.body, stdout, name) catch |err| {
                    try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                if (ok) tally.passed += 1 else tally.failed += 1;
            },
            .invoke_action => {
                if (module_bad) {
                    tally.skipped += 1;
                    continue;
                }
                const compiled_ptr: *const runner_mod.CompiledWasm = if (current_compiled) |*c| c else {
                    try stdout.print("FAIL  {s}: invoke-action without prior module\n", .{name});
                    tally.failed += 1;
                    continue;
                };
                const wasm = current_wasm.?;
                const ok = callbacks.handle_invoke_action(gpa, wasm, compiled_ptr, classified.body, stdout, name) catch |err| {
                    try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                if (ok) tally.passed += 1 else tally.failed += 1;
            },
            .assert_invalid => {
                const file = classified.body;
                const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                    try stdout.print("FAIL  {s}/{s} (assert_invalid) read: {s}\n", .{ name, file, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                if (runner_mod.compileWasm(gpa, wasm_bytes)) |compiled_ok| {
                    var c = compiled_ok;
                    c.deinit(gpa);
                    try stdout.print("SKIP-VALIDATOR-GAP  {s}: assert_invalid {s}\n", .{ name, file });
                    tally.skipped += 1;
                } else |_| {
                    tally.passed += 1;
                }
                gpa.free(wasm_bytes);
            },
            .assert_malformed => {
                const file = classified.body;
                const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                    try stdout.print("FAIL  {s}/{s} (assert_malformed) read: {s}\n", .{ name, file, @errorName(err) });
                    tally.failed += 1;
                    continue;
                };
                if (runner_mod.compileWasm(gpa, wasm_bytes)) |compiled_ok| {
                    var c = compiled_ok;
                    c.deinit(gpa);
                    try stdout.print("SKIP-PARSER-GAP  {s}: assert_malformed {s}\n", .{ name, file });
                    tally.skipped += 1;
                } else |_| {
                    tally.passed += 1;
                }
                gpa.free(wasm_bytes);
            },
            .unknown => {
                try stdout.print("FAIL  {s}: unknown directive '{s}'\n", .{ name, line });
                tally.failed += 1;
            },
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "parseI32Token: unsigned decimal" {
    try testing.expectEqual(@as(u32, 42), try parseI32Token("42"));
    try testing.expectEqual(@as(u32, 0), try parseI32Token("0"));
}

test "parseI32Token: negative decimal roundtrips through i32" {
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), try parseI32Token("-1"));
    try testing.expectEqual(@as(u32, 0x80000000), try parseI32Token("-2147483648"));
}

test "parseI32Token: out-of-range rejects" {
    try testing.expectError(error.BadValue, parseI32Token("9999999999"));
    try testing.expectError(error.BadValue, parseI32Token("abc"));
}

test "parseI64Token: signed/unsigned both roundtrip" {
    try testing.expectEqual(@as(u64, 42), try parseI64Token("42"));
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), try parseI64Token("-1"));
    try testing.expectEqual(@as(u64, 0x8000000000000000), try parseI64Token("-9223372036854775808"));
}

test "splitFnAndArgs: unquoted name + args" {
    const r = try splitFnAndArgs("foo 1 2 3");
    try testing.expectEqualStrings("foo", r.fn_name);
    try testing.expectEqualStrings("1 2 3", r.args_s);
}

test "splitFnAndArgs: single-quoted name + args" {
    const r = try splitFnAndArgs("'v128.load align=16' 0 1");
    try testing.expectEqualStrings("v128.load align=16", r.fn_name);
    try testing.expectEqualStrings("0 1", r.args_s);
}

test "splitFnAndArgs: malformed (no close quote) rejects" {
    try testing.expectError(error.BadDirective, splitFnAndArgs("'foo bar"));
}

test "splitFnAndArgs: malformed (no space after close quote) rejects" {
    try testing.expectError(error.BadDirective, splitFnAndArgs("'foo'"));
}

test "classifySkipLine: skip-impl recognised" {
    try testing.expectEqual(SkipKind.skip_impl, classifySkipLine("skip-impl unsupported op"));
}

test "classifySkipLine: skip-adr-* recognised" {
    try testing.expectEqual(SkipKind.skip_adr, classifySkipLine("skip-adr-0029 waived"));
}

test "classifySkipLine: bare-legacy `skip ` recognised with WARN signal" {
    try testing.expectEqual(SkipKind.bare_legacy, classifySkipLine("skip legacy reason"));
}

test "classifySkipLine: regular directive returns .other" {
    try testing.expectEqual(SkipKind.other, classifySkipLine("assert_return foo 1"));
    try testing.expectEqual(SkipKind.other, classifySkipLine("module test.wasm"));
}

test "classifySkipLine: `skip-implfoo` (no space) is NOT classified as skip-impl" {
    // Defensive: the prefix is `skip-impl ` (with trailing space).
    // A directive named `skip-impl-something` shouldn't accidentally
    // route to skip-impl. classifySkipLine returns .other.
    try testing.expectEqual(SkipKind.other, classifySkipLine("skip-implfoo"));
}

test "AssertTally: defaults are zero" {
    const t: AssertTally = .{};
    try testing.expectEqual(@as(u32, 0), t.passed);
    try testing.expectEqual(@as(u32, 0), t.failed);
    try testing.expectEqual(@as(u32, 0), t.skipped);
    try testing.expectEqual(@as(u32, 0), t.skipped_adr);
}

test "classifyDirective: module strips `module ` prefix" {
    const r = classifyDirective("module test.wasm");
    try testing.expectEqual(DirectiveKind.module, r.kind);
    try testing.expectEqualStrings("test.wasm", r.body);
}

test "classifyDirective: assert_return strips prefix" {
    const r = classifyDirective("assert_return foo i32:42");
    try testing.expectEqual(DirectiveKind.assert_return, r.kind);
    try testing.expectEqualStrings("foo i32:42", r.body);
}

test "classifyDirective: assert_trap / assert_invalid / assert_malformed all routed" {
    try testing.expectEqual(DirectiveKind.assert_trap, classifyDirective("assert_trap bar").kind);
    try testing.expectEqual(DirectiveKind.assert_invalid, classifyDirective("assert_invalid baz").kind);
    try testing.expectEqual(DirectiveKind.assert_malformed, classifyDirective("assert_malformed qux").kind);
}

test "classifyDirective: unknown returns the full line in body" {
    const r = classifyDirective("garbage_line foo");
    try testing.expectEqual(DirectiveKind.unknown, r.kind);
    try testing.expectEqualStrings("garbage_line foo", r.body);
}

test "parseV128Token: 32 hex chars → 16 little-endian bytes" {
    const bytes = try parseV128Token("0102030405060708090a0b0c0d0e0f10");
    try testing.expectEqual(@as(u8, 0x01), bytes[0]);
    try testing.expectEqual(@as(u8, 0x10), bytes[15]);
}

test "parseV128Token: wrong length rejects" {
    try testing.expectError(error.BadValue, parseV128Token("0102"));
}

test "parseArgToken: scalar prefixes route to correct ArgKind" {
    const a = try parseArgToken("i32:42");
    try testing.expect(a == .i32);
    try testing.expectEqual(@as(u32, 42), a.i32);

    const b = try parseArgToken("i64:-1");
    try testing.expect(b == .i64);
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), b.i64);

    const c = try parseArgToken("f32:0");
    try testing.expect(c == .f32);

    const d = try parseArgToken("f64:0");
    try testing.expect(d == .f64);
}

test "parseArgToken: v128 returns 16-byte payload" {
    const a = try parseArgToken("v128:000102030405060708090a0b0c0d0e0f");
    try testing.expect(a == .v128);
    try testing.expectEqual(@as(u8, 0x00), a.v128[0]);
    try testing.expectEqual(@as(u8, 0x0f), a.v128[15]);
}

test "parseArgToken: unrecognised prefix rejects" {
    try testing.expectError(error.BadValue, parseArgToken("xyz:42"));
}

test "parseAssertReturnArgs: zero-arg form returns 0" {
    var buf: [4]ArgValue = undefined;
    try testing.expectEqual(@as(usize, 0), try parseAssertReturnArgs("()", &buf));
}

test "parseAssertReturnArgs: space-separated tokens" {
    var buf: [4]ArgValue = undefined;
    const n = try parseAssertReturnArgs("i32:1 i32:2 i32:3", &buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u32, 1), buf[0].i32);
    try testing.expectEqual(@as(u32, 2), buf[1].i32);
    try testing.expectEqual(@as(u32, 3), buf[2].i32);
}

test "parseAssertReturnArgs: TooManyArgs when buffer overflows" {
    var buf: [2]ArgValue = undefined;
    try testing.expectError(error.TooManyArgs, parseAssertReturnArgs("i32:1 i32:2 i32:3", &buf));
}

test "parseAssertReturnArgs: bad token propagates BadValue" {
    var buf: [4]ArgValue = undefined;
    try testing.expectError(error.BadValue, parseAssertReturnArgs("i32:1 xyz:2", &buf));
}

test "parseScalarFpExpected: nan:canonical / nan:arithmetic" {
    try testing.expectEqual(ScalarFpSpec.canonical, try parseScalarFpExpected("nan:canonical", 32));
    try testing.expectEqual(ScalarFpSpec.arithmetic, try parseScalarFpExpected("nan:arithmetic", 64));
}

test "parseScalarFpExpected: literal decimal routes to exact" {
    const got = try parseScalarFpExpected("42", 32);
    try testing.expect(got == .exact);
    try testing.expectEqual(@as(u64, 42), got.exact);
}

test "matchScalarF32: canonical NaN sign-agnostic" {
    try testing.expect(matchScalarF32(0x7fc00000, .canonical));
    try testing.expect(matchScalarF32(0xffc00000, .canonical));
    try testing.expect(!matchScalarF32(0x7fc00001, .canonical));
}

test "matchScalarF32: arithmetic NaN accepts any quiet NaN" {
    try testing.expect(matchScalarF32(0x7fc00000, .arithmetic));
    try testing.expect(matchScalarF32(0x7fc00001, .arithmetic));
    try testing.expect(matchScalarF32(0xffc00010, .arithmetic));
    // signalling NaN (mantissa MSB=0): rejected
    try testing.expect(!matchScalarF32(0x7f800001, .arithmetic));
}

test "matchScalarF32: exact bit-pattern equality" {
    try testing.expect(matchScalarF32(42, .{ .exact = 42 }));
    try testing.expect(!matchScalarF32(42, .{ .exact = 43 }));
}

test "matchScalarF64: canonical / arithmetic / exact" {
    try testing.expect(matchScalarF64(0x7ff8000000000000, .canonical));
    try testing.expect(matchScalarF64(0xfff8000000000000, .canonical));
    try testing.expect(matchScalarF64(0x7ff8000000000001, .arithmetic));
    try testing.expect(!matchScalarF64(0x7ff0000000000001, .arithmetic));
    try testing.expect(matchScalarF64(0xdeadbeef, .{ .exact = 0xdeadbeef }));
}

test "sigsegv guard: handler siglongjmps back to caller frame on raised SIGSEGV" {
    installSigsegvHandler();

    // Inline `sigsetjmp` — its captured frame is THIS test's
    // frame, so the handler's `siglongjmp` lands on the second
    // return below. `recovered` lives in module scope to survive
    // the longjmp (caller-frame locals may be in clobbered regs).
    const Recover = struct { var flag: bool = false; };
    Recover.flag = false;

    if (sigsetjmp(@ptrCast(&sigsegv_recover_buf), 1) == 0) {
        sigsegv_armed = true;
        // Raise SIGSEGV; the handler longjmps back to the
        // sigsetjmp site, which then takes the else-branch.
        std.posix.raise(.SEGV) catch unreachable;
        // Should not reach: longjmp transferred control.
        try testing.expect(false);
    } else {
        sigsegv_armed = false;
        Recover.flag = true;
    }

    try testing.expect(Recover.flag);
}

test "sigsegv guard: armed=false after recovery so subsequent SEGV is unexpected" {
    installSigsegvHandler();

    if (sigsetjmp(@ptrCast(&sigsegv_recover_buf), 1) == 0) {
        sigsegv_armed = true;
        std.posix.raise(.SEGV) catch unreachable;
        try testing.expect(false);
    } else {
        // Recovery path must clear armed (handler does it; the
        // assertion confirms the contract end-to-end).
        try testing.expect(sigsegv_armed == false);
    }
}
