// SIMD byte counting: count occurrences of a specific byte in a buffer
#include <wasm_simd128.h>
#include <stdio.h>

static unsigned char buf[4096];

int main(void) {
    // Fill buffer with pattern
    for (int i = 0; i < 4096; i++) {
        buf[i] = (unsigned char)(i % 256);
    }

    // Count occurrences of byte 42 using SIMD
    v128_t target = wasm_i8x16_splat(42);
    v128_t count = wasm_i32x4_const(0, 0, 0, 0);

    for (int i = 0; i < 4096; i += 16) {
        v128_t data = wasm_v128_load(&buf[i]);
        v128_t eq = wasm_i8x16_eq(data, target);
        // eq lanes are 0xFF or 0x00; negate to get 0x01 or 0x00
        v128_t ones = wasm_v128_and(eq, wasm_i8x16_splat(1));
        // Pairwise widen and accumulate
        v128_t sum16 = wasm_u16x8_extadd_pairwise_u8x16(ones);
        v128_t sum32 = wasm_u32x4_extadd_pairwise_u16x8(sum16);
        count = wasm_i32x4_add(count, sum32);
    }

    int total = wasm_i32x4_extract_lane(count, 0)
              + wasm_i32x4_extract_lane(count, 1)
              + wasm_i32x4_extract_lane(count, 2)
              + wasm_i32x4_extract_lane(count, 3);

    printf("%d\n", total);
    return 0;
}
