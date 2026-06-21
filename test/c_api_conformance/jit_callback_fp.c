/* zwasm v2 — C-API conformance: FP host callbacks under JIT (D-478).
 *
 * Extends jit_callback_args.c (GP scalars) to f32/f64 host imports. FP args ride
 * a SEPARATE register class from integers, so the bridge thunk must declare each
 * FP position with its exact type (the GP `u64`-collapse does not apply). Three
 * cases exercise: an f64 arg, an FP (f32) result with no args, and a mixed
 * GP+FP arg list:
 *
 *   dscale: (import "env" "h" (func (param f64) (result f64)))   h(x)=x*1.5 -> f(20)=30
 *   fret:   (import "env" "h" (func (result f32)))               h()=2.5    -> f()=2.5
 *   mixed:  (import "env" "h" (func (param i32 f64) (result f64))) h(n,x)=n+x -> f(2,40)=42
 *
 * Exits 0 on success. Run by `test-c-api-conformance`.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <wasm.h>
#include <zwasm.h>

/* (module (import "env" "h" (func (param f64) (result f64)))
 *   (func (export "f") (param f64) (result f64) local.get 0 call 0)) */
static const uint8_t kDscaleWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x06, 0x01, 0x60, 0x01, 0x7c, 0x01, 0x7c,       /* type (f64)->(f64) */
    0x02, 0x09, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x68, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x01,
    0x0a, 0x08, 0x01, 0x06, 0x00, 0x20, 0x00, 0x10, 0x00, 0x0b,
};

/* (module (import "env" "h" (func (result f32)))
 *   (func (export "f") (result f32) call 0)) */
static const uint8_t kFretWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7d,             /* type ()->(f32) */
    0x02, 0x09, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x68, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x01,
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x10, 0x00, 0x0b,
};

/* (module (import "env" "h" (func (param i32 f64) (result f64)))
 *   (func (export "f") (result f64) i32.const 2 f64.const 40.0 call 0))
 * The export is 0-arg (pushes the host-call args internally) to isolate the host
 * bridge from the JIT export-invoke arg path (mixed GP+FP export params are a
 * separate D-477 concern). */
static const uint8_t kMixedWasm[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0b, 0x02, 0x60, 0x02, 0x7f, 0x7c, 0x01, 0x7c, 0x60, 0x00, 0x01, 0x7c, /* type0 (i32 f64)->(f64), type1 ()->(f64) */
    0x02, 0x09, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x68, 0x00, 0x00, /* import env.h : type0 */
    0x03, 0x02, 0x01, 0x01,                               /* func[1] : type1 */
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x01,             /* export "f" -> 1 */
    0x0a, 0x11, 0x01, 0x0f, 0x00, 0x41, 0x02, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x44, 0x40, 0x10, 0x00, 0x0b,
};

static wasm_trap_t* h_dscale(const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    results->data[0].kind = WASM_F64;
    results->data[0].of.f64 = args->data[0].of.f64 * 1.5;
    return NULL;
}
static wasm_trap_t* h_fret(const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    (void) args;
    results->data[0].kind = WASM_F32;
    results->data[0].of.f32 = 2.5f;
    return NULL;
}
static wasm_trap_t* h_mixed(const wasm_val_vec_t* args, wasm_val_vec_t* results) {
    results->data[0].kind = WASM_F64;
    results->data[0].of.f64 = (double) args->data[0].of.i32 + args->data[1].of.f64;
    return NULL;
}

static int run_case(wasm_store_t* store, const uint8_t* wasm, size_t wasm_len,
                    wasm_functype_t* ft, wasm_func_callback_t cb,
                    wasm_val_vec_t* args, wasm_val_t* out) {
    int ok = 0;
    wasm_func_t* host_fn = wasm_func_new(store, ft, cb);
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    if (!host_fn) goto done;

    wasm_byte_vec_t binary = { wasm_len, (wasm_byte_t*) wasm };
    module = wasm_module_new(store, &binary);
    if (!module) goto done;

    wasm_extern_t* import_externs[1] = { wasm_func_as_extern(host_fn) };
    wasm_extern_vec_t imports = { 1, import_externs };
    wasm_trap_t* itrap = NULL;
    instance = zwasm_instance_new_ex(store, module, &imports, &itrap, ZWASM_ENGINE_JIT);
    if (!instance) goto done;

    wasm_instance_exports(instance, &exports);
    if (exports.size < 1 || !exports.data[0] ||
        wasm_extern_kind(exports.data[0]) != WASM_EXTERN_FUNC) goto done;
    wasm_func_t* f = wasm_extern_as_func(exports.data[0]);

    wasm_val_t res_data[1];
    memset(res_data, 0, sizeof(res_data));
    wasm_val_vec_t res = { 1, res_data };
    if (wasm_func_call(f, args, &res)) goto done;
    *out = res_data[0];
    ok = 1;

done:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (host_fn) wasm_func_delete(host_fn);
    return ok;
}

int main(void) {
    int rc = 1;
    wasm_engine_t* engine = wasm_engine_new();
    wasm_store_t* store = engine ? wasm_store_new(engine) : NULL;
    wasm_functype_t* ft_dscale = NULL;
    wasm_functype_t* ft_fret = NULL;
    wasm_functype_t* ft_mixed = NULL;
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    /* dscale(f64)->f64: f(20.0) == 30.0 */
    ft_dscale = wasm_functype_new_1_1(wasm_valtype_new(WASM_F64), wasm_valtype_new(WASM_F64));
    wasm_val_t ds_args_data[1] = { { .kind = WASM_F64, .of = { .f64 = 20.0 } } };
    wasm_val_vec_t ds_args = { 1, ds_args_data };
    wasm_val_t ds_out;
    memset(&ds_out, 0, sizeof(ds_out));
    if (!run_case(store, kDscaleWasm, sizeof(kDscaleWasm), ft_dscale, h_dscale, &ds_args, &ds_out)) {
        fputs("dscale case failed\n", stderr); goto cleanup;
    }
    if (ds_out.kind != WASM_F64 || ds_out.of.f64 != 30.0) {
        fprintf(stderr, "dscale f(20) = %f != 30\n", ds_out.of.f64); goto cleanup;
    }

    /* fret()->f32: f() == 2.5 */
    ft_fret = wasm_functype_new_0_1(wasm_valtype_new(WASM_F32));
    wasm_val_vec_t fr_args = { 0, NULL };
    wasm_val_t fr_out;
    memset(&fr_out, 0, sizeof(fr_out));
    if (!run_case(store, kFretWasm, sizeof(kFretWasm), ft_fret, h_fret, &fr_args, &fr_out)) {
        fputs("fret case failed\n", stderr); goto cleanup;
    }
    if (fr_out.kind != WASM_F32 || fr_out.of.f32 != 2.5f) {
        fprintf(stderr, "fret f() = %f != 2.5\n", (double) fr_out.of.f32); goto cleanup;
    }

    /* host h:(i32,f64)->f64; guest f:()->f64 calls h(2, 40.0) -> 42.0 */
    wasm_valtype_t* mx_ps[2] = { wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_F64) };
    wasm_valtype_vec_t mx_params, mx_results;
    wasm_valtype_vec_new(&mx_params, 2, mx_ps);
    wasm_valtype_t* mx_r[1] = { wasm_valtype_new(WASM_F64) };
    wasm_valtype_vec_new(&mx_results, 1, mx_r);
    ft_mixed = wasm_functype_new(&mx_params, &mx_results);
    wasm_val_vec_t mx_args = { 0, NULL };
    wasm_val_t mx_out;
    memset(&mx_out, 0, sizeof(mx_out));
    if (!run_case(store, kMixedWasm, sizeof(kMixedWasm), ft_mixed, h_mixed, &mx_args, &mx_out)) {
        fputs("mixed case failed\n", stderr); goto cleanup;
    }
    if (mx_out.kind != WASM_F64 || mx_out.of.f64 != 42.0) {
        fprintf(stderr, "mixed f(2,40) = %f != 42\n", mx_out.of.f64); goto cleanup;
    }

    printf("zwasm c_host (JIT FP): dscale(20)=%g fret()=%g mixed(2,40)=%g\n",
           ds_out.of.f64, (double) fr_out.of.f32, mx_out.of.f64);
    rc = 0;

cleanup:
    if (ft_dscale) wasm_functype_delete(ft_dscale);
    if (ft_fret) wasm_functype_delete(ft_fret);
    if (ft_mixed) wasm_functype_delete(ft_mixed);
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
