# noop

This benchmark performs no work: it simply calls `bench_start` and `bench_end` back to back. This
shows us the overhead involved with the infrastructure, a combination of, e.g.:
 - the overhead of calling an imported Wasm function
 - the overhead of our measurement mechanism
