
#include <stdio.h>
#include "sightglass.h"

int main()
{
    printf("[noop] calls bench_start and bench_end with no intervening code\n");
    bench_start();
    bench_end();
    printf("[noop] complete\n");
}
