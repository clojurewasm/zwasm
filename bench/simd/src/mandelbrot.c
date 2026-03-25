// SIMD benchmark: Mandelbrot set computation
// Classic SIMD benchmark — computes escape iterations for a grid.
// Usage: mandelbrot.wasm <scalar|simd>
// Build: wasm32-wasi-clang -O2 -msimd128 -o mandelbrot.wasm mandelbrot.c -lm

#include <wasm_simd128.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define WIDTH  1024
#define HEIGHT 1024
#define MAX_ITER 256

static uint8_t image[WIDTH * HEIGHT];

// --- Scalar version ---
static void mandelbrot_scalar(void) {
    for (int py = 0; py < HEIGHT; py++) {
        float y0 = (float)py / HEIGHT * 3.0f - 1.5f;
        for (int px = 0; px < WIDTH; px++) {
            float x0 = (float)px / WIDTH * 3.5f - 2.5f;
            float x = 0.0f, y = 0.0f;
            int iter = 0;
            while (x * x + y * y <= 4.0f && iter < MAX_ITER) {
                float xt = x * x - y * y + x0;
                y = 2.0f * x * y + y0;
                x = xt;
                iter++;
            }
            image[py * WIDTH + px] = (uint8_t)iter;
        }
    }
}

// --- SIMD version (4 pixels at once) ---
static void mandelbrot_simd(void) {
    v128_t four = wasm_f32x4_splat(4.0f);
    v128_t two = wasm_f32x4_splat(2.0f);
    v128_t one_i = wasm_i32x4_splat(1);

    for (int py = 0; py < HEIGHT; py++) {
        float y0 = (float)py / HEIGHT * 3.0f - 1.5f;
        v128_t vy0 = wasm_f32x4_splat(y0);

        for (int px = 0; px < WIDTH; px += 4) {
            // x0 for 4 consecutive pixels
            float base_x0 = (float)px / WIDTH * 3.5f - 2.5f;
            float step = 3.5f / WIDTH;
            v128_t vx0 = wasm_f32x4_make(
                base_x0, base_x0 + step, base_x0 + 2*step, base_x0 + 3*step);

            v128_t vx = wasm_f32x4_splat(0.0f);
            v128_t vy = wasm_f32x4_splat(0.0f);
            v128_t iters = wasm_i32x4_splat(0);

            for (int i = 0; i < MAX_ITER; i++) {
                v128_t xx = wasm_f32x4_mul(vx, vx);
                v128_t yy = wasm_f32x4_mul(vy, vy);
                v128_t mag2 = wasm_f32x4_add(xx, yy);

                // mask: 1 where mag2 <= 4.0
                v128_t mask = wasm_f32x4_le(mag2, four);
                if (!wasm_v128_any_true(mask)) break;

                // iter++ for active lanes
                iters = wasm_i32x4_add(iters, wasm_v128_and(one_i, mask));

                // z = z^2 + c
                v128_t xt = wasm_f32x4_add(wasm_f32x4_sub(xx, yy), vx0);
                vy = wasm_f32x4_add(wasm_f32x4_mul(two, wasm_f32x4_mul(vx, vy)), vy0);
                vx = xt;
            }

            // Store 4 iteration counts
            image[py * WIDTH + px + 0] = (uint8_t)wasm_i32x4_extract_lane(iters, 0);
            if (px + 1 < WIDTH) image[py * WIDTH + px + 1] = (uint8_t)wasm_i32x4_extract_lane(iters, 1);
            if (px + 2 < WIDTH) image[py * WIDTH + px + 2] = (uint8_t)wasm_i32x4_extract_lane(iters, 2);
            if (px + 3 < WIDTH) image[py * WIDTH + px + 3] = (uint8_t)wasm_i32x4_extract_lane(iters, 3);
        }
    }
}

int main(int argc, char **argv) {
    int use_simd = (argc > 1 && strcmp(argv[1], "simd") == 0);
    int reps = 10;

    for (int r = 0; r < reps; r++) {
        memset(image, 0, sizeof(image));
        if (use_simd) mandelbrot_simd();
        else mandelbrot_scalar();
    }

    // Checksum
    uint32_t sum = 0;
    for (int i = 0; i < WIDTH * HEIGHT; i++) sum += image[i];
    printf("checksum: %u (%s, %dx%d, %d reps)\n", sum, use_simd ? "simd" : "scalar", WIDTH, HEIGHT, reps);
    return 0;
}
