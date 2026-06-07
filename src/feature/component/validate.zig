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
    }
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
