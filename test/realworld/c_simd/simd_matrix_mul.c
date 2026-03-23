// SIMD 4x4 matrix multiplication
#include <wasm_simd128.h>
#include <stdio.h>

typedef struct { float m[4][4]; } Mat4;

static Mat4 mat_mul_simd(const Mat4 *a, const Mat4 *b) {
    Mat4 result;
    for (int i = 0; i < 4; i++) {
        v128_t row = wasm_f32x4_const(0, 0, 0, 0);
        for (int k = 0; k < 4; k++) {
            v128_t s = wasm_f32x4_splat(a->m[i][k]);
            v128_t bcol = wasm_v128_load(&b->m[k][0]);
            row = wasm_f32x4_add(row, wasm_f32x4_mul(s, bcol));
        }
        wasm_v128_store(&result.m[i][0], row);
    }
    return result;
}

int main(void) {
    Mat4 a = {{{1,2,3,4},{5,6,7,8},{9,10,11,12},{13,14,15,16}}};
    Mat4 b = {{{2,0,0,0},{0,2,0,0},{0,0,2,0},{0,0,0,2}}};

    Mat4 c = a;
    for (int i = 0; i < 100; i++) {
        c = mat_mul_simd(&c, &b);
    }

    printf("%.0f\n", c.m[0][0]);
    return 0;
}
