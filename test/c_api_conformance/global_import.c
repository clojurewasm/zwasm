/* zwasm v2 — C-API conformance: host global import (§13.4)
 *
 * Validates the §13.2 host-entity construction (`wasm_global_new`) +
 * import wiring through the real wasm-c-api C ABI: a host-owned mutable
 * global is imported, the guest reads it, the host mutates it, and the
 * guest re-read sees the shared cell.
 *
 *   (module
 *     (import "env" "g" (global (mut i32)))
 *     (func (export "get") (result i32) (global.get 0)))
 *
 * Exits 0 on success.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>

static const uint8_t kGlobalWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, /* type () -> i32 */
    0x02, 0x0a, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x67, 0x03, 0x7f, 0x01, /* import env.g global (mut i32) */
    0x03, 0x02, 0x01, 0x00, /* func[0]: type 0 */
    0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, /* export "get" -> func 0 */
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x23, 0x00, 0x0b, /* code: global.get 0 */
};

static int32_t call_get(wasm_func_t* f) {
    wasm_val_vec_t args = { 0, NULL };
    wasm_val_t results_data[1];
    memset(results_data, 0, sizeof(results_data));
    wasm_val_vec_t results = { 1, results_data };
    wasm_trap_t* trap = wasm_func_call(f, &args, &results);
    if (trap) { wasm_trap_delete(trap); return -1; }
    return results_data[0].of.i32;
}

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    wasm_globaltype_t* gt = NULL;
    wasm_global_t* hg = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    /* host mutable i32 global = 10 */
    gt = wasm_globaltype_new(wasm_valtype_new(WASM_I32), WASM_VAR);
    wasm_val_t init = { .kind = WASM_I32, .of = { .i32 = 10 } };
    hg = wasm_global_new(store, gt, &init);
    if (!hg) { fputs("wasm_global_new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kGlobalWasm), (wasm_byte_t*) kGlobalWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_t* import_externs[1] = { wasm_global_as_extern(hg) };
    wasm_extern_vec_t imports = { 1, import_externs };
    instance = wasm_instance_new(store, module, &imports, NULL);
    if (!instance) { fputs("wasm_instance_new failed\n", stderr); goto cleanup; }

    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0]) { fputs("no exports\n", stderr); goto cleanup; }
    wasm_func_t* getf = wasm_extern_as_func(exports.data[0]);
    if (!getf) { fputs("export not a func\n", stderr); goto cleanup; }

    /* guest reads the host's initial value, then sees the host's mutation. */
    int32_t v0 = call_get(getf);
    wasm_val_t twenty = { .kind = WASM_I32, .of = { .i32 = 20 } };
    wasm_global_set(hg, &twenty);
    int32_t v1 = call_get(getf);

    /* and host get reads back the same shared cell. */
    wasm_val_t host_read;
    wasm_global_get(hg, &host_read);

    printf("zwasm c_api_conformance/global_import: get=%d then %d, host=%d\n", v0, v1, host_read.of.i32);
    rc = (v0 == 10 && v1 == 20 && host_read.kind == WASM_I32 && host_read.of.i32 == 20) ? 0 : 2;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (hg) wasm_global_delete(hg);
    if (gt) wasm_globaltype_delete(gt);
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
