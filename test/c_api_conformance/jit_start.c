/* zwasm v2 — C-API conformance: start function under JIT (D-478).
 *
 * A `(start $init)` MUST run at instantiation. Before this fix `instantiateJit`
 * returned without invoking it, so JIT-backed instances silently skipped their
 * start function (a latent correctness gap, and a prerequisite for the
 * `.auto`->JIT flip). The module's start sets a global to 42; the exported
 * `get` reads it back — 42 proves the start ran under the JIT engine.
 *
 *   (module
 *     (global $g (mut i32) (i32.const 0))
 *     (func $init (global.set $g (i32.const 42)))
 *     (func (export "get") (result i32) (global.get $g))
 *     (start $init))
 *
 * Exits 0 on success. Run by `test-c-api-conformance`.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

static const uint8_t kStartWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01, 0x7f, /* type0 ()->(), type1 ()->(i32) */
    0x03, 0x03, 0x02, 0x00, 0x01,                               /* func[0]:type0 (init), func[1]:type1 (get) */
    0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x00, 0x0b,             /* global $g (mut i32) = 0 */
    0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x01,       /* export "get" -> func 1 */
    0x08, 0x01, 0x00,                                           /* start -> func 0 */
    0x0a, 0x0d, 0x02,                                           /* code: 2 funcs */
    0x06, 0x00, 0x41, 0x2a, 0x24, 0x00, 0x0b,                   /* init: i32.const 42; global.set 0; end */
    0x04, 0x00, 0x23, 0x00, 0x0b,                               /* get: global.get 0; end */
};

/* (module (func $boom unreachable) (start $boom)) — a trapping start MUST fail
 * instantiation (not be silently skipped). */
static const uint8_t kBoomWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,       /* type ()->() */
    0x03, 0x02, 0x01, 0x00,                   /* func[0]:type0 */
    0x08, 0x01, 0x00,                         /* start -> func 0 */
    0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b, /* boom: unreachable; end */
};

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    wasm_byte_vec_t binary = { sizeof(kStartWasm), (wasm_byte_t*) kStartWasm };
    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    wasm_extern_vec_t imports = { 0, NULL };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, ZWASM_ENGINE_JIT);
    if (!instance) { fputs("zwasm_instance_new_ex(JIT) failed\n", stderr); goto cleanup; }

    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0] ||
        wasm_extern_kind(exports.data[0]) != WASM_EXTERN_FUNC) {
        fputs("missing get export\n", stderr); goto cleanup;
    }
    wasm_func_t* get = wasm_extern_as_func(exports.data[0]);

    wasm_val_vec_t no_args = { 0, NULL };
    wasm_val_t res_data[1];
    memset(res_data, 0, sizeof(res_data));
    wasm_val_vec_t res = { 1, res_data };
    if (wasm_func_call(get, &no_args, &res)) { fputs("get() trapped\n", stderr); goto cleanup; }
    if (res_data[0].kind != WASM_I32 || res_data[0].of.i32 != 42) {
        fprintf(stderr, "get() = %d != 42 (start did not run)\n", res_data[0].of.i32);
        goto cleanup;
    }

    /* A trapping start must FAIL instantiation (return NULL), not be skipped. */
    {
        wasm_byte_vec_t bbin = { sizeof(kBoomWasm), (wasm_byte_t*) kBoomWasm };
        wasm_module_t* bmod = wasm_module_new(store, &bbin);
        if (!bmod) { fputs("boom module_new failed\n", stderr); goto cleanup; }
        wasm_extern_vec_t bimp = { 0, NULL };
        wasm_trap_t* btrap = NULL;
        wasm_instance_t* binst = zwasm_instance_new_ex(store, bmod, &bimp, &btrap, ZWASM_ENGINE_JIT);
        int failed_as_expected = (binst == NULL);
        if (binst) wasm_instance_delete(binst);
        if (btrap) wasm_trap_delete(btrap);
        wasm_module_delete(bmod);
        if (!failed_as_expected) {
            fputs("trapping start did NOT fail instantiation\n", stderr);
            goto cleanup;
        }
    }

    printf("zwasm c_host (JIT start): get()=%d; trapping-start rejected\n", res_data[0].of.i32);
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
