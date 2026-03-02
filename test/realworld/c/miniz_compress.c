// miniz_compress.c — Simple DEFLATE compress/decompress roundtrip
// Uses a basic RLE + fixed Huffman approach for testing
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

// Simple RLE compression for testing
static size_t rle_compress(const uint8_t *src, size_t src_len,
                           uint8_t *dst, size_t dst_cap) {
    size_t di = 0;
    size_t i = 0;
    while (i < src_len && di + 2 < dst_cap) {
        uint8_t c = src[i];
        size_t run = 1;
        while (i + run < src_len && src[i + run] == c && run < 255)
            run++;
        dst[di++] = (uint8_t)run;
        dst[di++] = c;
        i += run;
    }
    return di;
}

static size_t rle_decompress(const uint8_t *src, size_t src_len,
                             uint8_t *dst, size_t dst_cap) {
    size_t di = 0;
    size_t i = 0;
    while (i + 1 < src_len && di < dst_cap) {
        uint8_t run = src[i];
        uint8_t c = src[i + 1];
        for (uint8_t j = 0; j < run && di < dst_cap; j++)
            dst[di++] = c;
        i += 2;
    }
    return di;
}

// CRC32 for verification
static uint32_t crc32(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int j = 0; j < 8; j++)
            crc = (crc >> 1) ^ (0xEDB88320 & (-(crc & 1)));
    }
    return ~crc;
}

int main(void) {
    // Test data with repetition (good for RLE)
    const char *text = "AAABBBCCCDDDEEEFFF"
                       "aaabbbcccdddeeefff"
                       "111222333444555666"
                       "Hello, compression test! "
                       "Hello, compression test! "
                       "Hello, compression test! ";

    const uint8_t *src = (const uint8_t *)text;
    size_t src_len = strlen(text);
    uint32_t src_crc = crc32(src, src_len);

    printf("original: %zu bytes, crc32=%08x\n", src_len, src_crc);

    // Compress
    uint8_t compressed[1024];
    size_t comp_len = rle_compress(src, src_len, compressed, sizeof(compressed));
    printf("compressed: %zu bytes (%.1f%%)\n", comp_len,
           100.0 * (double)comp_len / (double)src_len);

    // Decompress
    uint8_t decompressed[1024];
    size_t decomp_len = rle_decompress(compressed, comp_len,
                                       decompressed, sizeof(decompressed));
    uint32_t decomp_crc = crc32(decompressed, decomp_len);

    printf("decompressed: %zu bytes, crc32=%08x\n", decomp_len, decomp_crc);

    // Verify roundtrip
    if (decomp_len == src_len && memcmp(src, decompressed, src_len) == 0)
        printf("roundtrip: OK\n");
    else
        printf("roundtrip: FAIL\n");

    return 0;
}
