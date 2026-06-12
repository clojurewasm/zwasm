//! Component-Model validation (ADR-0176) — structural-first, incremental.
//!
//! Walks the decoded `TypeInfo` (NO re-parse — the deliberate divergence from
//! wasm-tools, which interleaves validate-with-decode) and rejects invalid
//! components before instantiation, mirroring wasmtime's reject-invalid
//! behaviour (ADR-0170 wasmtime-equivalent goal). Each rule lands as one TDD
//! chunk under the E3-CM-validation bundle, driven by the official
//! `WebAssembly/component-model/test/wasm-tools` `assert_invalid` corpus.
//!
//! Rule 1 (this file's first rule): **type-index bounds** for value types.
//! Every `ValType.type_index` (recursively inside a top-level deftype) and
//! every `own`/`borrow` resource-type index must be `<` the type-index-space
//! length. Catches the most-frequent corpus category ("type index out of
//! bounds", ~39 cases).
//!
//! Zone 1 (`feature/component/`): pure logic, no host orchestration (ADR-0172).

const std = @import("std");
const types = @import("types.zig");

const TypeInfo = types.TypeInfo;
const DefType = types.DefType;
const ValType = types.ValType;
const Error = types.Error;

/// Component-Model spec (Binary.md / validation) — reject a component whose
/// decoded `TypeInfo` violates a structural rule. Called after
/// `decodeTypeInfo()`, before instantiation.
pub fn validate(info: *const TypeInfo) Error!void {
    // Bounds-check against the TRUE type-index-space size (type defs + type
    // aliases + type imports + type exports), NOT `deftypes.len` — a valid
    // reference to an aliased/imported type lives past the type-section count.
    const type_space_len = info.type_space_len;
    for (info.deftypes.items) |dt| {
        try checkDefTypeIndices(dt, type_space_len);
        try checkDefTypeLabels(dt);
    }
    try checkCanons(info, type_space_len);
    try checkAliases(info);
    for (info.imports.items) |imp| {
        try checkExternDesc(imp.desc, type_space_len);
        try checkExternName(imp.name);
    }
    for (info.exports.items) |ex| {
        if (ex.desc) |d| try checkExternDesc(d, type_space_len);
        try checkExternName(ex.name);
    }
}

/// Rule 5: name format. Every label-carrying deftype member (func param,
/// record field, variant case, enum/flags label) must be in kebab case per
/// the Explainer.md `label` grammar. Nested `instance`/`component` type
/// scopes are deferred (consistent with rule 1 — never a false-positive).
fn checkDefTypeLabels(dt: DefType) Error!void {
    switch (dt) {
        .func => |ft| for (ft.params) |p| try checkLabel(p.name),
        .record => |rec| for (rec.fields) |f| try checkLabel(f.name),
        .variant => |v| for (v.cases) |c| try checkLabel(c.name),
        .enum_ => |e| for (e.labels) |l| try checkLabel(l),
        .flags => |fl| for (fl.labels) |l| try checkLabel(l),
        .value, .list, .tuple, .option, .result, .own, .borrow => {},
        .instance_type, .component_type => {},
    }
}

/// Rule 5: import/export name format (Explainer.md `importname`/`exportname`).
/// Dispatches on the name's shape:
/// - `=`-carrying forms (`locked-dep=…`/`unlocked-dep=…`/`url=…`/`integrity=…`)
///   are accepted unchecked — their grammars are deferred (false-negative at
///   worst, never a false-positive).
/// - `:`-carrying `interfacename` (`namespace:package/interface@version`):
///   each `:`/`/` segment before the `@` must be a label. (The spec restricts
///   namespace/package to lowercase; the general label check is deliberately
///   more permissive — deferred refinement, false-negative direction only.
///   The `@version` semver grammar is likewise deferred.)
/// - `[constructor]l` / `[method]l.l` / `[static]l.l`: label parts checked;
///   other bracket forms (async) are deferred.
/// - anything else is a `plainname` → plain kebab label.
fn checkExternName(name: []const u8) Error!void {
    if (name.len == 0) return Error.InvalidName;
    if (std.mem.findScalar(u8, name, '=') != null) return;
    if (std.mem.findScalar(u8, name, ':') != null) {
        const base = if (std.mem.findScalar(u8, name, '@')) |at| name[0..at] else name;
        var it = std.mem.splitAny(u8, base, ":/");
        while (it.next()) |segment| try checkLabel(segment);
        return;
    }
    if (name[0] == '[') {
        const close = std.mem.findScalar(u8, name, ']') orelse return Error.InvalidName;
        const kind = name[1..close];
        const rest = name[close + 1 ..];
        if (std.mem.eql(u8, kind, "constructor")) return checkLabel(rest);
        if (std.mem.eql(u8, kind, "method") or std.mem.eql(u8, kind, "static")) {
            const dot = std.mem.findScalar(u8, rest, '.') orelse return Error.InvalidName;
            try checkLabel(rest[0..dot]);
            return checkLabel(rest[dot + 1 ..]);
        }
        return; // other bracket forms (async lift/lower) — deferred
    }
    return checkLabel(name);
}

/// Explainer.md `label` grammar: `label ::= <fragment> ('-' <fragment>)*`
/// where the first fragment is `[a-z][0-9a-z]*` or `[A-Z][0-9A-Z]*` (starts
/// with a letter) and later fragments are `[0-9a-z]+` or `[0-9A-Z]+` (may
/// start with a digit). Mixing cases WITHIN a fragment, empty fragments
/// (leading/trailing/double `-`), and the empty label are invalid.
fn checkLabel(label: []const u8) Error!void {
    if (label.len == 0) return Error.InvalidName;
    var it = std.mem.splitScalar(u8, label, '-');
    var first = true;
    while (it.next()) |fragment| {
        if (fragment.len == 0) return Error.InvalidName;
        if (first and std.ascii.isDigit(fragment[0])) return Error.InvalidName;
        var all_lower = true;
        var all_upper = true;
        for (fragment) |ch| {
            if (!(std.ascii.isDigit(ch) or std.ascii.isLower(ch))) all_lower = false;
            if (!(std.ascii.isDigit(ch) or std.ascii.isUpper(ch))) all_upper = false;
        }
        if (!all_lower and !all_upper) return Error.InvalidName;
        first = false;
    }
}

/// Rule 4: an import/export `externdesc` that ascribes a type must reference an
/// in-bounds type. `func`/`component`/`instance` are type indices (the ascribed
/// def-type); `type_bound (eq i)` references type `i`; `value` carries a valtype.
/// `core_module` (core-module index space) is deferred — the count is not yet
/// surfaced on `TypeInfo` (a false-negative at worst, never a false-positive).
fn checkExternDesc(desc: types.ExternDesc, type_space_len: u32) Error!void {
    switch (desc) {
        .func, .component, .instance => |idx| if (idx >= type_space_len) return Error.InvalidExternDesc,
        .type_bound => |tb| switch (tb) {
            .eq => |idx| if (idx >= type_space_len) return Error.InvalidExternDesc,
            .sub_resource => {},
        },
        .value_bound => |vb| if (vb) |vt| try checkValType(vt, type_space_len),
        .core_module => {}, // core-module index space count not yet on TypeInfo — deferred
    }
}

/// Rule 3: an `alias` of an instance export must name an in-bounds instance.
/// `core_export` → core-instance space (`core_instances`), `component_export` →
/// component-instance space (`instance_origins`). Bounds are the final space
/// size — a gross OOB (the corpus "instance index out of bounds" category) is
/// caught; definition-order forward-reference refinement + export-name existence
/// are deferred (a false-negative at worst, never a false-positive). `outer`
/// aliases need nesting-depth tracking and are deferred likewise.
fn checkAliases(info: *const TypeInfo) Error!void {
    const core_inst_len: u32 = @intCast(info.core_instances.items.len);
    const comp_inst_len: u32 = @intCast(info.instance_origins.items.len);
    for (info.aliases.items) |al| switch (al.target) {
        .core_export => |ce| if (ce.instance >= core_inst_len) return Error.InvalidAlias,
        .component_export => |ce| if (ce.instance >= comp_inst_len) return Error.InvalidAlias,
        .outer => {}, // needs nesting-depth tracking — deferred rule
    };
}

/// Rule 2: bounds-check every index a `canon` definition references against its
/// index space — `lift` (core-func + component-func type), `lower` (component
/// func), and the resource builtins (type). The core-/component-func lists ARE
/// their index spaces (every minting form appends), so `.items.len` is exact
/// here (unlike `deftypes.len` for the type space — see rule 1).
fn checkCanons(info: *const TypeInfo, type_space_len: u32) Error!void {
    const core_func_len: u32 = @intCast(info.core_funcs.items.len);
    const comp_func_len: u32 = @intCast(info.component_funcs.items.len);
    for (info.canons.items) |c| switch (c) {
        .lift => |l| {
            if (l.core_func >= core_func_len) return Error.InvalidCanon;
            if (l.type_index >= type_space_len) return Error.InvalidTypeIndex;
        },
        .lower => |l| if (l.func >= comp_func_len) return Error.InvalidCanon,
        .resource_new, .resource_drop, .resource_rep => |t| if (t >= type_space_len) return Error.InvalidTypeIndex,
    };
}

/// Rule 1: bounds-check every type-index a top-level deftype references against
/// the type-index-space length. Nested `instance`/`component` type scopes carry
/// their own index spaces and are deferred to a later rule (no false positives).
fn checkDefTypeIndices(dt: DefType, type_space_len: u32) Error!void {
    switch (dt) {
        .value => |vt| try checkValType(vt, type_space_len),
        .func => |ft| {
            for (ft.params) |p| try checkValType(p.ty, type_space_len);
            if (ft.result) |r| try checkValType(r, type_space_len);
        },
        .record => |rec| for (rec.fields) |f| try checkValType(f.ty, type_space_len),
        .tuple => |t| for (t.types) |vt| try checkValType(vt, type_space_len),
        .list => |l| try checkValType(l.element.*, type_space_len),
        .option => |o| try checkValType(o.payload.*, type_space_len),
        .variant => |v| for (v.cases) |c| {
            if (c.payload) |p| try checkValType(p, type_space_len);
        },
        .result => |res| {
            if (res.ok) |ok| try checkValType(ok, type_space_len);
            if (res.err) |er| try checkValType(er, type_space_len);
        },
        .own, .borrow => |idx| if (idx >= type_space_len) return Error.InvalidTypeIndex,
        // No type-index references in their immediate form:
        .enum_, .flags => {},
        // Nested type scopes — deferred to a later structural rule.
        .instance_type, .component_type => {},
    }
}

fn checkValType(vt: ValType, type_space_len: u32) Error!void {
    switch (vt) {
        .primitive => {},
        .type_index => |idx| if (idx >= type_space_len) return Error.InvalidTypeIndex,
    }
}

test "rule 5: label grammar boundaries" {
    // Valid: single word, multi-fragment, acronym fragment, digit-led later fragment.
    try checkLabel("a");
    try checkLabel("foo-bar");
    try checkLabel("foo-BAR2");
    try checkLabel("a-1");
    try checkLabel("WASI");
    // Invalid: empty, case-mix within a fragment, empty fragments, digit-led first.
    try std.testing.expectError(Error.InvalidName, checkLabel(""));
    try std.testing.expectError(Error.InvalidName, checkLabel("TyPeS"));
    try std.testing.expectError(Error.InvalidName, checkLabel("Foo"));
    try std.testing.expectError(Error.InvalidName, checkLabel("foo--bar"));
    try std.testing.expectError(Error.InvalidName, checkLabel("-foo"));
    try std.testing.expectError(Error.InvalidName, checkLabel("foo-"));
    try std.testing.expectError(Error.InvalidName, checkLabel("1foo"));
    try std.testing.expectError(Error.InvalidName, checkLabel("foo_bar"));
}

test "rule 5: extern name forms" {
    // interfacename: segments label-checked, @version skipped.
    try checkExternName("wasi:cli/environment@0.2.3");
    try checkExternName("wasi:io/streams");
    try std.testing.expectError(Error.InvalidName, checkExternName("wasi:cLi/x"));
    // bracket forms.
    try checkExternName("[constructor]blob");
    try checkExternName("[method]blob.get-size");
    try checkExternName("[static]blob.merge");
    try std.testing.expectError(Error.InvalidName, checkExternName("[method]no-dot"));
    try std.testing.expectError(Error.InvalidName, checkExternName("[constructor]Bad"));
    // deferred `=` forms accepted unchecked.
    try checkExternName("unlocked-dep=<a:b/c>");
    // plainname falls through to the label grammar.
    try checkExternName("hello");
    try std.testing.expectError(Error.InvalidName, checkExternName("NevEr"));
    try std.testing.expectError(Error.InvalidName, checkExternName(""));
}
