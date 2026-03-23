// SIMD benchmark: RGBA image grayscale conversion
// Usage: grayscale.wasm <scalar|simd>
// Build: wasm32-wasi-clang -O2 -msimd128 -o grayscale.wasm grayscale.c

#include <wasm_simd128.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define WIDTH 256
#define HEIGHT 256
#define PIXELS (WIDTH * HEIGHT)
#define ITERS 500

static uint8_t image[PIXELS * 4];  // RGBA
static uint8_t gray[PIXELS];

static void init_image(void) {
    for (int i = 0; i < PIXELS; i++) {
        image[i * 4 + 0] = (uint8_t)(i & 0xFF);
        image[i * 4 + 1] = (uint8_t)((i >> 2) & 0xFF);
        image[i * 4 + 2] = (uint8_t)((i >> 4) & 0xFF);
        image[i * 4 + 3] = 255;
    }
}

static void grayscale_scalar(void) {
    for (int i = 0; i < PIXELS; i++) {
        uint8_t r = image[i * 4 + 0];
        uint8_t g = image[i * 4 + 1];
        uint8_t b = image[i * 4 + 2];
        gray[i] = (uint8_t)((77 * r + 150 * g + 29 * b + 128) >> 8);
    }
}

static void grayscale_simd(void) {
    v128_t coeff_r = wasm_i16x8_splat(77);
    v128_t coeff_g = wasm_i16x8_splat(150);
    v128_t coeff_b = wasm_i16x8_splat(29);
    v128_t bias = wasm_i16x8_splat(128);

    for (int i = 0; i < PIXELS; i += 8) {
        v128_t r_vals = wasm_i16x8_make(
            image[i*4+0], image[(i+1)*4+0], image[(i+2)*4+0], image[(i+3)*4+0],
            image[(i+4)*4+0], image[(i+5)*4+0], image[(i+6)*4+0], image[(i+7)*4+0]);
        v128_t g_vals = wasm_i16x8_make(
            image[i*4+1], image[(i+1)*4+1], image[(i+2)*4+1], image[(i+3)*4+1],
            image[(i+4)*4+1], image[(i+5)*4+1], image[(i+6)*4+1], image[(i+7)*4+1]);
        v128_t b_vals = wasm_i16x8_make(
            image[i*4+2], image[(i+1)*4+2], image[(i+2)*4+2], image[(i+3)*4+2],
            image[(i+4)*4+2], image[(i+5)*4+2], image[(i+6)*4+2], image[(i+7)*4+2]);

        v128_t y = wasm_i16x8_add(
            wasm_i16x8_add(wasm_i16x8_mul(r_vals, coeff_r),
                           wasm_i16x8_mul(g_vals, coeff_g)),
            wasm_i16x8_add(wasm_i16x8_mul(b_vals, coeff_b), bias));
        y = wasm_u16x8_shr(y, 8);

        v128_t packed = wasm_u8x16_narrow_i16x8(y, y);
        uint8_t tmp[16];
        wasm_v128_store(tmp, packed);
        for (int j = 0; j < 8; j++) {
            gray[i + j] = tmp[j];
        }
    }
}

int main(int argc, char **argv) {
    init_image();
    int use_simd = (argc > 1 && strcmp(argv[1], "simd") == 0);

    for (int i = 0; i < ITERS; i++) {
        if (use_simd) grayscale_simd(); else grayscale_scalar();
    }

    uint32_t checksum = 0;
    for (int i = 0; i < PIXELS; i++) checksum += gray[i];
    printf("checksum: %u\n", checksum);
    return 0;
}
