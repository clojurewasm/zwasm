// SIMD image alpha blending: blend two 256-pixel RGBA strips
#include <wasm_simd128.h>
#include <stdio.h>

static unsigned char src[1024]; // 256 RGBA pixels
static unsigned char dst[1024];
static unsigned char out[1024];

int main(void) {
    // Initialize with patterns
    for (int i = 0; i < 1024; i++) {
        src[i] = (unsigned char)(i & 0xFF);
        dst[i] = (unsigned char)(255 - (i & 0xFF));
    }

    // Alpha blend: out = (src * alpha + dst * (255 - alpha)) / 255
    // Use alpha = 128 (50%) for simplicity
    v128_t alpha = wasm_i16x8_splat(128);
    v128_t inv_alpha = wasm_i16x8_splat(127);
    v128_t zero = wasm_i8x16_const(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);

    for (int i = 0; i < 1024; i += 16) {
        v128_t s = wasm_v128_load(&src[i]);
        v128_t d = wasm_v128_load(&dst[i]);

        // Widen to 16-bit for multiplication
        v128_t s_lo = wasm_u16x8_extend_low_u8x16(s);
        v128_t s_hi = wasm_u16x8_extend_high_u8x16(s);
        v128_t d_lo = wasm_u16x8_extend_low_u8x16(d);
        v128_t d_hi = wasm_u16x8_extend_high_u8x16(d);

        // Multiply and shift
        v128_t r_lo = wasm_i16x8_add(wasm_i16x8_mul(s_lo, alpha), wasm_i16x8_mul(d_lo, inv_alpha));
        v128_t r_hi = wasm_i16x8_add(wasm_i16x8_mul(s_hi, alpha), wasm_i16x8_mul(d_hi, inv_alpha));

        // Shift right by 8 to divide by ~256
        r_lo = wasm_u16x8_shr(r_lo, 8);
        r_hi = wasm_u16x8_shr(r_hi, 8);

        // Narrow back to 8-bit
        v128_t result = wasm_u8x16_narrow_i16x8(r_lo, r_hi);
        wasm_v128_store(&out[i], result);
    }

    // Checksum
    int sum = 0;
    for (int i = 0; i < 1024; i++) sum += out[i];
    printf("%d\n", sum);
    return 0;
}
