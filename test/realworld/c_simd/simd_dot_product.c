// SIMD dot product: compute dot product of two 1024-element float arrays
#include <wasm_simd128.h>
#include <stdio.h>

static float a[1024], b[1024];

int main(void) {
    // Initialize arrays
    for (int i = 0; i < 1024; i++) {
        a[i] = (float)(i + 1);
        b[i] = (float)(1024 - i);
    }

    // SIMD dot product
    v128_t sum = wasm_f32x4_const(0, 0, 0, 0);
    for (int i = 0; i < 1024; i += 4) {
        v128_t va = wasm_v128_load(&a[i]);
        v128_t vb = wasm_v128_load(&b[i]);
        v128_t prod = wasm_f32x4_mul(va, vb);
        sum = wasm_f32x4_add(sum, prod);
    }

    // Horizontal sum
    float result = wasm_f32x4_extract_lane(sum, 0)
                 + wasm_f32x4_extract_lane(sum, 1)
                 + wasm_f32x4_extract_lane(sum, 2)
                 + wasm_f32x4_extract_lane(sum, 3);

    printf("%.0f\n", result);
    return 0;
}
