// SIMD benchmark: 3x3 box blur on grayscale image
// Usage: box_blur.wasm <scalar|simd>
// Build: wasm32-wasi-clang -O2 -msimd128 -o box_blur.wasm box_blur.c

#include <wasm_simd128.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define WIDTH 256
#define HEIGHT 256
#define ITERS 300

static uint8_t src[WIDTH * HEIGHT];
static uint8_t dst[WIDTH * HEIGHT];

static void init_image(void) {
    for (int i = 0; i < WIDTH * HEIGHT; i++) {
        src[i] = (uint8_t)((i * 7 + 13) & 0xFF);
    }
}

static void blur_scalar(void) {
    for (int y = 1; y < HEIGHT - 1; y++) {
        for (int x = 1; x < WIDTH - 1; x++) {
            int sum = 0;
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    sum += src[(y + dy) * WIDTH + (x + dx)];
                }
            }
            dst[y * WIDTH + x] = (uint8_t)(sum / 9);
        }
    }
}

static void blur_simd(void) {
    for (int y = 1; y < HEIGHT - 1; y++) {
        int x = 1;
        for (; x + 8 <= WIDTH - 1; x += 8) {
            v128_t sum = wasm_i16x8_splat(0);
            for (int dy = -1; dy <= 1; dy++) {
                int row = (y + dy) * WIDTH;
                for (int dx = -1; dx <= 1; dx++) {
                    v128_t pixels = wasm_u16x8_load8x8(&src[row + x + dx]);
                    sum = wasm_i16x8_add(sum, pixels);
                }
            }
            v128_t factor = wasm_i16x8_splat(7282);
            v128_t lo = wasm_i32x4_extmul_low_i16x8(sum, factor);
            v128_t hi = wasm_i32x4_extmul_high_i16x8(sum, factor);
            lo = wasm_u32x4_shr(lo, 16);
            hi = wasm_u32x4_shr(hi, 16);
            v128_t result16 = wasm_i16x8_narrow_i32x4(lo, hi);
            v128_t result8 = wasm_u8x16_narrow_i16x8(result16, result16);
            uint8_t tmp[16];
            wasm_v128_store(tmp, result8);
            for (int j = 0; j < 8; j++) {
                dst[y * WIDTH + x + j] = tmp[j];
            }
        }
        for (; x < WIDTH - 1; x++) {
            int sum = 0;
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    sum += src[(y + dy) * WIDTH + (x + dx)];
                }
            }
            dst[y * WIDTH + x] = (uint8_t)(sum / 9);
        }
    }
}

int main(int argc, char **argv) {
    init_image();
    int use_simd = (argc > 1 && strcmp(argv[1], "simd") == 0);

    for (int i = 0; i < ITERS; i++) {
        if (use_simd) blur_simd(); else blur_scalar();
    }

    uint32_t checksum = 0;
    for (int i = 0; i < WIDTH * HEIGHT; i++) checksum += dst[i];
    printf("checksum: %u\n", checksum);
    return 0;
}
