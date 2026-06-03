/* zwasm v2 — C-API conformance: host table import (§13.4)
 *
 * Validates `wasm_table_new` + import wiring through the real C ABI:
 * a host-owned funcref table is imported; the guest's `table.size`
 * sees the host table's size.
 *
 *   (module
 *     (import "env" "t" (table 3 funcref))
 *     (func (export "sz") (result i32) (table.size 0)))
 *
 * Exits 0 on success.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>

static const uint8_t kTableWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, /* type () -> i32 */
    0x02, 0x0b, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x74, 0x01, 0x70, 0x00, 0x03, /* import env.t table funcref min 3 */
    0x03, 0x02, 0x01, 0x00, /* func[0]: type 0 */
    0x07, 0x06, 0x01, 0x02, 0x73, 0x7a, 0x00, 0x00, /* export "sz" -> func 0 */
    0x0a, 0x07, 0x01, 0x05, 0x00, 0xfc, 0x10, 0x00, 0x0b, /* table.size 0 */
};

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    wasm_tabletype_t* tt = NULL;
    wasm_table_t* ht = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_limits_t lim = { 3, wasm_limits_max_default };
    tt = wasm_tabletype_new(wasm_valtype_new(WASM_FUNCREF), &lim);
    ht = wasm_table_new(store, tt, NULL);
    if (!ht) { fputs("wasm_table_new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kTableWasm), (wasm_byte_t*) kTableWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_t* import_externs[1] = { wasm_table_as_extern(ht) };
    wasm_extern_vec_t imports = { 1, import_externs };
    instance = wasm_instance_new(store, module, &imports, NULL);
    if (!instance) { fputs("wasm_instance_new failed\n", stderr); goto cleanup; }

    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0]) { fputs("no exports\n", stderr); goto cleanup; }
    wasm_func_t* szf = wasm_extern_as_func(exports.data[0]);
    if (!szf) { fputs("export not a func\n", stderr); goto cleanup; }

    wasm_val_vec_t args = { 0, NULL };
    wasm_val_t results_data[1];
    memset(results_data, 0, sizeof(results_data));
    wasm_val_vec_t results = { 1, results_data };
    wasm_trap_t* trap = wasm_func_call(szf, &args, &results);
    if (trap) { fputs("guest call trapped\n", stderr); wasm_trap_delete(trap); goto cleanup; }

    printf("zwasm c_api_conformance/table_import: table.size(0) = %d\n", results_data[0].of.i32);
    rc = (results_data[0].kind == WASM_I32 && results_data[0].of.i32 == 3) ? 0 : 2;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (ht) wasm_table_delete(ht);
    if (tt) wasm_tabletype_delete(tt);
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
