
#include <sightglass.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define ITERATIONS 10000

#if defined(__SIZEOF_INT128__)
typedef unsigned __int128 uint128_t;
#else
typedef unsigned uint128_t __attribute__((mode(TI)));
#endif

typedef uint64_t fe25519[5];

#define LOAD64_LE(SRC) load64_le(SRC)
static inline uint64_t
load64_le(const uint8_t src[8])
{
    uint64_t w = (uint64_t)src[0];
    w |= (uint64_t)src[1] << 8;
    w |= (uint64_t)src[2] << 16;
    w |= (uint64_t)src[3] << 24;
    w |= (uint64_t)src[4] << 32;
    w |= (uint64_t)src[5] << 40;
    w |= (uint64_t)src[6] << 48;
    w |= (uint64_t)src[7] << 56;
    return w;
}

#define STORE64_LE(DST, W) store64_le((DST), (W))
static inline void
store64_le(uint8_t dst[8], uint64_t w)
{
    dst[0] = (uint8_t)w;
    w >>= 8;
    dst[1] = (uint8_t)w;
    w >>= 8;
    dst[2] = (uint8_t)w;
    w >>= 8;
    dst[3] = (uint8_t)w;
    w >>= 8;
    dst[4] = (uint8_t)w;
    w >>= 8;
    dst[5] = (uint8_t)w;
    w >>= 8;
    dst[6] = (uint8_t)w;
    w >>= 8;
    dst[7] = (uint8_t)w;
}

static inline void
fe25519_0(fe25519 h)
{
    memset(&h[0], 0, 5 * sizeof h[0]);
}

static inline void
fe25519_1(fe25519 h)
{
    h[0] = 1;
    memset(&h[1], 0, 4 * sizeof h[0]);
}

static inline void
fe25519_add(fe25519 h, const fe25519 f, const fe25519 g)
{
    uint64_t h0 = f[0] + g[0];
    uint64_t h1 = f[1] + g[1];
    uint64_t h2 = f[2] + g[2];
    uint64_t h3 = f[3] + g[3];
    uint64_t h4 = f[4] + g[4];

    h[0] = h0;
    h[1] = h1;
    h[2] = h2;
    h[3] = h3;
    h[4] = h4;
}

static void
fe25519_sub(fe25519 h, const fe25519 f, const fe25519 g)
{
    const uint64_t mask = 0x7ffffffffffffULL;
    uint64_t       h0, h1, h2, h3, h4;

    h0 = g[0];
    h1 = g[1];
    h2 = g[2];
    h3 = g[3];
    h4 = g[4];

    h1 += h0 >> 51;
    h0 &= mask;
    h2 += h1 >> 51;
    h1 &= mask;
    h3 += h2 >> 51;
    h2 &= mask;
    h4 += h3 >> 51;
    h3 &= mask;
    h0 += 19ULL * (h4 >> 51);
    h4 &= mask;

    h0 = (f[0] + 0xfffffffffffdaULL) - h0;
    h1 = (f[1] + 0xffffffffffffeULL) - h1;
    h2 = (f[2] + 0xffffffffffffeULL) - h2;
    h3 = (f[3] + 0xffffffffffffeULL) - h3;
    h4 = (f[4] + 0xffffffffffffeULL) - h4;

    h[0] = h0;
    h[1] = h1;
    h[2] = h2;
    h[3] = h3;
    h[4] = h4;
}

static inline void
fe25519_neg(fe25519 h, const fe25519 f)
{
    fe25519 zero;

    fe25519_0(zero);
    fe25519_sub(h, zero, f);
}

static void
fe25519_cmov(fe25519 f, const fe25519 g, unsigned int b)
{
    const uint64_t mask = (uint64_t)(-(int64_t)b);

    uint64_t f0 = f[0];
    uint64_t f1 = f[1];
    uint64_t f2 = f[2];
    uint64_t f3 = f[3];
    uint64_t f4 = f[4];

    uint64_t x0 = f0 ^ g[0];
    uint64_t x1 = f1 ^ g[1];
    uint64_t x2 = f2 ^ g[2];
    uint64_t x3 = f3 ^ g[3];
    uint64_t x4 = f4 ^ g[4];

    x0 &= mask;
    x1 &= mask;
    x2 &= mask;
    x3 &= mask;
    x4 &= mask;

    f[0] = f0 ^ x0;
    f[1] = f1 ^ x1;
    f[2] = f2 ^ x2;
    f[3] = f3 ^ x3;
    f[4] = f4 ^ x4;
}

static inline void
fe25519_copy(fe25519 h, const fe25519 f)
{
    uint64_t f0 = f[0];
    uint64_t f1 = f[1];
    uint64_t f2 = f[2];
    uint64_t f3 = f[3];
    uint64_t f4 = f[4];

    h[0] = f0;
    h[1] = f1;
    h[2] = f2;
    h[3] = f3;
    h[4] = f4;
}

static void
fe25519_reduce(fe25519 h, const fe25519 f)
{
    const uint64_t mask = 0x7ffffffffffffULL;
    uint128_t      t[5];

    t[0] = f[0];
    t[1] = f[1];
    t[2] = f[2];
    t[3] = f[3];
    t[4] = f[4];

    t[1] += t[0] >> 51;
    t[0] &= mask;
    t[2] += t[1] >> 51;
    t[1] &= mask;
    t[3] += t[2] >> 51;
    t[2] &= mask;
    t[4] += t[3] >> 51;
    t[3] &= mask;
    t[0] += 19 * (t[4] >> 51);
    t[4] &= mask;

    t[1] += t[0] >> 51;
    t[0] &= mask;
    t[2] += t[1] >> 51;
    t[1] &= mask;
    t[3] += t[2] >> 51;
    t[2] &= mask;
    t[4] += t[3] >> 51;
    t[3] &= mask;
    t[0] += 19 * (t[4] >> 51);
    t[4] &= mask;

    t[0] += 19ULL;

    t[1] += t[0] >> 51;
    t[0] &= mask;
    t[2] += t[1] >> 51;
    t[1] &= mask;
    t[3] += t[2] >> 51;
    t[2] &= mask;
    t[4] += t[3] >> 51;
    t[3] &= mask;
    t[0] += 19ULL * (t[4] >> 51);
    t[4] &= mask;

    t[0] += 0x8000000000000 - 19ULL;
    t[1] += 0x8000000000000 - 1ULL;
    t[2] += 0x8000000000000 - 1ULL;
    t[3] += 0x8000000000000 - 1ULL;
    t[4] += 0x8000000000000 - 1ULL;

    t[1] += t[0] >> 51;
    t[0] &= mask;
    t[2] += t[1] >> 51;
    t[1] &= mask;
    t[3] += t[2] >> 51;
    t[2] &= mask;
    t[4] += t[3] >> 51;
    t[3] &= mask;
    t[4] &= mask;

    h[0] = t[0];
    h[1] = t[1];
    h[2] = t[2];
    h[3] = t[3];
    h[4] = t[4];
}

static void
fe25519_tobytes(unsigned char* s, const fe25519 h)
{
    fe25519  t;
    uint64_t t0, t1, t2, t3;

    fe25519_reduce(t, h);
    t0 = t[0] | (t[1] << 51);
    t1 = (t[1] >> 13) | (t[2] << 38);
    t2 = (t[2] >> 26) | (t[3] << 25);
    t3 = (t[3] >> 39) | (t[4] << 12);
    STORE64_LE(s + 0, t0);
    STORE64_LE(s + 8, t1);
    STORE64_LE(s + 16, t2);
    STORE64_LE(s + 24, t3);
}

static inline int
fe25519_isnegative(const fe25519 f)
{
    unsigned char s[32];

    fe25519_tobytes(s, f);

    return s[0] & 1;
}

static int
is_zero(const unsigned char* n, const size_t nlen)
{
    size_t                 i;
    volatile unsigned char d = 0U;

    for (i = 0U; i < nlen; i++) {
        d |= n[i];
    }
    return 1 & ((d - 1) >> 8);
}

static inline int
fe25519_iszero(const fe25519 f)
{
    unsigned char s[32];

    fe25519_tobytes(s, f);

    return is_zero(s, 32);
}

static void
fe25519_mul(fe25519 h, const fe25519 f, const fe25519 g)
{
    const uint64_t mask = 0x7ffffffffffffULL;
    uint128_t      r0, r1, r2, r3, r4, carry;
    uint64_t       f0, f1, f2, f3, f4;
    uint64_t       f1_19, f2_19, f3_19, f4_19;
    uint64_t       g0, g1, g2, g3, g4;
    uint64_t       r00, r01, r02, r03, r04;

    f0 = f[0];
    f1 = f[1];
    f2 = f[2];
    f3 = f[3];
    f4 = f[4];

    g0 = g[0];
    g1 = g[1];
    g2 = g[2];
    g3 = g[3];
    g4 = g[4];

    f1_19 = 19ULL * f1;
    f2_19 = 19ULL * f2;
    f3_19 = 19ULL * f3;
    f4_19 = 19ULL * f4;

    r0 = ((uint128_t)f0) * ((uint128_t)g0);
    r0 += ((uint128_t)f1_19) * ((uint128_t)g4);
    r0 += ((uint128_t)f2_19) * ((uint128_t)g3);
    r0 += ((uint128_t)f3_19) * ((uint128_t)g2);
    r0 += ((uint128_t)f4_19) * ((uint128_t)g1);

    r1 = ((uint128_t)f0) * ((uint128_t)g1);
    r1 += ((uint128_t)f1) * ((uint128_t)g0);
    r1 += ((uint128_t)f2_19) * ((uint128_t)g4);
    r1 += ((uint128_t)f3_19) * ((uint128_t)g3);
    r1 += ((uint128_t)f4_19) * ((uint128_t)g2);

    r2 = ((uint128_t)f0) * ((uint128_t)g2);
    r2 += ((uint128_t)f1) * ((uint128_t)g1);
    r2 += ((uint128_t)f2) * ((uint128_t)g0);
    r2 += ((uint128_t)f3_19) * ((uint128_t)g4);
    r2 += ((uint128_t)f4_19) * ((uint128_t)g3);

    r3 = ((uint128_t)f0) * ((uint128_t)g3);
    r3 += ((uint128_t)f1) * ((uint128_t)g2);
    r3 += ((uint128_t)f2) * ((uint128_t)g1);
    r3 += ((uint128_t)f3) * ((uint128_t)g0);
    r3 += ((uint128_t)f4_19) * ((uint128_t)g4);

    r4 = ((uint128_t)f0) * ((uint128_t)g4);
    r4 += ((uint128_t)f1) * ((uint128_t)g3);
    r4 += ((uint128_t)f2) * ((uint128_t)g2);
    r4 += ((uint128_t)f3) * ((uint128_t)g1);
    r4 += ((uint128_t)f4) * ((uint128_t)g0);

    r00 = ((uint64_t)r0) & mask;
    carry = r0 >> 51;
    r1 += carry;
    r01 = ((uint64_t)r1) & mask;
    carry = r1 >> 51;
    r2 += carry;
    r02 = ((uint64_t)r2) & mask;
    carry = r2 >> 51;
    r3 += carry;
    r03 = ((uint64_t)r3) & mask;
    carry = r3 >> 51;
    r4 += carry;
    r04 = ((uint64_t)r4) & mask;
    carry = r4 >> 51;
    r00 += 19ULL * (uint64_t)carry;
    carry = r00 >> 51;
    r00 &= mask;
    r01 += (uint64_t)carry;
    carry = r01 >> 51;
    r01 &= mask;
    r02 += (uint64_t)carry;

    h[0] = r00;
    h[1] = r01;
    h[2] = r02;
    h[3] = r03;
    h[4] = r04;
}

static void
fe25519_sq(fe25519 h, const fe25519 f)
{
    const uint64_t mask = 0x7ffffffffffffULL;
    uint128_t      r0, r1, r2, r3, r4, carry;
    uint64_t       f0, f1, f2, f3, f4;
    uint64_t       f0_2, f1_2, f1_38, f2_38, f3_38, f3_19, f4_19;
    uint64_t       r00, r01, r02, r03, r04;

    f0 = f[0];
    f1 = f[1];
    f2 = f[2];
    f3 = f[3];
    f4 = f[4];

    f0_2 = f0 << 1;
    f1_2 = f1 << 1;

    f1_38 = 38ULL * f1;
    f2_38 = 38ULL * f2;
    f3_38 = 38ULL * f3;

    f3_19 = 19ULL * f3;
    f4_19 = 19ULL * f4;

    r0 = ((uint128_t)f0) * ((uint128_t)f0);
    r0 += ((uint128_t)f1_38) * ((uint128_t)f4);
    r0 += ((uint128_t)f2_38) * ((uint128_t)f3);

    r1 = ((uint128_t)f0_2) * ((uint128_t)f1);
    r1 += ((uint128_t)f2_38) * ((uint128_t)f4);
    r1 += ((uint128_t)f3_19) * ((uint128_t)f3);

    r2 = ((uint128_t)f0_2) * ((uint128_t)f2);
    r2 += ((uint128_t)f1) * ((uint128_t)f1);
    r2 += ((uint128_t)f3_38) * ((uint128_t)f4);

    r3 = ((uint128_t)f0_2) * ((uint128_t)f3);
    r3 += ((uint128_t)f1_2) * ((uint128_t)f2);
    r3 += ((uint128_t)f4_19) * ((uint128_t)f4);

    r4 = ((uint128_t)f0_2) * ((uint128_t)f4);
    r4 += ((uint128_t)f1_2) * ((uint128_t)f3);
    r4 += ((uint128_t)f2) * ((uint128_t)f2);

    r00 = ((uint64_t)r0) & mask;
    carry = r0 >> 51;
    r1 += carry;
    r01 = ((uint64_t)r1) & mask;
    carry = r1 >> 51;
    r2 += carry;
    r02 = ((uint64_t)r2) & mask;
    carry = r2 >> 51;
    r3 += carry;
    r03 = ((uint64_t)r3) & mask;
    carry = r3 >> 51;
    r4 += carry;
    r04 = ((uint64_t)r4) & mask;
    carry = r4 >> 51;
    r00 += 19ULL * (uint64_t)carry;
    carry = r00 >> 51;
    r00 &= mask;
    r01 += (uint64_t)carry;
    carry = r01 >> 51;
    r01 &= mask;
    r02 += (uint64_t)carry;

    h[0] = r00;
    h[1] = r01;
    h[2] = r02;
    h[3] = r03;
    h[4] = r04;
}

static void
fe25519_sq2(fe25519 h, const fe25519 f)
{
    const uint64_t mask = 0x7ffffffffffffULL;
    uint128_t      r0, r1, r2, r3, r4, carry;
    uint64_t       f0, f1, f2, f3, f4;
    uint64_t       f0_2, f1_2, f1_38, f2_38, f3_38, f3_19, f4_19;
    uint64_t       r00, r01, r02, r03, r04;

    f0 = f[0];
    f1 = f[1];
    f2 = f[2];
    f3 = f[3];
    f4 = f[4];

    f0_2 = f0 << 1;
    f1_2 = f1 << 1;

    f1_38 = 38ULL * f1;
    f2_38 = 38ULL * f2;
    f3_38 = 38ULL * f3;

    f3_19 = 19ULL * f3;
    f4_19 = 19ULL * f4;

    r0 = ((uint128_t)f0) * ((uint128_t)f0);
    r0 += ((uint128_t)f1_38) * ((uint128_t)f4);
    r0 += ((uint128_t)f2_38) * ((uint128_t)f3);

    r1 = ((uint128_t)f0_2) * ((uint128_t)f1);
    r1 += ((uint128_t)f2_38) * ((uint128_t)f4);
    r1 += ((uint128_t)f3_19) * ((uint128_t)f3);

    r2 = ((uint128_t)f0_2) * ((uint128_t)f2);
    r2 += ((uint128_t)f1) * ((uint128_t)f1);
    r2 += ((uint128_t)f3_38) * ((uint128_t)f4);

    r3 = ((uint128_t)f0_2) * ((uint128_t)f3);
    r3 += ((uint128_t)f1_2) * ((uint128_t)f2);
    r3 += ((uint128_t)f4_19) * ((uint128_t)f4);

    r4 = ((uint128_t)f0_2) * ((uint128_t)f4);
    r4 += ((uint128_t)f1_2) * ((uint128_t)f3);
    r4 += ((uint128_t)f2) * ((uint128_t)f2);

    r0 <<= 1;
    r1 <<= 1;
    r2 <<= 1;
    r3 <<= 1;
    r4 <<= 1;

    r00 = ((uint64_t)r0) & mask;
    carry = r0 >> 51;
    r1 += carry;
    r01 = ((uint64_t)r1) & mask;
    carry = r1 >> 51;
    r2 += carry;
    r02 = ((uint64_t)r2) & mask;
    carry = r2 >> 51;
    r3 += carry;
    r03 = ((uint64_t)r3) & mask;
    carry = r3 >> 51;
    r4 += carry;
    r04 = ((uint64_t)r4) & mask;
    carry = r4 >> 51;
    r00 += 19ULL * (uint64_t)carry;
    carry = r00 >> 51;
    r00 &= mask;
    r01 += (uint64_t)carry;
    carry = r01 >> 51;
    r01 &= mask;
    r02 += (uint64_t)carry;

    h[0] = r00;
    h[1] = r01;
    h[2] = r02;
    h[3] = r03;
    h[4] = r04;
}

static void
fe25519_frombytes(fe25519 h, const unsigned char* s)
{
    const uint64_t mask = 0x7ffffffffffffULL;
    uint64_t       h0, h1, h2, h3, h4;

    h0 = (LOAD64_LE(s)) & mask;
    h1 = (LOAD64_LE(s + 6) >> 3) & mask;
    h2 = (LOAD64_LE(s + 12) >> 6) & mask;
    h3 = (LOAD64_LE(s + 19) >> 1) & mask;
    h4 = (LOAD64_LE(s + 24) >> 12) & mask;

    h[0] = h0;
    h[1] = h1;
    h[2] = h2;
    h[3] = h3;
    h[4] = h4;
}

static const fe25519 d = { 929955233495203, 466365720129213, 1662059464998953, 2033849074728123,
                           1442794654840575 };

static const fe25519 d2 = { 1859910466990425, 932731440258426, 1072319116312658, 1815898335770999,
                            633789495995903 };

static const fe25519 sqrtm1 = { 1718705420411056, 234908883556509, 2233514472574048,
                                2117202627021982, 765476049583133 };

static void
fe25519_invert(fe25519 out, const fe25519 z)
{
    fe25519 t0;
    fe25519 t1;
    fe25519 t2;
    fe25519 t3;
    int     i;

    fe25519_sq(t0, z);
    fe25519_sq(t1, t0);
    fe25519_sq(t1, t1);
    fe25519_mul(t1, z, t1);
    fe25519_mul(t0, t0, t1);
    fe25519_sq(t2, t0);
    fe25519_mul(t1, t1, t2);
    fe25519_sq(t2, t1);
    for (i = 1; i < 5; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    fe25519_sq(t2, t1);
    for (i = 1; i < 10; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t2, t2, t1);
    fe25519_sq(t3, t2);
    for (i = 1; i < 20; ++i) {
        fe25519_sq(t3, t3);
    }
    fe25519_mul(t2, t3, t2);
    fe25519_sq(t2, t2);
    for (i = 1; i < 10; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    fe25519_sq(t2, t1);
    for (i = 1; i < 50; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t2, t2, t1);
    fe25519_sq(t3, t2);
    for (i = 1; i < 100; ++i) {
        fe25519_sq(t3, t3);
    }
    fe25519_mul(t2, t3, t2);
    fe25519_sq(t2, t2);
    for (i = 1; i < 50; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    fe25519_sq(t1, t1);
    for (i = 1; i < 5; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(out, t1, t0);
}

static void
fe25519_pow22523(fe25519 out, const fe25519 z)
{
    fe25519 t0;
    fe25519 t1;
    fe25519 t2;
    int     i;

    fe25519_sq(t0, z);
    fe25519_sq(t1, t0);
    fe25519_sq(t1, t1);
    fe25519_mul(t1, z, t1);
    fe25519_mul(t0, t0, t1);
    fe25519_sq(t0, t0);
    fe25519_mul(t0, t1, t0);
    fe25519_sq(t1, t0);
    for (i = 1; i < 5; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t0, t1, t0);
    fe25519_sq(t1, t0);
    for (i = 1; i < 10; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t1, t1, t0);
    fe25519_sq(t2, t1);
    for (i = 1; i < 20; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    fe25519_sq(t1, t1);
    for (i = 1; i < 10; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t0, t1, t0);
    fe25519_sq(t1, t0);
    for (i = 1; i < 50; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t1, t1, t0);
    fe25519_sq(t2, t1);
    for (i = 1; i < 100; ++i) {
        fe25519_sq(t2, t2);
    }
    fe25519_mul(t1, t2, t1);
    fe25519_sq(t1, t1);
    for (i = 1; i < 50; ++i) {
        fe25519_sq(t1, t1);
    }
    fe25519_mul(t0, t1, t0);
    fe25519_sq(t0, t0);
    fe25519_sq(t0, t0);
    fe25519_mul(out, t0, z);
}

typedef struct {
    fe25519 X;
    fe25519 Y;
    fe25519 Z;
} ge25519_p2;

typedef struct {
    fe25519 X;
    fe25519 Y;
    fe25519 Z;
    fe25519 T;
} ge25519_p3;

typedef struct {
    fe25519 X;
    fe25519 Y;
    fe25519 Z;
    fe25519 T;
} ge25519_p1p1;

typedef struct {
    fe25519 yplusx;
    fe25519 yminusx;
    fe25519 xy2d;
} ge25519_precomp;

typedef struct {
    fe25519 YplusX;
    fe25519 YminusX;
    fe25519 Z;
    fe25519 T2d;
} ge25519_cached;

static void
ge25519_add(ge25519_p1p1* r, const ge25519_p3* p, const ge25519_cached* q)
{
    fe25519 t0;

    fe25519_add(r->X, p->Y, p->X);
    fe25519_sub(r->Y, p->Y, p->X);
    fe25519_mul(r->Z, r->X, q->YplusX);
    fe25519_mul(r->Y, r->Y, q->YminusX);
    fe25519_mul(r->T, q->T2d, p->T);
    fe25519_mul(r->X, p->Z, q->Z);
    fe25519_add(t0, r->X, r->X);
    fe25519_sub(r->X, r->Z, r->Y);
    fe25519_add(r->Y, r->Z, r->Y);
    fe25519_add(r->Z, t0, r->T);
    fe25519_sub(r->T, t0, r->T);
}

static int
ge25519_frombytes(ge25519_p3* h, const unsigned char* s)
{
    fe25519 u;
    fe25519 v;
    fe25519 v3;
    fe25519 vxx;
    fe25519 m_root_check, p_root_check;
    fe25519 negx;
    fe25519 x_sqrtm1;
    int     has_m_root, has_p_root;

    fe25519_frombytes(h->Y, s);
    fe25519_1(h->Z);
    fe25519_sq(u, h->Y);
    fe25519_mul(v, u, d);
    fe25519_sub(u, u, h->Z); /* u = y^2-1 */
    fe25519_add(v, v, h->Z); /* v = dy^2+1 */

    fe25519_sq(v3, v);
    fe25519_mul(v3, v3, v); /* v3 = v^3 */
    fe25519_sq(h->X, v3);
    fe25519_mul(h->X, h->X, v);
    fe25519_mul(h->X, h->X, u); /* x = uv^7 */

    fe25519_pow22523(h->X, h->X); /* x = (uv^7)^((q-5)/8) */
    fe25519_mul(h->X, h->X, v3);
    fe25519_mul(h->X, h->X, u); /* x = uv^3(uv^7)^((q-5)/8) */

    fe25519_sq(vxx, h->X);
    fe25519_mul(vxx, vxx, v);
    fe25519_sub(m_root_check, vxx, u); /* vx^2-u */
    fe25519_add(p_root_check, vxx, u); /* vx^2+u */
    has_m_root = fe25519_iszero(m_root_check);
    has_p_root = fe25519_iszero(p_root_check);
    fe25519_mul(x_sqrtm1, h->X, sqrtm1); /* x*sqrt(-1) */
    fe25519_cmov(h->X, x_sqrtm1, 1 - has_m_root);

    fe25519_neg(negx, h->X);
    fe25519_cmov(h->X, negx, fe25519_isnegative(h->X) ^ (s[31] >> 7));
    fe25519_mul(h->T, h->X, h->Y);

    return (has_m_root | has_p_root) - 1;
}

static void
ge25519_p1p1_to_p2(ge25519_p2* r, const ge25519_p1p1* p)
{
    fe25519_mul(r->X, p->X, p->T);
    fe25519_mul(r->Y, p->Y, p->Z);
    fe25519_mul(r->Z, p->Z, p->T);
}

static void
ge25519_p1p1_to_p3(ge25519_p3* r, const ge25519_p1p1* p)
{
    fe25519_mul(r->X, p->X, p->T);
    fe25519_mul(r->Y, p->Y, p->Z);
    fe25519_mul(r->Z, p->Z, p->T);
    fe25519_mul(r->T, p->X, p->Y);
}

static void
ge25519_p2_dbl(ge25519_p1p1* r, const ge25519_p2* p)
{
    fe25519 t0;

    fe25519_sq(r->X, p->X);
    fe25519_sq(r->Z, p->Y);
    fe25519_sq2(r->T, p->Z);
    fe25519_add(r->Y, p->X, p->Y);
    fe25519_sq(t0, r->Y);
    fe25519_add(r->Y, r->Z, r->X);
    fe25519_sub(r->Z, r->Z, r->X);
    fe25519_sub(r->X, t0, r->Y);
    fe25519_sub(r->T, r->T, r->Z);
}

static void
ge25519_p3_0(ge25519_p3* h)
{
    fe25519_0(h->X);
    fe25519_1(h->Y);
    fe25519_1(h->Z);
    fe25519_0(h->T);
}

static void
ge25519_cached_0(ge25519_cached* h)
{
    fe25519_1(h->YplusX);
    fe25519_1(h->YminusX);
    fe25519_1(h->Z);
    fe25519_0(h->T2d);
}

static void
ge25519_p3_to_cached(ge25519_cached* r, const ge25519_p3* p)
{
    fe25519_add(r->YplusX, p->Y, p->X);
    fe25519_sub(r->YminusX, p->Y, p->X);
    fe25519_copy(r->Z, p->Z);
    fe25519_mul(r->T2d, p->T, d2);
}

static void
ge25519_p3_to_p2(ge25519_p2* r, const ge25519_p3* p)
{
    fe25519_copy(r->X, p->X);
    fe25519_copy(r->Y, p->Y);
    fe25519_copy(r->Z, p->Z);
}

void
ge25519_p3_tobytes(unsigned char* s, const ge25519_p3* h)
{
    fe25519 recip;
    fe25519 x;
    fe25519 y;

    fe25519_invert(recip, h->Z);
    fe25519_mul(x, h->X, recip);
    fe25519_mul(y, h->Y, recip);
    fe25519_tobytes(s, y);
    s[31] ^= fe25519_isnegative(x) << 7;
}

static void
ge25519_p3_dbl(ge25519_p1p1* r, const ge25519_p3* p)
{
    ge25519_p2 q;
    ge25519_p3_to_p2(&q, p);
    ge25519_p2_dbl(r, &q);
}

static unsigned char
equal(signed char b, signed char c)
{
    unsigned char ub = b;
    unsigned char uc = c;
    unsigned char x = ub ^ uc; /* 0: yes; 1..255: no */
    uint32_t      y = x;       /* 0: yes; 1..255: no */

    y -= 1;   /* 4294967295: yes; 0..254: no */
    y >>= 31; /* 1: yes; 0: no */

    return y;
}

static unsigned char
negative(signed char b)
{
    uint64_t x = b;

    x >>= 63; /* 1: yes; 0: no */

    return x;
}

static void
ge25519_cmov_cached(ge25519_cached* t, const ge25519_cached* u, unsigned char b)
{
    fe25519_cmov(t->YplusX, u->YplusX, b);
    fe25519_cmov(t->YminusX, u->YminusX, b);
    fe25519_cmov(t->Z, u->Z, b);
    fe25519_cmov(t->T2d, u->T2d, b);
}

static void
ge25519_select_cached(ge25519_cached* t, const ge25519_cached cached[8], const signed char b)
{
    ge25519_cached      minust;
    const unsigned char bnegative = negative(b);
    const unsigned char babs = b - (((-bnegative) & b) * ((signed char)1 << 1));

    ge25519_cached_0(t);
    ge25519_cmov_cached(t, &cached[0], equal(babs, 1));
    ge25519_cmov_cached(t, &cached[1], equal(babs, 2));
    ge25519_cmov_cached(t, &cached[2], equal(babs, 3));
    ge25519_cmov_cached(t, &cached[3], equal(babs, 4));
    ge25519_cmov_cached(t, &cached[4], equal(babs, 5));
    ge25519_cmov_cached(t, &cached[5], equal(babs, 6));
    ge25519_cmov_cached(t, &cached[6], equal(babs, 7));
    ge25519_cmov_cached(t, &cached[7], equal(babs, 8));
    fe25519_copy(minust.YplusX, t->YminusX);
    fe25519_copy(minust.YminusX, t->YplusX);
    fe25519_copy(minust.Z, t->Z);
    fe25519_neg(minust.T2d, t->T2d);
    ge25519_cmov_cached(t, &minust, bnegative);
}

static void
ge25519_scalarmult(ge25519_p3* h, const unsigned char* a, const ge25519_p3* p)
{
    signed char    e[64];
    signed char    carry;
    ge25519_p1p1   r;
    ge25519_p2     s;
    ge25519_p1p1   t2, t3, t4, t5, t6, t7, t8;
    ge25519_p3     p2, p3, p4, p5, p6, p7, p8;
    ge25519_cached pi[8];
    ge25519_cached t;
    int            i;

    ge25519_p3_to_cached(&pi[1 - 1], p); /* p */

    ge25519_p3_dbl(&t2, p);
    ge25519_p1p1_to_p3(&p2, &t2);
    ge25519_p3_to_cached(&pi[2 - 1], &p2); /* 2p = 2*p */

    ge25519_add(&t3, p, &pi[2 - 1]);
    ge25519_p1p1_to_p3(&p3, &t3);
    ge25519_p3_to_cached(&pi[3 - 1], &p3); /* 3p = 2p+p */

    ge25519_p3_dbl(&t4, &p2);
    ge25519_p1p1_to_p3(&p4, &t4);
    ge25519_p3_to_cached(&pi[4 - 1], &p4); /* 4p = 2*2p */

    ge25519_add(&t5, p, &pi[4 - 1]);
    ge25519_p1p1_to_p3(&p5, &t5);
    ge25519_p3_to_cached(&pi[5 - 1], &p5); /* 5p = 4p+p */

    ge25519_p3_dbl(&t6, &p3);
    ge25519_p1p1_to_p3(&p6, &t6);
    ge25519_p3_to_cached(&pi[6 - 1], &p6); /* 6p = 2*3p */

    ge25519_add(&t7, p, &pi[6 - 1]);
    ge25519_p1p1_to_p3(&p7, &t7);
    ge25519_p3_to_cached(&pi[7 - 1], &p7); /* 7p = 6p+p */

    ge25519_p3_dbl(&t8, &p4);
    ge25519_p1p1_to_p3(&p8, &t8);
    ge25519_p3_to_cached(&pi[8 - 1], &p8); /* 8p = 2*4p */

    for (i = 0; i < 32; ++i) {
        e[2 * i + 0] = (a[i] >> 0) & 15;
        e[2 * i + 1] = (a[i] >> 4) & 15;
    }

    carry = 0;
    for (i = 0; i < 63; ++i) {
        e[i] += carry;
        carry = e[i] + 8;
        carry >>= 4;
        e[i] -= carry * ((signed char)1 << 4);
    }
    e[63] += carry;

    ge25519_p3_0(h);

    for (i = 63; i != 0; i--) {
        ge25519_select_cached(&t, pi, e[i]);
        ge25519_add(&r, h, &t);

        ge25519_p1p1_to_p2(&s, &r);
        ge25519_p2_dbl(&r, &s);
        ge25519_p1p1_to_p2(&s, &r);
        ge25519_p2_dbl(&r, &s);
        ge25519_p1p1_to_p2(&s, &r);
        ge25519_p2_dbl(&r, &s);
        ge25519_p1p1_to_p2(&s, &r);
        ge25519_p2_dbl(&r, &s);

        ge25519_p1p1_to_p3(h, &r); /* *16 */
    }
    ge25519_select_cached(&t, pi, e[i]);
    ge25519_add(&r, h, &t);

    ge25519_p1p1_to_p3(h, &r);
}

int main()
{
    unsigned char p_s[32] = { 9, 0 };
    unsigned char a[32] = { 0x42 };
    BLACK_BOX(a);

    bench_start();
    int i;
    for (i = 0; i < ITERATIONS; i++) {
        BLACK_BOX(p_s);
        ge25519_p3 p;
        ge25519_frombytes(&p, p_s);

        ge25519_p3 h;
        ge25519_scalarmult(&h, a, &p);

        ge25519_p3_tobytes(a, &h);
        a[31] &= 0x7f;
    }
    bench_end();

    BLACK_BOX(a);
}
