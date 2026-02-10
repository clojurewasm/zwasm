
#include <sightglass.h>

#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define ITERATIONS 1000
#define BUF_SIZE 1000

#define ROTL32(x, b) (uint32_t)(((x) << (b)) | ((x) >> (32 - (b))))

#define LOAD32_LE(SRC) load32_le(SRC)
static inline uint32_t
load32_le(const uint8_t src[4])
{
    uint32_t w = (uint32_t)src[0];
    w |= (uint32_t)src[1] << 8;
    w |= (uint32_t)src[2] << 16;
    w |= (uint32_t)src[3] << 24;
    return w;
}

#define STORE32_LE(DST, W) store32_le((DST), (W))
static inline void
store32_le(uint8_t dst[4], uint32_t w)
{
    dst[0] = (uint8_t)w;
    w >>= 8;
    dst[1] = (uint8_t)w;
    w >>= 8;
    dst[2] = (uint8_t)w;
    w >>= 8;
    dst[3] = (uint8_t)w;
}

#define CHACHA20_ROUNDS 12

#define chacha20_KEYBYTES 32
#define chacha20_NONCEBYTES 12

#define xchacha20_KEYBYTES 32
#define xchacha20_NONCEBYTES 24

#define chacha20_block_BYTES 64
#define chacha20_block_KEYBYTES 32
#define chacha20_block_NONCEBYTES 16

#define hchacha20_BYTES 32
#define hchacha20_KEYBYTES 32
#define hchacha20_NONCEBYTES 16

#define CHACHA20_QUARTERROUND(a, b, c, d) \
    a += b;                               \
    d = ROTL32(d ^ a, 16);                \
    c += d;                               \
    b = ROTL32(b ^ c, 12);                \
    a += b;                               \
    d = ROTL32(d ^ a, 8);                 \
    c += d;                               \
    b = ROTL32(b ^ c, 7)

static void
chacha20_rounds(uint32_t st[16])
{
    int i;

    for (i = 0; i < CHACHA20_ROUNDS; i += 2)
    {
        CHACHA20_QUARTERROUND(st[0], st[4], st[8], st[12]);
        CHACHA20_QUARTERROUND(st[1], st[5], st[9], st[13]);
        CHACHA20_QUARTERROUND(st[2], st[6], st[10], st[14]);
        CHACHA20_QUARTERROUND(st[3], st[7], st[11], st[15]);
        CHACHA20_QUARTERROUND(st[0], st[5], st[10], st[15]);
        CHACHA20_QUARTERROUND(st[1], st[6], st[11], st[12]);
        CHACHA20_QUARTERROUND(st[2], st[7], st[8], st[13]);
        CHACHA20_QUARTERROUND(st[3], st[4], st[9], st[14]);
    }
}

static void
chacha20_update(uint32_t ks[16], uint32_t st[16])
{
    int i;

    memcpy(ks, st, 4 * 16);
    chacha20_rounds(st);
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
chacha20_init(uint32_t st[16], const uint8_t nonce[chacha20_NONCEBYTES],
              const uint8_t key[chacha20_KEYBYTES])
{
    int i;

    st[0] = 0x61707865UL;
    st[1] = 0x3120646eUL;
    st[2] = 0x79622d36UL;
    st[3] = 0x6b206574UL;
    for (i = 0; i < 8; i++)
    {
        st[4 + i] = LOAD32_LE(&key[4 * i]);
    }
    st[12] = 0;
    st[13] = LOAD32_LE(&nonce[4 * 0]);
    st[14] = LOAD32_LE(&nonce[4 * 1]);
    st[15] = LOAD32_LE(&nonce[4 * 2]);
}

static int
chacha20_xor(uint8_t *c, const uint8_t *m, size_t len, const uint8_t nonce[chacha20_NONCEBYTES],
             const uint8_t key[chacha20_KEYBYTES])
{
    uint8_t tmp[64];
    uint32_t ks[16];
    uint32_t st[16];
    uint32_t x;
    int i;

    chacha20_init(st, nonce, key);
    while (len >= 64)
    {
        chacha20_update(ks, st);
        for (i = 0; i < 16; i++)
        {
            x = ks[i] ^ LOAD32_LE(m + 4 * i);
            STORE32_LE(c + 4 * i, x);
        }
        c += 64;
        m += 64;
        len -= 64;
    }
    if (len > 0)
    {
        chacha20_update(ks, st);
        memset(tmp, 0, 64);
        for (i = 0; i < (int)len; i++)
        {
            tmp[i] = m[i];
        }
        for (i = 0; i < 16; i++)
        {
            x = ks[i] ^ LOAD32_LE(tmp + 4 * i);
            STORE32_LE(tmp + 4 * i, x);
        }
        for (i = 0; i < (int)len; i++)
        {
            c[i] = tmp[i];
        }
    }
    return 0;
}

static void
hchacha20(uint8_t subkey[hchacha20_BYTES], const uint8_t nonce[hchacha20_NONCEBYTES],
          const uint8_t key[hchacha20_KEYBYTES])
{
    uint32_t st[16];
    int i;

    chacha20_init(st, &nonce[4], key);
    st[12] = LOAD32_LE(&nonce[0]);
    chacha20_rounds(st);
    for (i = 0; i < 4; i++)
    {
        STORE32_LE(subkey + 4 * i, st[i]);
    }
    for (; i < 8; i++)
    {
        STORE32_LE(subkey + 4 * i, st[i + 12 - 4]);
    }
}

static int
xchacha20_xor(uint8_t *c, const uint8_t *m, size_t len, const uint8_t nonce[xchacha20_NONCEBYTES],
              const uint8_t key[xchacha20_KEYBYTES])
{
    uint8_t subkey[chacha20_KEYBYTES];
    uint8_t subnonce[chacha20_NONCEBYTES];

    hchacha20(subkey, nonce, key);
    memset(subnonce, 0, 4);
    memcpy(subnonce + 4, nonce + hchacha20_NONCEBYTES, 8);

    return chacha20_xor(c, m, len, subnonce, subkey);
}

int main()
{
    uint8_t *buf = calloc(BUF_SIZE, (size_t)1U);
    assert(buf != NULL);
    BLACK_BOX(buf);
    assert(BUF_SIZE >= xchacha20_KEYBYTES && BUF_SIZE >= xchacha20_NONCEBYTES);

    bench_start();
    int i;
    for (i = 0; i < ITERATIONS; i++)
    {
        xchacha20_xor(buf, buf, BUF_SIZE, buf, buf);
    }
    bench_end();

    BLACK_BOX(buf);
    free(buf);
}
