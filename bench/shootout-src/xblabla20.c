
#include <sightglass.h>

#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define ITERATIONS 1000
#define BUF_SIZE 1000

#define ROTL64(x, b) (uint64_t)(((x) << (b)) | ((x) >> (64 - (b))))

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

#define BLABLA20_ROUNDS 12

#define blabla20_KEYBYTES 32
#define blabla20_NONCEBYTES 12

#define xblabla20_KEYBYTES 32
#define xblabla20_NONCEBYTES 24

#define blabla20_block_BYTES 64
#define blabla20_block_KEYBYTES 32
#define blabla20_block_NONCEBYTES 16

#define hblabla20_BYTES 32
#define hblabla20_KEYBYTES 32
#define hblabla20_NONCEBYTES 16

#define BLABLA20_QUARTERROUND(a, b, c, d) \
    a += b;                               \
    d = ROTL64(d ^ a, 32);                \
    c += d;                               \
    b = ROTL64(b ^ c, 40);                \
    a += b;                               \
    d = ROTL64(d ^ a, 48);                \
    c += d;                               \
    b = ROTL64(b ^ c, 1)

static void
blabla20_rounds(uint64_t st[16])
{
    int i;

    for (i = 0; i < BLABLA20_ROUNDS; i += 2)
    {
        BLABLA20_QUARTERROUND(st[0], st[4], st[8], st[12]);
        BLABLA20_QUARTERROUND(st[1], st[5], st[9], st[13]);
        BLABLA20_QUARTERROUND(st[2], st[6], st[10], st[14]);
        BLABLA20_QUARTERROUND(st[3], st[7], st[11], st[15]);
        BLABLA20_QUARTERROUND(st[0], st[5], st[10], st[15]);
        BLABLA20_QUARTERROUND(st[1], st[6], st[11], st[12]);
        BLABLA20_QUARTERROUND(st[2], st[7], st[8], st[13]);
        BLABLA20_QUARTERROUND(st[3], st[4], st[9], st[14]);
    }
}

static void
blabla20_update(uint64_t ks[16], uint64_t st[16])
{
    int i;

    memcpy(ks, st, 8 * 16);
    blabla20_rounds(st);
    for (i = 0; i < 16; i++)
    {
        ks[i] += st[i];
    }
    if (++st[12] == 0)
    {
        ++st[13];
    }
}

static void
blabla20_init(uint64_t st[16], const uint8_t nonce[blabla20_NONCEBYTES],
              const uint8_t key[blabla20_KEYBYTES])
{
    int i;

    st[0] = 0x6170786593810fab;
    st[1] = 0x3320646ec7398aee;
    st[2] = 0x79622d3217318274;
    st[3] = 0x6b206574babadada;
    for (i = 0; i < 4; i++)
    {
        st[4 + i] = LOAD64_LE(&key[8 * i]);
    }
    st[8] = 0x2ae36e593e46ad5f;
    st[9] = 0xb68f143029225fc9;
    st[10] = 0x8da1e08468303aa6;
    st[11] = 0xa48a209acd50a4a7;
    st[12] = 0x7fdc12f23f90778c;
    st[13] = 1;
    st[14] = LOAD64_LE(&nonce[8 * 0]);
    st[15] = LOAD64_LE(&nonce[8 * 1]);
}

static int
blabla20_xor(uint8_t *c, const uint8_t *m, size_t len, const uint8_t nonce[blabla20_NONCEBYTES],
             const uint8_t key[blabla20_KEYBYTES])
{
    uint8_t tmp[128];
    uint64_t ks[16];
    uint64_t st[16];
    uint64_t x;
    int i;

    blabla20_init(st, nonce, key);
    while (len >= 128)
    {
        blabla20_update(ks, st);
        for (i = 0; i < 16; i++)
        {
            x = ks[i] ^ LOAD64_LE(m + 8 * i);
            STORE64_LE(c + 8 * i, x);
        }
        c += 128;
        m += 128;
        len -= 128;
    }
    if (len > 0)
    {
        blabla20_update(ks, st);
        memset(tmp, 0, 128);
        for (i = 0; i < (int)len; i++)
        {
            tmp[i] = m[i];
        }
        for (i = 0; i < 16; i++)
        {
            x = ks[i] ^ LOAD64_LE(tmp + 8 * i);
            STORE64_LE(tmp + 8 * i, x);
        }
        for (i = 0; i < (int)len; i++)
        {
            c[i] = tmp[i];
        }
    }
    return 0;
}

static void
hblabla20(uint8_t subkey[hblabla20_BYTES], const uint8_t nonce[hblabla20_NONCEBYTES],
          const uint8_t key[hblabla20_KEYBYTES])
{
    uint64_t st[16];
    int i;

    blabla20_init(st, &nonce[8], key);
    st[13] = LOAD64_LE(&nonce[0]);
    blabla20_rounds(st);
    for (i = 0; i < 2; i++)
    {
        STORE64_LE(subkey + 8 * i, st[i]);
    }
    for (; i < 4; i++)
    {
        STORE64_LE(subkey + 8 * i, st[i + 12 - 4]);
    }
}

static int
xblabla20_xor(uint8_t *c, const uint8_t *m, size_t len, const uint8_t nonce[xblabla20_NONCEBYTES],
              const uint8_t key[xblabla20_KEYBYTES])
{
    uint8_t subkey[blabla20_KEYBYTES];
    uint8_t subnonce[blabla20_NONCEBYTES];

    hblabla20(subkey, nonce, key);

    return blabla20_xor(c, m, len, subnonce, subkey);
}

int main()
{
    uint8_t *buf = calloc(BUF_SIZE, (size_t)1U);
    assert(buf != NULL);
    BLACK_BOX(buf);
    assert(BUF_SIZE >= xblabla20_KEYBYTES && BUF_SIZE >= xblabla20_NONCEBYTES);

    bench_start();
    int i;
    for (i = 0; i < ITERATIONS; i++)
    {
        xblabla20_xor(buf, buf, BUF_SIZE, buf, buf);
    }
    bench_end();

    BLACK_BOX(buf);
    free(buf);
}
