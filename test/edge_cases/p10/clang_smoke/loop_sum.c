// Regular clang output (loop + memory + globals, no tail-call): sum 1..10 = 55.
// Proves the clang --target=wasm32 → zwasm JIT realworld pipeline.
int test(void) {
    int s = 0;
    for (int i = 1; i <= 10; i++) s += i;
    return s;
}
