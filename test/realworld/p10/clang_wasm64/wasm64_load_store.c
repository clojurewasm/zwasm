// Wasm 3.0 memory64 (function-references era) — clang --target=wasm64
// emits a `(memory i64 ...)` module: memory ops take an i64 address.
// `volatile` keeps the store+load from being const-folded by -O2, so the
// compiled `test` genuinely exercises the i64-addressed i32.store / i32.load
// JIT path (the realworld counterpart of the hand-written memory64 spec
// corpus). Returns 42.
static volatile int g_mem[8];
int test(void) {
    g_mem[3] = 42;
    return g_mem[3];
}
