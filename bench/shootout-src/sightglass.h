// No-op replacement for sightglass.h from:
//   https://github.com/bytecodealliance/sightglass/blob/main/benchmarks/shootout/src/sightglass.h
//
// Original defines bench_start()/bench_end() as wasm imports from "bench" module
// (used by sightglass-recorder for profiling). We replace them with empty inline
// functions so the compiled .wasm has no external bench imports and can run on
// any wasm runtime without stub modules.

#ifndef sightglass_h
#define sightglass_h 1

static void bench_start(void) {}
static void bench_end(void) {}

#ifndef black_box
static void _black_box(void *x) { (void)x; }
static void (*volatile black_box)(void *x) = _black_box;
#else
void black_box(void *x);
#endif
#define BLACK_BOX(X) black_box((void *)&(X))

#endif
