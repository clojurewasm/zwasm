// SIMD benchmark: byte frequency counting
// Usage: byte_freq.wasm <scalar|simd>
// Build: wasm32-wasi-clang -O2 -msimd128 -o byte_freq.wasm byte_freq.c

#include <wasm_simd128.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define BUFSIZE (64 * 1024)
#define ITERS 100

static uint8_t buffer[BUFSIZE];
static uint32_t freq[256];

static void init_buffer(void) {
    for (int i = 0; i < BUFSIZE; i++) {
        buffer[i] = (uint8_t)((i * 31 + i / 7 + 17) & 0xFF);
    }
}

static void count_scalar(void) {
    memset(freq, 0, sizeof(freq));
    for (int i = 0; i < BUFSIZE; i++) {
        freq[buffer[i]]++;
    }
}

static void count_simd(void) {
    memset(freq, 0, sizeof(freq));
    for (int target = 0; target < 256; target++) {
        v128_t match_val = wasm_i8x16_splat((int8_t)target);
        uint32_t count = 0;
        for (int i = 0; i < BUFSIZE; i += 16) {
            v128_t chunk = wasm_v128_load(&buffer[i]);
            v128_t eq = wasm_i8x16_eq(chunk, match_val);
            uint32_t mask = (uint32_t)wasm_i8x16_bitmask(eq);
            while (mask) { count++; mask &= mask - 1; }
        }
        freq[target] = count;
    }
}

int main(int argc, char **argv) {
    init_buffer();
    int use_simd = (argc > 1 && strcmp(argv[1], "simd") == 0);

    for (int i = 0; i < ITERS; i++) {
        if (use_simd) count_simd(); else count_scalar();
    }

    uint32_t checksum = 0;
    for (int i = 0; i < 256; i++) checksum += freq[i] * (uint32_t)i;
    printf("checksum: %u\n", checksum);
    return 0;
}
