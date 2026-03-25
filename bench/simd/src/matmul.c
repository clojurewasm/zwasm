// SIMD benchmark: Matrix multiplication (GEMM)
// Classic SIMD benchmark — C = A * B for square matrices.
// Usage: matmul.wasm <scalar|simd>
// Build: wasm32-wasi-clang -O2 -msimd128 -o matmul.wasm matmul.c -lm

#include <wasm_simd128.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define N 256

static float A[N * N];
static float B[N * N];
static float C[N * N];

static void init_matrices(void) {
    for (int i = 0; i < N * N; i++) {
        A[i] = (float)(i % 97) * 0.01f;
        B[i] = (float)(i % 53) * 0.01f;
    }
}

// --- Scalar version ---
static void matmul_scalar(void) {
    memset(C, 0, sizeof(C));
    for (int i = 0; i < N; i++) {
        for (int k = 0; k < N; k++) {
            float a_ik = A[i * N + k];
            for (int j = 0; j < N; j++) {
                C[i * N + j] += a_ik * B[k * N + j];
            }
        }
    }
}

// --- SIMD version (4-wide f32x4) ---
static void matmul_simd(void) {
    memset(C, 0, sizeof(C));
    for (int i = 0; i < N; i++) {
        for (int k = 0; k < N; k++) {
            v128_t va = wasm_f32x4_splat(A[i * N + k]);
            for (int j = 0; j < N; j += 4) {
                v128_t vc = wasm_v128_load(&C[i * N + j]);
                v128_t vb = wasm_v128_load(&B[k * N + j]);
                vc = wasm_f32x4_add(vc, wasm_f32x4_mul(va, vb));
                wasm_v128_store(&C[i * N + j], vc);
            }
        }
    }
}

int main(int argc, char **argv) {
    int use_simd = (argc > 1 && strcmp(argv[1], "simd") == 0);
    int reps = 10;

    init_matrices();

    for (int r = 0; r < reps; r++) {
        if (use_simd) matmul_simd();
        else matmul_scalar();
    }

    // Checksum (sum of C)
    double sum = 0.0;
    for (int i = 0; i < N * N; i++) sum += C[i];
    printf("checksum: %.6f (%s, %dx%d, %d reps)\n", sum, use_simd ? "simd" : "scalar", N, N, reps);
    return 0;
}
