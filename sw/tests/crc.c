// CRC-32 with a table vs bit-by-bit; strings and byte loads.
#include "rt.h"
static uint32_t table[256];
static const char msg[] = "The quick brown fox jumps over the lazy dog";

static uint32_t crc_bits(const uint8_t *p, int n) {
    uint32_t c = 0xffffffffu;
    for (int i = 0; i < n; i++) {
        c ^= p[i];
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320u & -(c & 1));
    }
    return ~c;
}

int main(void) {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (c >> 1) ^ 0xedb88320u : c >> 1;
        table[i] = c;
    }
    int n = sizeof(msg) - 1;
    uint32_t c = 0xffffffffu;
    for (int i = 0; i < n; i++) c = table[(c ^ (uint8_t)msg[i]) & 0xff] ^ (c >> 8);
    c = ~c;
    CHECK(c == crc_bits((const uint8_t *)msg, n));
    CHECK(c == 0x414fa339u);                 // published CRC-32 of this string
    rt_puts("crc ok\n");
    return 0;
}
