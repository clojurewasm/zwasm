# `include/` — vendored C API headers

`wasm.h` is the upstream `WebAssembly/wasm-c-api` header. It is
vendored read-only at the commit hash recorded in
[`.dev/decisions/0004_phase3_wasm_c_api_pin.md`](../.dev/decisions/0004_phase3_wasm_c_api_pin.md).

Do not edit `wasm.h` by hand. To bump the upstream pin:

```sh
# 1. Update WASM_C_API_PIN_DEFAULT in scripts/fetch_wasm_c_api.sh
# 2. Update ADR-0004 with the new hash + rationale
bash scripts/fetch_wasm_c_api.sh
git add include/wasm.h scripts/fetch_wasm_c_api.sh \
    .dev/decisions/0004_phase3_wasm_c_api_pin.md
git commit -m "chore(p3): bump wasm-c-api pin to <newhash> (ADR-0004)"
```

`zwasm.h` (forthcoming, §9.3 follow-on) and `wasi.h` (Phase 4)
will live alongside `wasm.h` here. Per ROADMAP §1.1, `wasm.h` is
the primary C ABI and any `zwasm.h` extensions are subordinate.

## build.zig wiring

`build.zig` adds this directory to the Zig module include path so
any module under `src/c_api/` can do `@cImport(@cInclude
("wasm.h"))` once the binding work in §9.3 / 3.2 lands. A
header-parses smoke test belongs at the C-API binding level, not
the unit-test layer (Zig's `translate-c` doesn't run reliably on
the OrbStack x86_64-on-Rosetta gate, so unit tests stay
host-portable).
