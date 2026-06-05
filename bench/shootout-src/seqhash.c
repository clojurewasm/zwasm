#include <sightglass.h>

#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ARENA_SIZE ((size_t)1000000)
#define LEVEL_FIRST 1
#define LEVEL_LAST 5
#define LEVELS (LEVEL_LAST - LEVEL_FIRST + 1)
#define HASH_ITERATIONS 1

#define SUFFIX_LEN 32
#define HASHSEQ_LOCATIONS 8
#define ROTR32(X, B) (uint32_t)(((X) >> (B)) | ((X) << (32 - (B))))

#define G(A, B, C, D)                \
    do                               \
    {                                \
        (A) += (B);                  \
        (D) = ROTR32((D) ^ (A), 16); \
        (C) += (D);                  \
        (B) = ROTR32((B) ^ (C), 12); \
        (A) += (B);                  \
        (D) = ROTR32((D) ^ (A), 8);  \
        (C) += (D);                  \
        (B) = ROTR32((B) ^ (C), 7);  \
    } while (0)

static const uint32_t IV[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                               0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

typedef struct Mask_
{
    uint32_t m0;
    uint32_t m1;
} Mask;

typedef struct HashSeqArena_
{
    uint32_t *base;
    uint32_t mask;
    uint32_t size;
} HashSeqArena;

typedef struct HashSeqSolution_
{
    uint32_t s0;
    uint32_t s1;
} HashSeqSolution;

static inline void
permute(uint32_t state[16])
{
    G(state[0], state[4], state[8], state[12]);
    G(state[1], state[5], state[9], state[13]);
    G(state[2], state[6], state[10], state[14]);
    G(state[3], state[7], state[11], state[15]);

    G(state[0], state[5], state[10], state[15]);
    G(state[1], state[6], state[11], state[12]);
    G(state[2], state[7], state[8], state[13]);
    G(state[3], state[4], state[9], state[14]);
}

static inline void
hash_init(uint32_t state[16], const uint32_t suffix[8], uint32_t level, uint32_t iteration)
{
    int i;

    memcpy(&state[0], IV, 8 * sizeof state[0]);
    state[7] ^= (level << 16) | iteration;
    for (i = 0; i < 8; i++)
    {
        state[8 + i] = IV[i] ^ suffix[i];
    }
}

static int
hash_try(HashSeqArena *arena, uint32_t ostate[16], uint32_t istate[16],
         const HashSeqSolution *proposal, const Mask *mask)
{
    uint32_t *locations[2 * HASHSEQ_LOCATIONS], *location1, *location2;
    uint32_t f0, f1;
    uint32_t pass, passes;
    uint32_t off;
    size_t i, j;

    passes = arena->size;
    istate[0] = IV[0] ^ proposal->s0;
    istate[1] = IV[1] ^ proposal->s1;
    memcpy(ostate, istate, 16 * sizeof ostate[0]);
    for (i = 0; i < 5; i++)
    {
        permute(ostate);
    }
    for (pass = 0; pass < passes; pass++)
    {
        for (i = 0; i < sizeof locations / sizeof locations[0]; i++)
        {
            permute(ostate);
            locations[i] = &arena->base[ostate[0] & arena->mask];
        }
        for (i = 0; i < sizeof locations / sizeof locations[0] / 2; i++)
        {
            location1 = locations[i];
            location2 = locations[i + sizeof locations / sizeof locations[0] / 2];
            permute(ostate);
            for (j = 0; j < 16; j++)
            {
                location1[i] ^= location2[i] + ostate[i];
            }
        }
    }
    for (off = 0; off <= arena->size - 8 * sizeof ostate[0]; off += 8 * sizeof ostate[0])
    {
        for (i = 0; i < 8; i++)
        {
            ostate[i] ^= arena->base[off + i];
        }
        permute(ostate);
    }
    f0 = ostate[0];
    f1 = ostate[1];
    for (i = 2; i < 16; i += 2)
    {
        f0 ^= ostate[i];
        f1 ^= ostate[i + 1];
    }
    return ((f0 & mask->m0) | (f1 & mask->m1)) == 0U;
}

static void
mask_from_level(Mask *mask, uint32_t level)
{
    if (level > 32U)
    {
        mask->m0 = ~0U;
        mask->m1 = (1U << (level - 32)) - 1U;
    }
    else
    {
        mask->m1 = 0U;
        mask->m0 = (1U << level) - 1U;
    }
}

static int
solve1(HashSeqArena *arena, HashSeqSolution *solution, uint32_t suffix[8], uint32_t level,
       uint32_t iteration)
{
    uint32_t istate[16], ostate[16];
    Mask mask;
    HashSeqSolution proposal;

    hash_init(istate, suffix, level, iteration);
    mask_from_level(&mask, level);
    proposal.s0 = proposal.s1 = 0U;
    while (hash_try(arena, ostate, istate, &proposal, &mask) == 0)
    {
        if (++proposal.s0 == 0U)
        {
            proposal.s1++;
        }
    }
    memcpy(suffix, &ostate[8], 8 * sizeof ostate[0]);
    memcpy(solution, &proposal, sizeof *solution);

    return 0;
}

static int
hashseq_arena_init(HashSeqArena *arena, uint32_t *base, size_t size)
{
    uint32_t mask;

    memset(base, 0, size);
    size /= sizeof base[0];
    if (size < 32 || size > (size_t)(uint32_t)-1)
    {
        return -1;
    }
    arena->base = base;
    arena->size = (uint32_t)size;
    mask = 0U;
    while (mask < (size >> 1))
    {
        mask = (mask << 1) | 1;
    }
    mask &= ~15U;
    if (mask == 0U)
    {
        return -1;
    }
    arena->mask = mask;

    return 0;
}

static int
hashseq_solve(HashSeqArena *arena, HashSeqSolution *solutions, const uint32_t suffix[8],
              uint32_t level_first, uint32_t level_last, uint32_t iterations)
{
    uint32_t suffix_[8];
    uint32_t level, iteration;
    int i = 0;

    memcpy(suffix_, suffix, sizeof suffix_);
    for (level = level_first; level <= level_last; level++)
    {
        for (iteration = 0; iteration < iterations; iteration++)
        {
            if (solve1(arena, &solutions[i++], suffix_, level, iteration))
            {
                return -1;
            }
        }
    }
    return 0;
}

int main()
{
    void *buf = calloc(ARENA_SIZE, (size_t)1U);
    assert(buf != NULL);
    HashSeqArena arena;
    HashSeqSolution solutions[LEVELS];
    uint32_t suffix[8];

    BLACK_BOX(buf);
    memcpy(suffix, buf, sizeof suffix);
    BLACK_BOX(suffix);

    hashseq_arena_init(&arena, buf, ARENA_SIZE);

    bench_start();
    hashseq_solve(&arena, solutions, suffix, LEVEL_FIRST, LEVEL_LAST, HASH_ITERATIONS);
    bench_end();

    BLACK_BOX(arena);
    BLACK_BOX(buf);
    BLACK_BOX(solutions);
    free(buf);
}
