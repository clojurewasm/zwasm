/* zwasm v2 — C-API conformance: call a funcref pulled from a table (D-269)
 *
 * Exercises the STANDARD wasm-c-api indirect path that wasmtime/wasmer
 * expose in plain wasm.h (survey 2026-06-05):
 *
 *   wasm_table_get(table, idx) -> wasm_ref_t*
 *   wasm_ref_as_func(ref)      -> wasm_func_t*
 *   wasm_func_call(func, ...)  -> result
 *
 * The guest exports a funcref table whose slot 0 is a function returning
 * 42 (placed via an active elem segment):
 *
 *   (module
 *     (func (result i32) (i32.const 42))
 *     (table (export "t") 1 1 funcref)
 *     (elem (i32.const 0) func 0))
 *
 * A host embedder reads the table slot, recovers the func, and calls it.
 * Exits 0 iff it returns 42 — i.e. the table-slot funcref encoding
 * (`fromFuncRef` `*FuncEntity` pointer, via `wasm_table_get`'s allocated
 * `*Ref`) decodes through `refAsFuncEntity` into a callable func.
 *
 * NOTE (D-269): the SIBLING path — a funcref RETURNED FROM A CALL, read
 * via `results[i].of.ref` — is NOT yet conformant (`marshalValOut`
 * instance.zig:926 puts the raw `*FuncEntity` payload directly into
 * `of.ref`, which a standard consumer type-confuses for a `*Ref` handle).
 * That is the next chunk (owned-handle ref model, D-269/D-253); its RED
 * repro is recorded in the D-269 debt row.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>

static const uint8_t kFuncrefTableWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x04, 0x05, 0x01, 0x70, 0x01,
    0x01, 0x01, 0x07, 0x05, 0x01, 0x01, 0x74, 0x01, 0x00, 0x09, 0x07, 0x01,
    0x00, 0x41, 0x00, 0x0b, 0x01, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41,
    0x2a, 0x0b,
};

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_ref_t* ref = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kFuncrefTableWasm), (wasm_byte_t*) kFuncrefTableWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t imports = { 0, NULL };
    instance = wasm_instance_new(store, module, &imports, NULL);
    if (!instance) { fputs("wasm_instance_new failed\n", stderr); goto cleanup; }

    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0]) { fputs("no exports\n", stderr); goto cleanup; }
    wasm_table_t* tab = wasm_extern_as_table(exports.data[0]);
    if (!tab) { fputs("export not a table\n", stderr); goto cleanup; }

    /* The standard indirect path: table slot -> ref -> func -> call. */
    ref = wasm_table_get(tab, 0);
    if (!ref) { fputs("wasm_table_get(0) returned null (slot empty or OOB)\n", stderr); goto cleanup; }
    wasm_func_t* f = wasm_ref_as_func(ref);
    if (!f) { fputs("wasm_ref_as_func: table funcref not recoverable as a callable func\n", stderr); goto cleanup; }

    wasm_val_vec_t args = { 0, NULL };
    wasm_val_t results_data[1];
    memset(results_data, 0, sizeof(results_data));
    wasm_val_vec_t results = { 1, results_data };
    wasm_trap_t* trap = wasm_func_call(f, &args, &results);
    if (trap) { fputs("calling the table funcref trapped\n", stderr); wasm_trap_delete(trap); goto cleanup; }

    printf("zwasm c_api_conformance/funcref_table_call: table[0]() = %d\n", results_data[0].of.i32);
    rc = (results_data[0].kind == WASM_I32 && results_data[0].of.i32 == 42) ? 0 : 2;

cleanup:
    if (ref) wasm_ref_delete(ref);
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
