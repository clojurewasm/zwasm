// SIMD benchmark: N-body gravitational simulation
// Usage: nbody_simd.wasm <scalar|simd>
// Build: wasm32-wasi-clang -O2 -msimd128 -o nbody_simd.wasm nbody_simd.c

#include <wasm_simd128.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

#define NUM_BODIES 128
#define DT 0.01f
#define SOFTENING 0.001f
#define ITERS 200

static float pos_x[NUM_BODIES], pos_y[NUM_BODIES], pos_z[NUM_BODIES];
static float vel_x[NUM_BODIES], vel_y[NUM_BODIES], vel_z[NUM_BODIES];
static float mass[NUM_BODIES];

static float spos[NUM_BODIES * 4];
static float svel[NUM_BODIES * 4];
static float smass[NUM_BODIES];

static void init_bodies(void) {
    for (int i = 0; i < NUM_BODIES; i++) {
        float fi = (float)(i + 1);
        pos_x[i] = spos[i*4+0] = fi * 0.1f;
        pos_y[i] = spos[i*4+1] = fi * 0.2f - 10.0f;
        pos_z[i] = spos[i*4+2] = fi * 0.05f - 3.0f;
        spos[i*4+3] = 0.0f;
        vel_x[i] = svel[i*4+0] = 0.0f;
        vel_y[i] = svel[i*4+1] = 0.0f;
        vel_z[i] = svel[i*4+2] = 0.0f;
        svel[i*4+3] = 0.0f;
        mass[i] = smass[i] = 1.0f + fi * 0.01f;
    }
}

static void step_scalar(void) {
    for (int i = 0; i < NUM_BODIES; i++) {
        float fx = 0, fy = 0, fz = 0;
        for (int j = 0; j < NUM_BODIES; j++) {
            if (i == j) continue;
            float dx = pos_x[j] - pos_x[i];
            float dy = pos_y[j] - pos_y[i];
            float dz = pos_z[j] - pos_z[i];
            float dist2 = dx*dx + dy*dy + dz*dz + SOFTENING;
            float inv_dist = 1.0f / sqrtf(dist2);
            float inv_dist3 = inv_dist * inv_dist * inv_dist;
            float f = mass[j] * inv_dist3;
            fx += dx * f; fy += dy * f; fz += dz * f;
        }
        vel_x[i] += fx * DT; vel_y[i] += fy * DT; vel_z[i] += fz * DT;
    }
    for (int i = 0; i < NUM_BODIES; i++) {
        pos_x[i] += vel_x[i] * DT;
        pos_y[i] += vel_y[i] * DT;
        pos_z[i] += vel_z[i] * DT;
    }
}

static void step_simd(void) {
    v128_t dt_vec = wasm_f32x4_splat(DT);

    for (int i = 0; i < NUM_BODIES; i++) {
        v128_t pi = wasm_v128_load(&spos[i * 4]);
        v128_t force = wasm_f32x4_splat(0.0f);

        for (int j = 0; j < NUM_BODIES; j++) {
            if (i == j) continue;
            v128_t pj = wasm_v128_load(&spos[j * 4]);
            v128_t d = wasm_f32x4_sub(pj, pi);
            v128_t d2 = wasm_f32x4_mul(d, d);
            float dist2 = wasm_f32x4_extract_lane(d2, 0) +
                          wasm_f32x4_extract_lane(d2, 1) +
                          wasm_f32x4_extract_lane(d2, 2) + SOFTENING;
            float inv_dist = 1.0f / sqrtf(dist2);
            float f = smass[j] * inv_dist * inv_dist * inv_dist;
            v128_t f_vec = wasm_f32x4_splat(f);
            force = wasm_f32x4_add(force, wasm_f32x4_mul(d, f_vec));
        }

        v128_t vi = wasm_v128_load(&svel[i * 4]);
        vi = wasm_f32x4_add(vi, wasm_f32x4_mul(force, dt_vec));
        wasm_v128_store(&svel[i * 4], vi);
    }

    for (int i = 0; i < NUM_BODIES; i++) {
        v128_t p = wasm_v128_load(&spos[i * 4]);
        v128_t v = wasm_v128_load(&svel[i * 4]);
        p = wasm_f32x4_add(p, wasm_f32x4_mul(v, dt_vec));
        wasm_v128_store(&spos[i * 4], p);
    }
}

int main(int argc, char **argv) {
    init_bodies();
    int use_simd = (argc > 1 && strcmp(argv[1], "simd") == 0);

    for (int i = 0; i < ITERS; i++) {
        if (use_simd) step_simd(); else step_scalar();
    }

    if (use_simd) {
        printf("pos[0]: %.6f %.6f %.6f\n", spos[0], spos[1], spos[2]);
    } else {
        printf("pos[0]: %.6f %.6f %.6f\n", pos_x[0], pos_y[0], pos_z[0]);
    }
    return 0;
}
