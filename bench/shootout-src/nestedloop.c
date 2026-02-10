
#include <sightglass.h>
#include <stdio.h>
#include <stdlib.h>

#define LENGTH 30

int main()
{
    int n = LENGTH;
    BLACK_BOX(n);
    int a, b, c, d, e, f, x = 0;
    BLACK_BOX(x);

    printf("[nestedloop] running 6 nested loops with %d iterations each\n", n);
    bench_start();
    for (a = 0; a < n; a++) {
        for (b = 0; b < n; b++) {
            for (c = 0; c < n; c++) {
                for (d = 0; d < n; d++) {
                    for (e = 0; e < n; e++) {
                        for (f = 0; f < n; f++) {
                            x++;
                        }
                    }
                }
            }
        }
    }
    bench_end();

    BLACK_BOX(x);
    printf("[nestedloop] returned %d\n", x);
}
