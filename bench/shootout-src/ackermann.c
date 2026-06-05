// Modified from: https://github.com/bytecodealliance/sightglass/blob/main/benchmarks/shootout/src/ackermann.c
// Changes: removed file I/O (open/read), hardcoded M=3, N=7 inputs.
// Original read M and N from external files via WASI filesystem.
// ackermann(3,7) = 1021 — fits in wasm call stack (M=3,N>=9 overflows).

#include <sightglass.h>
#include <stdio.h>

int ackermann(int M, int N)
{
    if (M == 0)
    {
        return N + 1;
    }
    if (N == 0)
    {
        return ackermann(M - 1, 1);
    }
    return ackermann(M - 1, ackermann(M, (N - 1)));
}

int main()
{
    int M = 3;
    int N = 7;
    printf("[ackermann] running with M = %d and N = %d\n", M, N);

    bench_start();
    int result = ackermann(M, N);
    bench_end();

    printf("[ackermann] returned %d\n", result);
    BLACK_BOX(result);
}
