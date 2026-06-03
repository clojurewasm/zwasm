/* zwasm v2 — C-API conformance: host memory import (§13.4)
 *
 * Validates `wasm_memory_new` + import wiring through the real C ABI:
 * a host-owned linear memory is imported; the host writes bytes and the
 * guest's `i32.load` reads them (shared buffer).
 *
 *   (module
 *     (import "env" "m" (memory 1))
 *     (func (export "r") (result i32) (i32.const 0) (i32.load)))
 *
 * Exits 0 on success.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>

static const uint8_t kMemWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, /* type () -> i32 */
    0x02, 0x0a, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x6d, 0x02, 0x00, 0x01, /* import env.m memory min 1 */
    0x03, 0x02, 0x01, 0x00, /* func[0]: type 0 */
    0x07, 0x05, 0x01, 0x01, 0x72, 0x00, 0x00, /* export "r" -> func 0 */
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x41, 0x00, 0x28, 0x02, 0x00, 0x0b, /* i32.load (i32.const 0) */
};

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    wasm_memorytype_t* mt = NULL;
    wasm_memory_t* hm = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_limits_t lim = { 1, wasm_limits_max_default };
    mt = wasm_memorytype_new(&lim);
    hm = wasm_memory_new(store, mt);
    if (!hm) { fputs("wasm_memory_new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kMemWasm), (wasm_byte_t*) kMemWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_t* import_externs[1] = { wasm_memory_as_extern(hm) };
    wasm_extern_vec_t imports = { 1, import_externs };
    instance = wasm_instance_new(store, module, &imports, NULL);
    if (!instance) { fputs("wasm_instance_new failed\n", stderr); goto cleanup; }

    /* host writes the shared buffer; guest i32.load sees it. */
    uint8_t* data = (uint8_t*) wasm_memory_data(hm);
    if (!data) { fputs("wasm_memory_data null\n", stderr); goto cleanup; }
    data[0] = 42;

    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0]) { fputs("no exports\n", stderr); goto cleanup; }
    wasm_func_t* rf = wasm_extern_as_func(exports.data[0]);
    if (!rf) { fputs("export not a func\n", stderr); goto cleanup; }

    wasm_val_vec_t args = { 0, NULL };
    wasm_val_t results_data[1];
    memset(results_data, 0, sizeof(results_data));
    wasm_val_vec_t results = { 1, results_data };
    wasm_trap_t* trap = wasm_func_call(rf, &args, &results);
    if (trap) { fputs("guest call trapped\n", stderr); wasm_trap_delete(trap); goto cleanup; }

    printf("zwasm c_api_conformance/memory_import: i32.load(0) = %d\n", results_data[0].of.i32);
    rc = (results_data[0].kind == WASM_I32 && results_data[0].of.i32 == 42) ? 0 : 2;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (hm) wasm_memory_delete(hm);
    if (mt) wasm_memorytype_delete(mt);
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
