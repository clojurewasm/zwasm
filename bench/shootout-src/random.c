#include <sightglass.h>
#include <stdio.h>
#include <stdlib.h>

#define LENGTH 40000000
#define IA 3877
#define IC 29573
#define IM 139968

static inline double
gen_random(double max, long ia, long ic, long im)
{
    static long last = 42;
    last = (last * ia + ic) % im;
    return max * last / im;
}

int main()
{
    long ia = IA;
    long ic = IC;
    long im = IM;
    int n = LENGTH;
    BLACK_BOX(n);

    printf("[random] generating random number in %d iterations\n", n);
    bench_start();
    while (n--) {
        gen_random(100.0, ia, ic, im);
    }
    double res = gen_random(100.0, ia, ic, im);
    bench_end();
    printf("[random] returned %f\n", res);

    BLACK_BOX(res);
}
