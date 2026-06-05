#include <sightglass.h>
#include <assert.h>
#include <ctype.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#define STR_SIZE 50000
#define ITERATIONS 1000

int main()
{
    size_t str_size = STR_SIZE;
    char* str = malloc(str_size);
    assert(str != NULL);
    size_t ret = (size_t)0U;
    size_t j;
    int i;

    assert(str_size >= 2U);
    memset(str, 'x', str_size);
    str[str_size - 1U] = 0;

    printf("[ctype] running with str_size = %zu for %d iterations\n", str_size, ITERATIONS);
    bench_start();
    for (i = 0; i < ITERATIONS; i++)
    {
        BLACK_BOX(str);
        for (j = 0U; j < str_size; j++)
        {
            ret += isalpha((int)(unsigned char)str[j]);
            ret += isalnum((int)(unsigned char)str[j]);
            ret += isdigit((int)(unsigned char)str[j]);
            ret += isspace((int)(unsigned char)str[j]);
            ret += isprint((int)(unsigned char)str[j]);
            if (isupper((int)(unsigned char)str[j]))
            {
                str[j] = (char)tolower((int)(unsigned char)str[j]);
            }
            else if (islower((int)(unsigned char)str[j]))
            {
                str[j] = (char)toupper((int)(unsigned char)str[j]);
            }
        }
    }
    bench_end();
    printf("[ctype] returned: %s\n", str);

    free(str);
    BLACK_BOX(ret);
}
