/*
 * test_basic.c — Basic C API tests for zwasm
 *
 * Build: zig build c-test
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "zwasm.h"

static int tests_run = 0;
static int tests_passed = 0;

#define ASSERT(cond, msg) do { \
    tests_run++; \
    if (!(cond)) { \
        printf("FAIL: %s (line %d): %s\n", msg, __LINE__, zwasm_last_error_message()); \
    } else { \
        tests_passed++; \
    } \
} while(0)

/* Minimal valid Wasm: magic + version, no sections */
static const uint8_t MINIMAL_WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00
};

/* Module: export "f" () -> i32 { return 42 } */
static const uint8_t RETURN42_WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,       /* type: () -> i32 */
    0x03, 0x02, 0x01, 0x00,                           /* func section */
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,        /* export "f" = func 0 */
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b   /* code: i32.const 42, end */
};

/* Module: 1-page memory (min=0, max=1) — no exports */
static const uint8_t MEMORY_WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x05, 0x03, 0x01, 0x00, 0x01                      /* memory: min=0, max=1 */
};

static void test_module_lifecycle(void) {
    printf("-- module lifecycle\n");

    zwasm_module_t *mod = zwasm_module_new(MINIMAL_WASM, sizeof(MINIMAL_WASM));
    ASSERT(mod != NULL, "module_new with minimal wasm");
    if (mod) zwasm_module_delete(mod);

    mod = zwasm_module_new((const uint8_t *)"\x00\x00\x00\x00", 4);
    ASSERT(mod == NULL, "module_new with invalid bytes returns null");

    ASSERT(zwasm_module_validate(MINIMAL_WASM, sizeof(MINIMAL_WASM)),
           "validate minimal wasm");
    ASSERT(!zwasm_module_validate((const uint8_t *)"\x00\x00\x00\x00", 4),
           "validate rejects invalid bytes");
}

static void test_invoke(void) {
    printf("-- invoke\n");

    zwasm_module_t *mod = zwasm_module_new(RETURN42_WASM, sizeof(RETURN42_WASM));
    ASSERT(mod != NULL, "load return42 module");
    if (!mod) return;

    uint64_t results[1] = {0};
    ASSERT(zwasm_module_invoke(mod, "f", NULL, 0, results, 1), "invoke f()");
    ASSERT(results[0] == 42, "f() returns 42");

    ASSERT(!zwasm_module_invoke(mod, "nonexistent", NULL, 0, NULL, 0),
           "invoke nonexistent returns false");

    zwasm_module_delete(mod);
}

static void test_memory(void) {
    printf("-- memory\n");

    zwasm_module_t *mod = zwasm_module_new(MEMORY_WASM, sizeof(MEMORY_WASM));
    ASSERT(mod != NULL, "load memory module");
    if (!mod) return;

    size_t size = zwasm_module_memory_size(mod);
    ASSERT(size > 0, "memory size > 0");

    uint8_t *data = zwasm_module_memory_data(mod);
    ASSERT(data != NULL, "memory data not null");

    /* Write and read back */
    uint8_t write_buf[] = {0xDE, 0xAD, 0xBE, 0xEF};
    ASSERT(zwasm_module_memory_write(mod, 0, write_buf, 4), "memory write");

    uint8_t read_buf[4] = {0};
    ASSERT(zwasm_module_memory_read(mod, 0, 4, read_buf), "memory read");
    ASSERT(memcmp(write_buf, read_buf, 4) == 0, "read matches write");

    zwasm_module_delete(mod);
}

static void test_export_introspection(void) {
    printf("-- export introspection\n");

    zwasm_module_t *mod = zwasm_module_new(RETURN42_WASM, sizeof(RETURN42_WASM));
    ASSERT(mod != NULL, "load module");
    if (!mod) return;

    ASSERT(zwasm_module_export_count(mod) == 1, "1 export");

    const char *name = zwasm_module_export_name(mod, 0);
    ASSERT(name != NULL, "export name not null");
    if (name) ASSERT(strcmp(name, "f") == 0, "export name is 'f'");

    ASSERT(zwasm_module_export_param_count(mod, 0) == 0, "0 params");
    ASSERT(zwasm_module_export_result_count(mod, 0) == 1, "1 result");

    zwasm_module_delete(mod);
}

static bool add_callback(void *env, const uint64_t *args, uint64_t *results) {
    (void)env;
    int32_t a = (int32_t)args[0];
    int32_t b = (int32_t)args[1];
    results[0] = (uint64_t)(int64_t)(a + b);
    return true;
}

static void test_host_imports(void) {
    printf("-- host imports\n");

    /* Module: imports "env" "add" (i32,i32)->i32, exports "call_add" */
    static const uint8_t IMPORT_WASM[] = {
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
        0x02, 0x0b, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x0c, 0x01, 0x08, 0x63, 0x61, 0x6c, 0x6c, 0x5f, 0x61, 0x64, 0x64, 0x00, 0x01,
        0x0a, 0x0a, 0x01, 0x08, 0x00, 0x41, 0x03, 0x41, 0x04, 0x10, 0x00, 0x0b
    };

    zwasm_imports_t *imports = zwasm_import_new();
    ASSERT(imports != NULL, "import_new");
    if (!imports) return;

    zwasm_import_add_fn(imports, "env", "add", add_callback, NULL, 2, 1);

    zwasm_module_t *mod = zwasm_module_new_with_imports(
        IMPORT_WASM, sizeof(IMPORT_WASM), imports);
    ASSERT(mod != NULL, "module_new_with_imports");

    if (mod) {
        uint64_t results[1] = {0};
        ASSERT(zwasm_module_invoke(mod, "call_add", NULL, 0, results, 1),
               "invoke call_add");
        ASSERT(results[0] == 7, "call_add returns 3+4=7");
        zwasm_module_delete(mod);
    }

    zwasm_import_delete(imports);
}

int main(void) {
    printf("=== zwasm C API basic tests ===\n");

    test_module_lifecycle();
    test_invoke();
    test_memory();
    test_export_introspection();
    test_host_imports();

    printf("\n%d/%d tests passed\n", tests_passed, tests_run);
    return (tests_passed == tests_run) ? 0 : 1;
}
