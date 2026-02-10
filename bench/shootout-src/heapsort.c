
#include <sightglass.h>
#include <math.h>
#include <stdlib.h>

#define LENGTH 10000
#define ITERATIONS 1000

#define IM 139968
#define IA 3877
#define IC 29573

static double
gen_random(double max)
{
    static long last = 42;
    return max * (last = (last * IA + IC) % IM) / IM;
}

static void
my_heapsort(int n, double* ra)
{
    int    i, j;
    int    ir = n;
    int    l = (n >> 1) + 1;
    double rra;

    for (;;) {
        if (l > 1) {
            rra = ra[--l];
        }
        else {
            rra = ra[ir];
            ra[ir] = ra[1];
            if (--ir == 1) {
                ra[1] = rra;
                return;
            }
        }

        i = l;
        j = l << 1;
        while (j <= ir) {
            if (j < ir && ra[j] < ra[j + 1]) {
                ++j;
            }
            if (rra < ra[j]) {
                ra[i] = ra[j];
                j += (i = j);
            }
            else {
                j = ir + 1;
            }
        }
        ra[i] = rra;
    }
}

int main()
{
    int n = LENGTH;
    double* ary = calloc(n + 1, sizeof(double));
    double res;

    bench_start();
    int i, j;
    for (i = 0; i < ITERATIONS; i++) {
        BLACK_BOX(ary);
        BLACK_BOX(n);
        for (j = 1; j <= n; j++) {
            ary[j] = gen_random(1.0);
        }
        my_heapsort(n, ary);
        res = ary[n];
        BLACK_BOX(res);
    }
    bench_end();

    free(ary);
}
