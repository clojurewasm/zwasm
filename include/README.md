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

`wasi.h` (Phase 4) lives alongside `wasm.h` here. **Unlike
`wasm.h`, `wasi.h` is hand-authored**, not vendored — see
[`.dev/decisions/0005_phase4_wasi_h_authorship.md`](../.dev/decisions/0005_phase4_wasi_h_authorship.md)
for the rationale (no single canonical upstream `wasi.h` exists
for host-side WASI embedding). Edit `wasi.h` directly; the
`zwasm_wasi_*` symbols are project extensions.

`zwasm.h` also lives here. `wasm.h` is the primary C ABI; the
`zwasm.h` / `wasi.h` extensions are subordinate to it and are
pre-1.0 (may change until 1.0).

## build.zig wiring

`build.zig` adds this directory to the Zig module include path so
C-API code can `@cImport(@cInclude("wasm.h"))`. Header-parse smoke
testing belongs at the C-API binding level rather than the
unit-test layer, so the unit tests stay host-portable (Zig's
`translate-c` is not run there).
