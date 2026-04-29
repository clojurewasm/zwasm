/*
 * test_ffi.c — Comprehensive shared-library (FFI) tests for zwasm C API
 *
 * Loads libzwasm.so / .dylib / zwasm.dll via the platform's dynamic
 * linker (dlopen on POSIX, LoadLibraryA on Windows) and exercises every
 * exported symbol exactly as Python ctypes or other FFI consumers would.
 * This catches PIC / relocation / Debug-mode issues that static-link
 * tests miss (see GitHub issue #11).
 *
 * Build & run:
 *   bash test/c_api/run_ffi_test.sh          # auto-detects platform
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#  include <io.h>      /* _pipe / _write / _close / _open */
#  include <fcntl.h>   /* _O_RDONLY / _O_BINARY */
   typedef HMODULE zw_lib_t;
   typedef HANDLE  zw_thread_t;
   static zw_lib_t zw_dlopen(const char *path) { return LoadLibraryA(path); }
   static void *   zw_dlsym(zw_lib_t h, const char *sym) {
       return (void *)GetProcAddress(h, sym);
   }
   static void     zw_dlclose(zw_lib_t h) { FreeLibrary(h); }
   static const char *zw_dlerror(void) {
       static char buf[128];
       DWORD code = GetLastError();
       snprintf(buf, sizeof(buf), "GetLastError=%lu", (unsigned long)code);
       return buf;
   }
   static void zw_usleep_us(unsigned us) {
       /* Sleep takes ms; round up so we don't busy-spin under 1 ms. */
       Sleep(us < 1000 ? 1 : us / 1000);
   }
   typedef DWORD (WINAPI *zw_thread_fn_t)(LPVOID);
   /* Adapter so we can keep using `void *(*)(void *)` thread bodies. */
   typedef struct { void *(*fn)(void *); void *arg; } zw_thread_ctx_t;
   static DWORD WINAPI zw_thread_trampoline(LPVOID raw) {
       zw_thread_ctx_t *ctx = (zw_thread_ctx_t *)raw;
       ctx->fn(ctx->arg);
       return 0;
   }
   static int zw_thread_create(zw_thread_t *t, void *(*fn)(void *), void *arg,
                               zw_thread_ctx_t *ctx_out) {
       ctx_out->fn = fn;
       ctx_out->arg = arg;
       *t = CreateThread(NULL, 0, zw_thread_trampoline, ctx_out, 0, NULL);
       return *t == NULL ? -1 : 0;
   }
   static int zw_thread_join(zw_thread_t t) {
       WaitForSingleObject(t, INFINITE);
       CloseHandle(t);
       return 0;
   }
   static int zw_pipe(int fds[2]) {
       /* _O_BINARY so the test's raw byte writes don't get \r\n
          translated when the pipe ends are inherited as text fds. */
       return _pipe(fds, 4096, _O_BINARY);
   }
#  define zw_open       _open
#  define zw_close      _close
#  define zw_write      _write
#  define ZW_O_RDONLY   _O_RDONLY
#else
#  include <dlfcn.h>
#  include <unistd.h>
#  include <fcntl.h>
#  include <pthread.h>
   typedef void *    zw_lib_t;
   typedef pthread_t zw_thread_t;
   static zw_lib_t zw_dlopen(const char *path) { return dlopen(path, RTLD_NOW); }
   static void *   zw_dlsym(zw_lib_t h, const char *sym) { return dlsym(h, sym); }
   static void     zw_dlclose(zw_lib_t h) { dlclose(h); }
   static const char *zw_dlerror(void) { return dlerror(); }
   static void zw_usleep_us(unsigned us) { usleep(us); }
   typedef struct { void *(*fn)(void *); void *arg; } zw_thread_ctx_t;
   static int zw_thread_create(zw_thread_t *t, void *(*fn)(void *), void *arg,
                               zw_thread_ctx_t *ctx_out) {
       (void)ctx_out;  /* POSIX takes the body directly, no trampoline. */
       return pthread_create(t, NULL, fn, arg);
   }
   static int zw_thread_join(zw_thread_t t) { return pthread_join(t, NULL); }
   static int zw_pipe(int fds[2]) { return pipe(fds); }
#  define zw_open       open
#  define zw_close      close
#  define zw_write      write
#  define ZW_O_RDONLY   O_RDONLY
#endif

/* ------------------------------------------------------------------ */
/* Test harness                                                        */
/* ------------------------------------------------------------------ */

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

#define ASSERT(cond, msg) do { \
    tests_run++; \
    if (!(cond)) { \
        tests_failed++; \
        fprintf(stderr, "  FAIL: %s (line %d)\n", msg, __LINE__); \
    } else { \
        tests_passed++; \
    } \
} while(0)

#define ASSERT_EQ_U64(a, b, msg) do { \
    uint64_t _a = (a), _b = (b); \
    tests_run++; \
    if (_a != _b) { \
        tests_failed++; \
        fprintf(stderr, "  FAIL: %s — expected %lu, got %lu (line %d)\n", \
                msg, (unsigned long)_b, (unsigned long)_a, __LINE__); \
    } else { \
        tests_passed++; \
    } \
} while(0)

/* ------------------------------------------------------------------ */
/* Function pointer typedefs — mirrors include/zwasm.h                */
/* ------------------------------------------------------------------ */

typedef void *zwasm_module_t;
typedef void *zwasm_config_t;
typedef void *zwasm_wasi_config_t;
typedef void *zwasm_imports_t;
typedef bool (*zwasm_host_fn_callback_t)(void *, const uint64_t *, uint64_t *);

/* Module lifecycle */
typedef zwasm_module_t (*fn_module_new)(const uint8_t *, size_t);
typedef zwasm_module_t (*fn_module_new_wasi)(const uint8_t *, size_t);
typedef zwasm_module_t (*fn_module_new_with_imports)(const uint8_t *, size_t, zwasm_imports_t);
typedef zwasm_module_t (*fn_module_new_configured)(const uint8_t *, size_t, zwasm_config_t);
typedef void (*fn_module_delete)(zwasm_module_t);
typedef bool (*fn_module_validate)(const uint8_t *, size_t);

/* Invocation */
typedef bool (*fn_module_invoke)(zwasm_module_t, const char *, uint64_t *, uint32_t, uint64_t *, uint32_t);
typedef bool (*fn_module_invoke_start)(zwasm_module_t);
typedef void (*fn_module_cancel)(zwasm_module_t);

/* Export introspection */
typedef uint32_t (*fn_export_count)(zwasm_module_t);
typedef const char *(*fn_export_name)(zwasm_module_t, uint32_t);
typedef uint32_t (*fn_export_param_count)(zwasm_module_t, uint32_t);
typedef uint32_t (*fn_export_result_count)(zwasm_module_t, uint32_t);

/* Memory */
typedef uint8_t *(*fn_memory_data)(zwasm_module_t);
typedef size_t (*fn_memory_size)(zwasm_module_t);
typedef bool (*fn_memory_read)(zwasm_module_t, uint32_t, uint32_t, uint8_t *);
typedef bool (*fn_memory_write)(zwasm_module_t, uint32_t, const uint8_t *, uint32_t);

/* Error */
typedef const char *(*fn_last_error)(void);

/* Config */
typedef zwasm_config_t (*fn_config_new)(void);
typedef void (*fn_config_delete)(zwasm_config_t);
typedef void (*fn_config_set_fuel)(zwasm_config_t, uint64_t);
typedef void (*fn_config_set_timeout)(zwasm_config_t, uint64_t);
typedef void (*fn_config_set_max_memory)(zwasm_config_t, uint64_t);
typedef void (*fn_config_set_force_interpreter)(zwasm_config_t, bool);
typedef void (*fn_config_set_cancellable)(zwasm_config_t, bool);

/* Imports */
typedef zwasm_imports_t (*fn_import_new)(void);
typedef void (*fn_import_delete)(zwasm_imports_t);
typedef void (*fn_import_add_fn)(zwasm_imports_t, const char *, const char *,
                                  zwasm_host_fn_callback_t, void *,
                                  uint32_t, uint32_t);

/* WASI config */
typedef zwasm_wasi_config_t (*fn_wasi_config_new)(void);
typedef void (*fn_wasi_config_delete)(zwasm_wasi_config_t);
typedef void (*fn_wasi_config_set_stdio_fd)(zwasm_wasi_config_t, uint32_t, intptr_t, uint8_t);
typedef void (*fn_wasi_config_preopen_fd)(zwasm_wasi_config_t, intptr_t, const char *, size_t, uint8_t, uint8_t);
typedef zwasm_module_t (*fn_module_new_wasi_configured)(const uint8_t *, size_t, zwasm_wasi_config_t);

/* ------------------------------------------------------------------ */
/* Resolved function pointers (filled by load_api)                     */
/* ------------------------------------------------------------------ */

static struct {
    fn_module_new             module_new;
    fn_module_new_wasi        module_new_wasi;
    fn_module_new_with_imports module_new_with_imports;
    fn_module_new_configured  module_new_configured;
    fn_module_delete          module_delete;
    fn_module_validate        module_validate;
    fn_module_invoke          module_invoke;
    fn_module_invoke_start    module_invoke_start;
    fn_module_cancel          module_cancel;
    fn_export_count           export_count;
    fn_export_name            export_name;
    fn_export_param_count     export_param_count;
    fn_export_result_count    export_result_count;
    fn_memory_data            memory_data;
    fn_memory_size            memory_size;
    fn_memory_read            memory_read;
    fn_memory_write           memory_write;
    fn_last_error             last_error;
    fn_config_new             config_new;
    fn_config_delete          config_delete;
    fn_config_set_fuel        config_set_fuel;
    fn_config_set_timeout     config_set_timeout;
    fn_config_set_max_memory  config_set_max_memory;
    fn_config_set_force_interpreter config_set_force_interpreter;
    fn_config_set_cancellable config_set_cancellable;
    fn_import_new             import_new;
    fn_import_delete          import_delete;
    fn_import_add_fn          import_add_fn;
    fn_wasi_config_new        wasi_config_new;
    fn_wasi_config_delete     wasi_config_delete;
    fn_wasi_config_set_stdio_fd wasi_config_set_stdio_fd;
    fn_wasi_config_preopen_fd wasi_config_preopen_fd;
    fn_module_new_wasi_configured module_new_wasi_configured;
} api;

typedef struct {
    zwasm_module_t module;
} CancelThreadArgs;

static void *cancel_thread_main(void *raw) {
    CancelThreadArgs *args = (CancelThreadArgs *)raw;
    /* Keep cancel requests alive across invoke start/reset race. */
    zw_usleep_us(100);
    for (int i = 0; i < 200; i++) {
        api.module_cancel(args->module);
        zw_usleep_us(100);
    }
    return NULL;
}

static zw_lib_t lib_handle = NULL;

#define LOAD_SYM(field, name) do { \
    api.field = (typeof(api.field))zw_dlsym(lib_handle, name); \
    if (!api.field) { \
        fprintf(stderr, "dlsym(%s): %s\n", name, zw_dlerror()); \
        return false; \
    } \
} while(0)

static bool load_api(const char *path) {
    lib_handle = zw_dlopen(path);
    if (!lib_handle) {
        fprintf(stderr, "dlopen(%s): %s\n", path, zw_dlerror());
        return false;
    }
    LOAD_SYM(module_new,             "zwasm_module_new");
    LOAD_SYM(module_new_wasi,        "zwasm_module_new_wasi");
    LOAD_SYM(module_new_with_imports,"zwasm_module_new_with_imports");
    LOAD_SYM(module_new_configured,  "zwasm_module_new_configured");
    LOAD_SYM(module_delete,          "zwasm_module_delete");
    LOAD_SYM(module_validate,        "zwasm_module_validate");
    LOAD_SYM(module_invoke,          "zwasm_module_invoke");
    LOAD_SYM(module_invoke_start,    "zwasm_module_invoke_start");
    LOAD_SYM(module_cancel,          "zwasm_module_cancel");
    LOAD_SYM(export_count,           "zwasm_module_export_count");
    LOAD_SYM(export_name,            "zwasm_module_export_name");
    LOAD_SYM(export_param_count,     "zwasm_module_export_param_count");
    LOAD_SYM(export_result_count,    "zwasm_module_export_result_count");
    LOAD_SYM(memory_data,            "zwasm_module_memory_data");
    LOAD_SYM(memory_size,            "zwasm_module_memory_size");
    LOAD_SYM(memory_read,            "zwasm_module_memory_read");
    LOAD_SYM(memory_write,           "zwasm_module_memory_write");
    LOAD_SYM(last_error,             "zwasm_last_error_message");
    LOAD_SYM(config_new,             "zwasm_config_new");
    LOAD_SYM(config_delete,          "zwasm_config_delete");
    LOAD_SYM(config_set_fuel,        "zwasm_config_set_fuel");
    LOAD_SYM(config_set_timeout,     "zwasm_config_set_timeout");
    LOAD_SYM(config_set_max_memory,  "zwasm_config_set_max_memory");
    LOAD_SYM(config_set_force_interpreter, "zwasm_config_set_force_interpreter");
    LOAD_SYM(config_set_cancellable, "zwasm_config_set_cancellable");
    LOAD_SYM(import_new,             "zwasm_import_new");
    LOAD_SYM(import_delete,          "zwasm_import_delete");
    LOAD_SYM(import_add_fn,          "zwasm_import_add_fn");
    LOAD_SYM(wasi_config_new,        "zwasm_wasi_config_new");
    LOAD_SYM(wasi_config_delete,     "zwasm_wasi_config_delete");
    LOAD_SYM(wasi_config_set_stdio_fd, "zwasm_wasi_config_set_stdio_fd");
    LOAD_SYM(wasi_config_preopen_fd, "zwasm_wasi_config_preopen_fd");
    LOAD_SYM(module_new_wasi_configured, "zwasm_module_new_wasi_configured");
    return true;
}

/* ------------------------------------------------------------------ */
/* Wasm test modules (hand-coded binary)                               */
/* ------------------------------------------------------------------ */

/* Minimal valid: magic + version only */
static const uint8_t MINIMAL_WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00
};

/* (func (export "f") (result i32) (i32.const 42)) */
static const uint8_t RETURN42_WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b
};

/* (func (export "add") (param i32 i32) (result i32) (i32.add (local.get 0) (local.get 1))) */
static const uint8_t ADD_WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b
};

/* (memory (export "m") 1) + (func (export "f") i32.store(0, 42)) */
static const uint8_t MEMORY_WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,               /* type: () -> () */
    0x03, 0x02, 0x01, 0x00,                             /* func section */
    0x05, 0x03, 0x01, 0x00, 0x01,                       /* memory: min=0, max=1 */
    0x07, 0x09, 0x02,                                   /* export section: 2 exports */
    0x01, 0x6d, 0x02, 0x00,                             /* "m" = mem 0 */
    0x01, 0x66, 0x00, 0x00,                             /* "f" = func 0 */
    0x0a, 0x0b, 0x01, 0x09, 0x00, 0x41, 0x00, 0x41,    /* code */
    0x2a, 0x36, 0x02, 0x00, 0x0b
};

/* Module: imports "env" "add" (i32,i32)->i32, exports "call_add" */
static const uint8_t IMPORT_WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
    0x02, 0x0b, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x0c, 0x01, 0x08, 0x63, 0x61, 0x6c, 0x6c, 0x5f, 0x61, 0x64, 0x64, 0x00, 0x01,
    0x0a, 0x0a, 0x01, 0x08, 0x00, 0x41, 0x03, 0x41, 0x04, 0x10, 0x00, 0x0b
};

/* Module: (func (export "loop") (loop (br 0))) — infinite loop, never completes */
static const uint8_t INFINITE_LOOP_WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,                 /* type: () -> () */
    0x03, 0x02, 0x01, 0x00,                               /* func 0: type 0 */
    0x07, 0x08, 0x01, 0x04, 0x6c, 0x6f, 0x6f, 0x70,       /* export "loop" */
    0x00, 0x00,
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x03, 0x40, 0x0c, 0x00, /* code: loop br 0 end end */
    0x0b, 0x0b
};

/* ------------------------------------------------------------------ */
/* Tests                                                               */
/* ------------------------------------------------------------------ */

static void test_symbol_resolution(void) {
    printf("-- symbol resolution (all required exports)\n");
    /* Already verified by load_api — if we got here, all symbols resolved. */
    ASSERT(api.module_new != NULL, "zwasm_module_new resolved");
    ASSERT(api.module_delete != NULL, "zwasm_module_delete resolved");
    ASSERT(api.module_invoke != NULL, "zwasm_module_invoke resolved");
    ASSERT(api.memory_data != NULL, "zwasm_module_memory_data resolved");
    ASSERT(api.memory_size != NULL, "zwasm_module_memory_size resolved");
    ASSERT(api.last_error != NULL, "zwasm_last_error_message resolved");
    ASSERT(api.config_new != NULL, "zwasm_config_new resolved");
    ASSERT(api.import_new != NULL, "zwasm_import_new resolved");
}

static void test_module_lifecycle(void) {
    printf("-- module lifecycle\n");

    zwasm_module_t mod = api.module_new(MINIMAL_WASM, sizeof(MINIMAL_WASM));
    ASSERT(mod != NULL, "module_new minimal");
    if (mod) api.module_delete(mod);

    mod = api.module_new((const uint8_t *)"\x00\x00\x00\x00", 4);
    ASSERT(mod == NULL, "module_new invalid returns NULL");

    /* Error message should be set after failure */
    const char *err = api.last_error();
    ASSERT(err != NULL && strlen(err) > 0, "last_error non-empty after failure");
}

static void test_validate(void) {
    printf("-- validate\n");

    ASSERT(api.module_validate(RETURN42_WASM, sizeof(RETURN42_WASM)),
           "validate return42");
    ASSERT(!api.module_validate((const uint8_t *)"\x00\x00\x00\x00", 4),
           "validate rejects garbage");
}

static void test_invoke_no_args(void) {
    printf("-- invoke (no args, one result)\n");

    zwasm_module_t mod = api.module_new(RETURN42_WASM, sizeof(RETURN42_WASM));
    ASSERT(mod != NULL, "load return42");
    if (!mod) return;

    uint64_t results[1] = {0};
    ASSERT(api.module_invoke(mod, "f", NULL, 0, results, 1), "invoke f()");
    ASSERT_EQ_U64(results[0], 42, "f() == 42");

    /* Invoke again — should work (module is reusable) */
    results[0] = 0;
    ASSERT(api.module_invoke(mod, "f", NULL, 0, results, 1), "invoke f() again");
    ASSERT_EQ_U64(results[0], 42, "f() == 42 second call");

    api.module_delete(mod);
}

static void test_invoke_with_args(void) {
    printf("-- invoke (with args)\n");

    zwasm_module_t mod = api.module_new(ADD_WASM, sizeof(ADD_WASM));
    ASSERT(mod != NULL, "load add module");
    if (!mod) return;

    uint64_t args[2] = {10, 32};
    uint64_t results[1] = {0};
    ASSERT(api.module_invoke(mod, "add", args, 2, results, 1), "invoke add(10,32)");
    ASSERT_EQ_U64(results[0], 42, "add(10,32) == 42");

    /* Edge: zero + zero */
    args[0] = 0; args[1] = 0;
    ASSERT(api.module_invoke(mod, "add", args, 2, results, 1), "invoke add(0,0)");
    ASSERT_EQ_U64(results[0], 0, "add(0,0) == 0");

    /* Edge: large i32 values (wrapping) */
    args[0] = 0xFFFFFFFF; args[1] = 1;
    ASSERT(api.module_invoke(mod, "add", args, 2, results, 1), "invoke add(MAX,1)");
    ASSERT_EQ_U64(results[0] & 0xFFFFFFFF, 0, "add wraps to 0");

    api.module_delete(mod);
}

static void test_invoke_nonexistent(void) {
    printf("-- invoke nonexistent function\n");

    zwasm_module_t mod = api.module_new(RETURN42_WASM, sizeof(RETURN42_WASM));
    ASSERT(mod != NULL, "load module");
    if (!mod) return;

    ASSERT(!api.module_invoke(mod, "nonexistent", NULL, 0, NULL, 0),
           "invoke nonexistent returns false");
    const char *err = api.last_error();
    ASSERT(err != NULL && strlen(err) > 0, "error message set");

    api.module_delete(mod);
}

static void test_export_introspection(void) {
    printf("-- export introspection\n");

    zwasm_module_t mod = api.module_new(RETURN42_WASM, sizeof(RETURN42_WASM));
    ASSERT(mod != NULL, "load module");
    if (!mod) return;

    ASSERT_EQ_U64(api.export_count(mod), 1, "1 export");

    const char *name = api.export_name(mod, 0);
    ASSERT(name != NULL, "export name not null");
    if (name) ASSERT(strcmp(name, "f") == 0, "export name == 'f'");

    ASSERT_EQ_U64(api.export_param_count(mod, 0), 0, "0 params");
    ASSERT_EQ_U64(api.export_result_count(mod, 0), 1, "1 result");

    /* Out-of-range index */
    ASSERT(api.export_name(mod, 99) == NULL, "export_name(99) == NULL");

    api.module_delete(mod);
}

static void test_memory_access(void) {
    printf("-- memory access\n");

    zwasm_module_t mod = api.module_new(MEMORY_WASM, sizeof(MEMORY_WASM));
    ASSERT(mod != NULL, "load memory module");
    if (!mod) return;

    /* Memory data pointer */
    uint8_t *data = api.memory_data(mod);
    ASSERT(data != NULL, "memory_data not null");

    /* Memory size (at least 1 page = 65536 bytes) */
    size_t size = api.memory_size(mod);
    ASSERT(size >= 65536, "memory >= 1 page");

    /* Write via API, read back via API */
    uint8_t write_buf[] = {0xDE, 0xAD, 0xBE, 0xEF};
    ASSERT(api.memory_write(mod, 0, write_buf, 4), "memory_write");

    uint8_t read_buf[4] = {0};
    ASSERT(api.memory_read(mod, 0, 4, read_buf), "memory_read");
    ASSERT(memcmp(write_buf, read_buf, 4) == 0, "read == write");

    /* Write via API, read via data pointer */
    if (data) {
        ASSERT(data[0] == 0xDE && data[1] == 0xAD, "data ptr matches write");
    }

    /* Out-of-bounds write */
    ASSERT(!api.memory_write(mod, (uint32_t)size, write_buf, 4),
           "OOB write returns false");

    /* Out-of-bounds read */
    ASSERT(!api.memory_read(mod, (uint32_t)size, 4, read_buf),
           "OOB read returns false");

    /* Invoke f (stores 42 at offset 0) and verify via data pointer */
    ASSERT(api.module_invoke(mod, "f", NULL, 0, NULL, 0), "invoke store fn");
    if (data) {
        uint32_t val = *(uint32_t *)data;
        ASSERT_EQ_U64(val, 42, "store fn wrote 42 at offset 0");
    }

    api.module_delete(mod);
}

static void test_no_memory_module(void) {
    printf("-- module without memory\n");

    zwasm_module_t mod = api.module_new(RETURN42_WASM, sizeof(RETURN42_WASM));
    ASSERT(mod != NULL, "load module");
    if (!mod) return;

    ASSERT(api.memory_data(mod) == NULL, "memory_data == NULL for no-memory");
    ASSERT_EQ_U64(api.memory_size(mod), 0, "memory_size == 0 for no-memory");

    api.module_delete(mod);
}

static bool host_add(void *env, const uint64_t *args, uint64_t *results) {
    (void)env;
    results[0] = (uint64_t)((int32_t)args[0] + (int32_t)args[1]);
    return true;
}

static void test_host_imports(void) {
    printf("-- host function imports\n");

    zwasm_imports_t imports = api.import_new();
    ASSERT(imports != NULL, "import_new");
    if (!imports) return;

    api.import_add_fn(imports, "env", "add", host_add, NULL, 2, 1);

    zwasm_module_t mod = api.module_new_with_imports(
        IMPORT_WASM, sizeof(IMPORT_WASM), imports);
    ASSERT(mod != NULL, "module_new_with_imports");

    if (mod) {
        uint64_t results[1] = {0};
        ASSERT(api.module_invoke(mod, "call_add", NULL, 0, results, 1),
               "invoke call_add");
        ASSERT_EQ_U64(results[0], 7, "call_add == 3+4=7");
        api.module_delete(mod);
    }

    api.import_delete(imports);
}

static void test_config_lifecycle(void) {
    printf("-- config lifecycle\n");

    zwasm_config_t cfg = api.config_new();
    ASSERT(cfg != NULL, "config_new");
    api.config_set_fuel(cfg, 10000);
    api.config_set_timeout(cfg, 5000);
    api.config_set_max_memory(cfg, 65536);
    api.config_set_force_interpreter(cfg, true);

    zwasm_module_t mod2 = api.module_new_configured(RETURN42_WASM, sizeof(RETURN42_WASM), cfg);
    ASSERT(mod2 != NULL, "module_new_configured(cfg)");
    if (mod2) api.module_delete(mod2);

    if (cfg) api.config_delete(cfg);

    /* Configured module (NULL config = default) */
    zwasm_module_t mod = api.module_new_configured(
        RETURN42_WASM, sizeof(RETURN42_WASM), NULL);
    ASSERT(mod != NULL, "module_new_configured(NULL)");
    if (mod) {
        uint64_t results[1] = {0};
        ASSERT(api.module_invoke(mod, "f", NULL, 0, results, 1),
               "invoke via configured module");
        ASSERT_EQ_U64(results[0], 42, "f() == 42 via configured");
        api.module_delete(mod);
    }
}

static void test_multiple_modules(void) {
    printf("-- multiple simultaneous modules\n");

    zwasm_module_t m1 = api.module_new(RETURN42_WASM, sizeof(RETURN42_WASM));
    zwasm_module_t m2 = api.module_new(ADD_WASM, sizeof(ADD_WASM));
    zwasm_module_t m3 = api.module_new(MEMORY_WASM, sizeof(MEMORY_WASM));
    ASSERT(m1 != NULL && m2 != NULL && m3 != NULL, "3 modules loaded");

    if (m1 && m2 && m3) {
        uint64_t r[1] = {0};
        ASSERT(api.module_invoke(m1, "f", NULL, 0, r, 1), "invoke m1.f");
        ASSERT_EQ_U64(r[0], 42, "m1.f() == 42");

        uint64_t args[2] = {100, 200};
        ASSERT(api.module_invoke(m2, "add", args, 2, r, 1), "invoke m2.add");
        ASSERT_EQ_U64(r[0], 300, "m2.add(100,200) == 300");

        ASSERT(api.memory_size(m3) >= 65536, "m3 has memory");
    }

    if (m1) api.module_delete(m1);
    if (m2) api.module_delete(m2);
    if (m3) api.module_delete(m3);
}

static void test_wasi_config_fd_api(void) {
    printf("-- WASI config FD API\n");

    /* Basic lifecycle: create, configure, delete */
    zwasm_wasi_config_t wc = api.wasi_config_new();
    ASSERT(wc != NULL, "wasi_config_new returns non-null");

    /* Set stdio overrides (use pipe fds) */
    int stdout_pipe[2];
    ASSERT(zw_pipe(stdout_pipe) == 0, "pipe() for stdout");

    /* Override stdout (fd 1) with write end of pipe, borrow mode */
    api.wasi_config_set_stdio_fd(wc, 1, (intptr_t)stdout_pipe[1], 0 /* borrow */);

    /* Override stderr (fd 2) with write end as well, borrow mode */
    api.wasi_config_set_stdio_fd(wc, 2, (intptr_t)stdout_pipe[1], 0 /* borrow */);

    /* Invalid fd index (>=3) should be silently ignored */
    api.wasi_config_set_stdio_fd(wc, 5, (intptr_t)stdout_pipe[0], 0);

    /* Add an FD-based preopen (borrow mode). The API only stores the
       fd integer in borrow mode, so the underlying object doesn't
       need to be a real directory. msvcrt's `_open` rejects directory
       paths (returns -1 with EACCES), so on Windows we fall back to
       `_dup(0)` since fd 0 (stdin) is always present. */
#ifdef _WIN32
    int dir_fd = _dup(0);
    ASSERT(dir_fd >= 0, "dup(stdin) for preopen fd");
#else
    int dir_fd = zw_open(".", ZW_O_RDONLY);
    ASSERT(dir_fd >= 0, "open(\".\") for preopen fd");
#endif
    api.wasi_config_preopen_fd(wc, (intptr_t)dir_fd, "/sandbox", 8,
                               1 /* dir */, 0 /* borrow */);

    api.wasi_config_delete(wc);

    /* Borrowed fds should still be valid */
    ASSERT(zw_write(stdout_pipe[1], "ok", 2) == 2, "borrowed stdout pipe still writable");
    zw_close(stdout_pipe[0]);
    zw_close(stdout_pipe[1]);
    zw_close(dir_fd);
}

static void test_repeated_create_destroy(void) {
    printf("-- repeated create/destroy (leak check)\n");

    for (int i = 0; i < 100; i++) {
        zwasm_module_t mod = api.module_new(RETURN42_WASM, sizeof(RETURN42_WASM));
        if (!mod) {
            ASSERT(false, "create failed in loop");
            return;
        }
        uint64_t r[1] = {0};
        api.module_invoke(mod, "f", NULL, 0, r, 1);
        api.module_delete(mod);
    }
    ASSERT(true, "100 create/invoke/destroy cycles");
}

static void test_cancellable_config(void) {
    zwasm_config_t *config = api.config_new();
    ASSERT(config != NULL, "config created");

    /* Test disabling cancellation */
    api.config_set_cancellable(config, false);

    zwasm_module_t mod = api.module_new_configured(MINIMAL_WASM, sizeof(MINIMAL_WASM), config);
    ASSERT(mod != NULL, "module created with cancellable=false");

    api.module_delete(mod);
    api.config_delete(config);
}

static void test_cancel_api(void) {
    printf("-- cancel API (thread-safety check)\n");

    zwasm_module_t mod = api.module_new(RETURN42_WASM, sizeof(RETURN42_WASM));
    ASSERT(mod != NULL, "module loaded");
    if (!mod) return;

    /* Call cancel on idle module (should be no-op) */
    api.module_cancel(mod);
    ASSERT(true, "module_cancel on idle module");

    /* invoke() resets cancellation state at entry, so this should succeed */
    uint64_t r[1] = {0};
    ASSERT(api.module_invoke(mod, "f", NULL, 0, r, 1),
           "invoke after cancel (flag cleared by reset)");
    ASSERT_EQ_U64(r[0], 42, "result after cancel is correct");

    api.module_delete(mod);

    /* Concurrent cancel: cancel from another thread while invoke("loop") is running.
     * The module runs an infinite loop, so the ONLY way invoke() can return is
     * via cancellation.  If cancel() is broken, this test will hang forever
     * (caught by CI timeout). */
    zwasm_module_t loop_mod = api.module_new(INFINITE_LOOP_WASM, sizeof(INFINITE_LOOP_WASM));
    ASSERT(loop_mod != NULL, "infinite loop module loaded");
    if (!loop_mod) return;

    CancelThreadArgs cargs = { .module = loop_mod };

    zw_thread_t tid;
    zw_thread_ctx_t tctx;
    int create_rc = zw_thread_create(&tid, cancel_thread_main, &cargs, &tctx);
    ASSERT(create_rc == 0, "thread create for cancel thread");
    if (create_rc == 0) {
        bool ok = api.module_invoke(loop_mod, "loop", NULL, 0, NULL, 0);
        /* invoke() MUST fail — the loop is infinite, so success is impossible */
        ASSERT(!ok, "invoke of infinite loop was cancelled (did not complete)");
        const char *err = api.last_error();
        ASSERT(err != NULL && strstr(err, "Canceled") != NULL,
               "last_error indicates Canceled");
        ASSERT(zw_thread_join(tid) == 0, "thread join cancel thread");
    }

    api.module_delete(loop_mod);
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

int main(int argc, char **argv) {
    const char *lib_path = NULL;
    if (argc > 1) {
        lib_path = argv[1];
    } else {
        /* Auto-detect. Zig installs DLLs to bin/ on Windows but
           shared objects to lib/ on POSIX. */
#ifdef __APPLE__
        lib_path = "zig-out/lib/libzwasm.dylib";
#elif defined(_WIN32)
        lib_path = "zig-out/bin/zwasm.dll";
#else
        lib_path = "zig-out/lib/libzwasm.so";
#endif
    }

    printf("=== zwasm FFI test suite ===\n");
    printf("Library: %s\n\n", lib_path);

    if (!load_api(lib_path)) {
        fprintf(stderr, "FATAL: could not load library\n");
        return 1;
    }

    test_symbol_resolution();
    test_module_lifecycle();
    test_validate();
    test_invoke_no_args();
    test_invoke_with_args();
    test_invoke_nonexistent();
    test_export_introspection();
    test_memory_access();
    test_no_memory_module();
    test_host_imports();
    test_config_lifecycle();
    test_cancellable_config();
    test_multiple_modules();
    test_wasi_config_fd_api();
    test_repeated_create_destroy();
    test_cancel_api();

    printf("\n%d/%d passed, %d failed\n", tests_passed, tests_run, tests_failed);

    zw_dlclose(lib_handle);
    return (tests_failed == 0) ? 0 : 1;
}
