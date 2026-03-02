/*
 * hello.c — Minimal example using the zwasm C API
 *
 * Demonstrates: load module, invoke exported function, read result.
 *
 * Build: zig build c-test   (or: cc -o hello hello.c -L zig-out/lib -lzwasm)
 * Run:   ./zig-out/bin/example_c_hello
 */

#include <stdio.h>
#include "zwasm.h"

/* Wasm module: export "f" () -> i32 { return 42 } */
static const uint8_t WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b
};

int main(void) {
    /* Load module */
    zwasm_module_t *mod = zwasm_module_new(WASM, sizeof(WASM));
    if (!mod) {
        fprintf(stderr, "Error: %s\n", zwasm_last_error_message());
        return 1;
    }

    /* Invoke exported function "f" */
    uint64_t results[1] = {0};
    if (!zwasm_module_invoke(mod, "f", NULL, 0, results, 1)) {
        fprintf(stderr, "Invoke error: %s\n", zwasm_last_error_message());
        zwasm_module_delete(mod);
        return 1;
    }

    printf("f() = %llu\n", (unsigned long long)results[0]);

    /* Cleanup */
    zwasm_module_delete(mod);
    return 0;
}
