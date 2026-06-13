/* zwasm v2 — C-API conformance: WASI preopen smoke (ADR-0184 step 4)
 *
 * End-to-end exercise of the preopen surface through the real C ABI:
 * the host makes a temp directory containing `hello.txt`, queues it
 * via `zwasm_wasi_config_preopen_dir`, and instantiates a wasi guest
 * (wasi_preopen_guest.wat, passed as argv[1]) whose `_start`
 * path_opens + fd_reads the file and verifies its first byte. The
 * guest returns normally on success; any failure proc_exits nonzero,
 * which surfaces here as a trap.
 *
 * Exits 0 on success.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#include <direct.h>
#define make_dir(path) _mkdir(path)
#else
#include <sys/stat.h>
#define make_dir(path) mkdir(path, 0700)
#endif

#include <wasm.h>
#include <wasi.h>

static const char kFileContent[] = "preopen!";

/* mkdir <tmp>/zwasm_c_preopen + write hello.txt; returns 0 on success. */
static int setup_fixture_dir(char* dir, size_t dir_cap) {
    const char* base = getenv("TMPDIR");
    if (!base) base = getenv("TEMP");
    if (!base) base = "/tmp";
    int n = snprintf(dir, dir_cap, "%s/zwasm_c_preopen", base);
    if (n < 0 || (size_t) n >= dir_cap) return 1;
    make_dir(dir); /* may already exist from a prior run; file write decides */

    char file[1024];
    n = snprintf(file, sizeof file, "%s/hello.txt", dir);
    if (n < 0 || (size_t) n >= sizeof file) return 1;
    FILE* f = fopen(file, "wb");
    if (!f) return 1;
    size_t wrote = fwrite(kFileContent, 1, sizeof kFileContent - 1, f);
    fclose(f);
    return wrote == sizeof kFileContent - 1 ? 0 : 1;
}

static int read_file(const char* path, wasm_byte_vec_t* out) {
    FILE* f = fopen(path, "rb");
    if (!f) return 1;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 1; }
    long len = ftell(f);
    if (len <= 0) { fclose(f); return 1; }
    rewind(f);
    wasm_byte_vec_new_uninitialized(out, (size_t) len);
    if (!out->data || fread(out->data, 1, (size_t) len, f) != (size_t) len) {
        fclose(f);
        return 1;
    }
    fclose(f);
    return 0;
}

int main(int argc, char** argv) {
    int rc = 1;
    if (argc < 2) { fputs("usage: wasi_preopen <guest.wasm>\n", stderr); return 1; }

    char dir[1024];
    if (setup_fixture_dir(dir, sizeof dir) != 0) {
        fputs("fixture dir setup failed\n", stderr);
        return 1;
    }

    wasm_engine_t* engine = NULL;
    wasm_store_t* store = NULL;
    wasm_module_t* module = NULL;
    wasm_instance_t* instance = NULL;
    wasm_extern_vec_t exports = { 0, NULL };
    wasm_byte_vec_t binary = { 0, NULL };

    if (read_file(argv[1], &binary) != 0) { fputs("guest wasm read failed\n", stderr); goto cleanup; }

    engine = wasm_engine_new();
    store = engine ? wasm_store_new(engine) : NULL;
    if (!engine || !store) { fputs("engine/store new failed\n", stderr); goto cleanup; }

    zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
    if (!cfg) { fputs("wasi config new failed\n", stderr); goto cleanup; }
    if (!zwasm_wasi_config_preopen_dir(cfg, dir, "/")) {
        fputs("preopen_dir failed\n", stderr);
        zwasm_wasi_config_delete(cfg);
        goto cleanup;
    }
    zwasm_store_set_wasi(store, cfg); /* takes ownership of cfg */

    module = wasm_module_new(store, &binary);
    if (!module) { fputs("wasm_module_new failed\n", stderr); goto cleanup; }

    instance = wasm_instance_new(store, module, NULL, NULL);
    if (!instance) { fputs("wasm_instance_new failed (preopen open?)\n", stderr); goto cleanup; }

    /* exports = memory, _start — scan for the (only) func. */
    wasm_instance_exports(instance, &exports);
    wasm_func_t* start = NULL;
    for (size_t i = 0; i < exports.size; i++) {
        if (exports.data[i] && (start = wasm_extern_as_func(exports.data[i]))) break;
    }
    if (!start) { fputs("_start export not found\n", stderr); goto cleanup; }

    wasm_val_vec_t args = { 0, NULL };
    wasm_val_vec_t results = { 0, NULL };
    wasm_trap_t* trap = wasm_func_call(start, &args, &results);
    if (trap) {
        wasm_message_t msg;
        wasm_trap_message(trap, &msg);
        fprintf(stderr, "guest trapped: %.*s\n", (int) msg.size, msg.data ? msg.data : "");
        wasm_byte_vec_delete(&msg);
        wasm_trap_delete(trap);
        goto cleanup;
    }

    printf("zwasm c_api_conformance/wasi_preopen: guest read %s/hello.txt OK\n", dir);
    rc = 0;

cleanup:
    if (exports.data) wasm_extern_vec_delete(&exports);
    if (instance) wasm_instance_delete(instance);
    if (module) wasm_module_delete(module);
    if (binary.data) wasm_byte_vec_delete(&binary);
    if (store) wasm_store_delete(store);
    if (engine) wasm_engine_delete(engine);
    return rc;
}
