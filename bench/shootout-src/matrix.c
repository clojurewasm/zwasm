#include <sightglass.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

#define ITERATIONS 300000
#define SIZE 10

static int**
mkmatrix(int rows, int cols)
{
    int** m = calloc(rows, sizeof(int*));
    assert(m != NULL);

    int i, j, count = 1;
    for (i = 0; i < rows; i++) {
        m[i] = calloc(cols, sizeof(int));
        assert(m[i] != NULL);
        for (j = 0; j < cols; j++) {
            m[i][j] = count++;
        }
    }
    return m;
}

static void
freematrix(int rows, int** m)
{
    while (--rows > -1) {
        free(m[rows]);
    }
    free(m);
}

static int**
mmult(int rows, int cols, int** m1, int** m2, int** m3)
{
    int i, j, k, val;

    for (i = 0; i < rows; i++) {
        for (j = 0; j < cols; j++) {
            val = 0;
            for (k = 0; k < cols; k++) {
                val += m1[i][k] * m2[k][j];
            }
            m3[i][j] = val;
        }
    }
    return m3;
}

int main()
{
    // SETUP
    int rows = SIZE;
    int cols = SIZE;
    int** m1 = mkmatrix(rows, cols);
    int** m2 = mkmatrix(rows, cols);
    int** mm = mkmatrix(rows, cols);
    assert(m1 != NULL && m2 != NULL && mm != NULL);

    // BENCHMARK
    printf("[matrix] running matrix multiplication on %d rows, %d columns for %d iterations\n", rows, cols, ITERATIONS);
    bench_start();
    int i;
    for (i = 0; i < ITERATIONS; i++) {
        mm = mmult(rows, cols, m1, m2, mm);
    }
    int res = mm[0][0] + mm[2][3] + mm[3][2] + mm[4][4];
    bench_end();
    BLACK_BOX(res);
    printf("[matrix] returned %d\n", res);

    // TEARDOWN
    freematrix(rows, m1);
    freematrix(rows, m2);
    freematrix(rows, mm);
}
