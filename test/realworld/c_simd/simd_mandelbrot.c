// SIMD Mandelbrot set: compute 64x64 grid, count total iterations
#include <wasm_simd128.h>
#include <stdio.h>

int main(void) {
    const int W = 64, H = 64, MAX_ITER = 100;
    long total = 0;

    for (int py = 0; py < H; py++) {
        float cy = -2.0f + 4.0f * (float)py / (float)H;
        for (int px = 0; px < W; px += 4) {
            // Process 4 pixels at once
            v128_t cx = wasm_f32x4_make(
                -2.0f + 4.0f * (float)(px+0) / (float)W,
                -2.0f + 4.0f * (float)(px+1) / (float)W,
                -2.0f + 4.0f * (float)(px+2) / (float)W,
                -2.0f + 4.0f * (float)(px+3) / (float)W
            );
            v128_t vcy = wasm_f32x4_splat(cy);

            v128_t zr = wasm_f32x4_const(0,0,0,0);
            v128_t zi = wasm_f32x4_const(0,0,0,0);
            v128_t iters = wasm_i32x4_const(0,0,0,0);
            v128_t one = wasm_i32x4_const(1,1,1,1);
            v128_t four = wasm_f32x4_const(4,4,4,4);

            for (int i = 0; i < MAX_ITER; i++) {
                v128_t zr2 = wasm_f32x4_mul(zr, zr);
                v128_t zi2 = wasm_f32x4_mul(zi, zi);
                v128_t mag2 = wasm_f32x4_add(zr2, zi2);
                v128_t mask = wasm_f32x4_le(mag2, four);
                if (!wasm_v128_any_true(mask)) break;
                // iters += mask & 1
                iters = wasm_i32x4_add(iters, wasm_v128_and(mask, one));
                v128_t zr_new = wasm_f32x4_add(wasm_f32x4_sub(zr2, zi2), cx);
                zi = wasm_f32x4_add(wasm_f32x4_mul(wasm_f32x4_add(zr, zr), zi), vcy);
                zr = zr_new;
            }

            total += (long)wasm_i32x4_extract_lane(iters, 0)
                   + (long)wasm_i32x4_extract_lane(iters, 1)
                   + (long)wasm_i32x4_extract_lane(iters, 2)
                   + (long)wasm_i32x4_extract_lane(iters, 3);
        }
    }

    printf("%ld\n", total);
    return 0;
}
