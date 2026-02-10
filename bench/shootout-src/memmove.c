#include <sightglass.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>

#define STR_SIZE 10000
#define ITERATIONS 10

int main()
{
    size_t str_size = STR_SIZE;
    char* str = calloc(str_size, (size_t)1U);
    assert(str != NULL);

    bench_start();
    int i;
    size_t j;
    for (i = 0; i < ITERATIONS; i++) {
        BLACK_BOX(str);
        for (j = (size_t)0U; j < str_size - (size_t)1U; j++) {
            memmove(&str[j], str, str_size - j);
        }
        for (j = (size_t)0U; j < str_size - (size_t)1U; j++) {
            memmove(str, &str[j], str_size - j);
        }
    }
    bench_end();

    char ret = str[0];
    BLACK_BOX(str);
    free(str);
}
