// SIMD benchmark: f32 array reduction (sum)
// Usage: sum_reduce.wasm <scalar|simd>
// Build: wasm32-wasi-clang -O2 -msimd128 -o sum_reduce.wasm sum_reduce.c

#include <wasm_simd128.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define N 16384
#define ITERS 10000

static float data[N];

static void init_data(void) {
    for (int i = 0; i < N; i++) {
        data[i] = 1.0f / (float)(i + 1);
    }
}

static float sum_scalar(void) {
    float sum = 0.0f;
    for (int i = 0; i < N; i++) {
        sum += data[i];
    }
    return sum;
}

static float sum_simd(void) {
    v128_t acc = wasm_f32x4_splat(0.0f);
    for (int i = 0; i < N; i += 4) {
        v128_t v = wasm_v128_load(&data[i]);
        acc = wasm_f32x4_add(acc, v);
    }
    return wasm_f32x4_extract_lane(acc, 0) +
           wasm_f32x4_extract_lane(acc, 1) +
           wasm_f32x4_extract_lane(acc, 2) +
           wasm_f32x4_extract_lane(acc, 3);
}

int main(int argc, char **argv) {
    init_data();
    int use_simd = (argc > 1 && strcmp(argv[1], "simd") == 0);
    float result = 0;

    for (int i = 0; i < ITERS; i++) {
        result = use_simd ? sum_simd() : sum_scalar();
    }

    printf("result: %.6f\n", result);
    return 0;
}
