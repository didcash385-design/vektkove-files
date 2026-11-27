/* Vektkove codecs: text encodings and compression formats, shared by the macOS engine and the portable runner.
 * Header-only C11 with no dependencies. Every function reports failure through the output buffer.
 */
#ifndef VKCODEC_H
#define VKCODEC_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif
#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#endif

#define VKC_MAX_OUTPUT (16u * 1024u * 1024u)

typedef struct { uint8_t *p; size_t n, cap; int fail; const char *err; } vkc_buf;

static int vkc_reserve(vkc_buf *b, size_t add) {
    if (b->fail) return 0;
    if (add > VKC_MAX_OUTPUT || b->n + add > VKC_MAX_OUTPUT) { b->fail = 1; b->err = "output exceeds the 16 MiB limit"; return 0; }
    if (b->n + add > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->n + add) cap *= 2;
        uint8_t *grown = (uint8_t *)realloc(b->p, cap);
        if (!grown) { b->fail = 1; b->err = "out of memory"; return 0; }
        b->p = grown; b->cap = cap;
    }
    return 1;
}
static void vkc_put(vkc_buf *b, uint8_t c) { if (vkc_reserve(b, 1)) b->p[b->n++] = c; }
static void vkc_write(vkc_buf *b, const void *d, size_t n) { if (n && vkc_reserve(b, n)) { memcpy(b->p + b->n, d, n); b->n += n; } }
static int vkc_fail(vkc_buf *b, const char *e) { if (!b->fail) { b->fail = 1; b->err = e; } return 0; }
static void vkc_free(vkc_buf *b) { free(b->p); memset(b, 0, sizeof(*b)); }

static uint32_t vkc_rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint64_t vkc_rd64(const uint8_t *p) { return (uint64_t)vkc_rd32(p) | ((uint64_t)vkc_rd32(p + 4) << 32); }
static void vkc_put32(vkc_buf *b, uint32_t v) { vkc_put(b, (uint8_t)v); vkc_put(b, (uint8_t)(v >> 8)); vkc_put(b, (uint8_t)(v >> 16)); vkc_put(b, (uint8_t)(v >> 24)); }
static int vkc_highbit(uint32_t v) { int r = 0; while (v >>= 1) r++; return r; }

static int vkc_valid_utf8(const uint8_t *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        uint8_t c = s[i];
        if (c < 0x80) { i++; continue; }
        size_t len = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC2 ? 2 : 0;
        if (!len || c > 0xF4 || i + len > n) return 0;
        for (size_t k = 1; k < len; k++) if ((s[i + k] & 0xC0) != 0x80) return 0;
        if (c == 0xE0 && s[i + 1] < 0xA0) return 0;
        if (c == 0xED && s[i + 1] >= 0xA0) return 0;
        if (c == 0xF0 && s[i + 1] < 0x90) return 0;
        if (c == 0xF4 && s[i + 1] >= 0x90) return 0;
        i += len;
    }
    return 1;
}
static void vkc_put_utf8(vkc_buf *b, uint32_t cp) {
    if (cp < 0x80) vkc_put(b, (uint8_t)cp);
    else if (cp < 0x800) { vkc_put(b, (uint8_t)(0xC0 | (cp >> 6))); vkc_put(b, (uint8_t)(0x80 | (cp & 0x3F))); }
    else if (cp < 0x10000) { vkc_put(b, (uint8_t)(0xE0 | (cp >> 12))); vkc_put(b, (uint8_t)(0x80 | ((cp >> 6) & 0x3F))); vkc_put(b, (uint8_t)(0x80 | (cp & 0x3F))); }
    else { vkc_put(b, (uint8_t)(0xF0 | (cp >> 18))); vkc_put(b, (uint8_t)(0x80 | ((cp >> 12) & 0x3F))); vkc_put(b, (uint8_t)(0x80 | ((cp >> 6) & 0x3F))); vkc_put(b, (uint8_t)(0x80 | (cp & 0x3F))); }
}

/* ---- Checksums ---- */
static uint32_t vkc_crc32(const uint8_t *p, size_t n) {
    static uint32_t table[256]; static int ready = 0;
    if (!ready) { for (uint32_t i = 0; i < 256; i++) { uint32_t c = i; for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1; table[i] = c; } ready = 1; }
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) crc = table[(crc ^ p[i]) & 255] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}
static uint32_t vkc_adler32(const uint8_t *p, size_t n) {
    uint32_t a = 1, b = 0;
    for (size_t i = 0; i < n; i++) { a = (a + p[i]) % 65521u; b = (b + a) % 65521u; }
    return (b << 16) | a;
}
static uint32_t vkc_rotl32(uint32_t x, int r) { return (x << r) | (x >> (32 - r)); }
static uint32_t vkc_xxh32(const uint8_t *p, size_t len) {
    const uint32_t P1 = 2654435761u, P2 = 2246822519u, P3 = 3266489917u, P4 = 668265263u, P5 = 374761393u;
    const uint8_t *end = p + len; uint32_t h;
    if (len >= 16) {
        uint32_t v1 = P1 + P2, v2 = P2, v3 = 0, v4 = 0u - P1;
        do {
            v1 = vkc_rotl32(v1 + vkc_rd32(p) * P2, 13) * P1; p += 4;
            v2 = vkc_rotl32(v2 + vkc_rd32(p) * P2, 13) * P1; p += 4;
            v3 = vkc_rotl32(v3 + vkc_rd32(p) * P2, 13) * P1; p += 4;
            v4 = vkc_rotl32(v4 + vkc_rd32(p) * P2, 13) * P1; p += 4;
        } while (p + 16 <= end);
        h = vkc_rotl32(v1, 1) + vkc_rotl32(v2, 7) + vkc_rotl32(v3, 12) + vkc_rotl32(v4, 18);
    } else h = P5;
    h += (uint32_t)len;
    while (p + 4 <= end) { h = vkc_rotl32(h + vkc_rd32(p) * P3, 17) * P4; p += 4; }
    while (p < end) { h = vkc_rotl32(h + (*p++) * P5, 11) * P1; }
    h ^= h >> 15; h *= P2; h ^= h >> 13; h *= P3; h ^= h >> 16;
    return h;
}
static uint64_t vkc_rotl64(uint64_t x, int r) { return (x << r) | (x >> (64 - r)); }
static uint64_t vkc_xxh64(const uint8_t *p, size_t len) {
    const uint64_t P1 = 11400714785074694791ULL, P2 = 14029467366897019727ULL, P3 = 1609587929392839161ULL, P4 = 9650029242287828579ULL, P5 = 2870177450012600261ULL;
    const uint8_t *end = p + len; uint64_t h;
#define VKC_X64ROUND(acc, in) vkc_rotl64((acc) + (in) * P2, 31) * P1
    if (len >= 32) {
        uint64_t v1 = P1 + P2, v2 = P2, v3 = 0, v4 = 0ULL - P1;
        do {
            v1 = VKC_X64ROUND(v1, vkc_rd64(p)); p += 8; v2 = VKC_X64ROUND(v2, vkc_rd64(p)); p += 8;
            v3 = VKC_X64ROUND(v3, vkc_rd64(p)); p += 8; v4 = VKC_X64ROUND(v4, vkc_rd64(p)); p += 8;
        } while (p + 32 <= end);
        h = vkc_rotl64(v1, 1) + vkc_rotl64(v2, 7) + vkc_rotl64(v3, 12) + vkc_rotl64(v4, 18);
        uint64_t vs[4] = {v1, v2, v3, v4};
        for (int i = 0; i < 4; i++) { h ^= VKC_X64ROUND(0, vs[i]); h = h * P1 + P4; }
    } else h = P5;
    h += len;
    while (p + 8 <= end) { h ^= VKC_X64ROUND(0, vkc_rd64(p)); h = vkc_rotl64(h, 27) * P1 + P4; p += 8; }
    if (p + 4 <= end) { h ^= (uint64_t)vkc_rd32(p) * P1; h = vkc_rotl64(h, 23) * P2 + P3; p += 4; }
    while (p < end) { h ^= (*p++) * P5; h = vkc_rotl64(h, 11) * P1; }
    h ^= h >> 33; h *= P2; h ^= h >> 29; h *= P3; h ^= h >> 32;
#undef VKC_X64ROUND
    return h;
}

/* ---- Text codecs ---- */
static int vkc_is_space(uint8_t c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
static int vkc_hexval(uint8_t c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }

static int vkc_base64_encode_with(const uint8_t *in, size_t n, vkc_buf *o, const char *alphabet, int pad) {
    size_t i = 0;
    for (; i + 3 <= n; i += 3) {
        uint32_t v = ((uint32_t)in[i] << 16) | ((uint32_t)in[i + 1] << 8) | in[i + 2];
        vkc_put(o, (uint8_t)alphabet[v >> 18]); vkc_put(o, (uint8_t)alphabet[(v >> 12) & 63]); vkc_put(o, (uint8_t)alphabet[(v >> 6) & 63]); vkc_put(o, (uint8_t)alphabet[v & 63]);
    }
    if (n - i) {
        uint32_t v = (uint32_t)in[i] << 16; if (n - i == 2) v |= (uint32_t)in[i + 1] << 8;
        vkc_put(o, (uint8_t)alphabet[v >> 18]); vkc_put(o, (uint8_t)alphabet[(v >> 12) & 63]);
        if (n - i == 2) vkc_put(o, (uint8_t)alphabet[(v >> 6) & 63]); else if (pad) vkc_put(o, '=');
        if (pad) vkc_put(o, '=');
    }
    return !o->fail;
}
static int vkc_base64_decode_with(const uint8_t *in, size_t n, vkc_buf *o, const char *alphabet) {
    int8_t map[256]; memset(map, -1, sizeof(map));
    for (int i = 0; i < 64; i++) map[(uint8_t)alphabet[i]] = (int8_t)i;
    uint32_t acc = 0; int bits = 0; size_t chars = 0, pads = 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t c = in[i];
        if (vkc_is_space(c)) continue;
        if (c == '=') { pads++; continue; }
        if (pads) return vkc_fail(o, "base64 data continues after padding");
        if (map[c] < 0) return vkc_fail(o, "invalid base64 character");
        acc = (acc << 6) | (uint32_t)map[c]; bits += 6; chars++;
        if (bits >= 8) { bits -= 8; vkc_put(o, (uint8_t)(acc >> bits)); acc &= (1u << bits) - 1; }
    }
    if (chars % 4 == 1) return vkc_fail(o, "invalid base64 length");
    if (pads && (pads > 2 || (chars + pads) % 4 != 0)) return vkc_fail(o, "invalid base64 padding");
    return !o->fail;
}
static int vkc_base64_enc(const uint8_t *in, size_t n, vkc_buf *o) { return vkc_base64_encode_with(in, n, o, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", 1); }
static int vkc_base64_dec(const uint8_t *in, size_t n, vkc_buf *o) { return vkc_base64_decode_with(in, n, o, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"); }
static int vkc_base64url_enc(const uint8_t *in, size_t n, vkc_buf *o) { return vkc_base64_encode_with(in, n, o, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_", 0); }
static int vkc_base64url_dec(const uint8_t *in, size_t n, vkc_buf *o) { return vkc_base64_decode_with(in, n, o, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"); }

static int vkc_base32_encode_with(const uint8_t *in, size_t n, vkc_buf *o, const char *alphabet) {
    uint32_t acc = 0; int bits = 0; size_t chars = 0;
    for (size_t i = 0; i < n; i++) {
        acc = (acc << 8) | in[i]; bits += 8;
        while (bits >= 5) { bits -= 5; vkc_put(o, (uint8_t)alphabet[(acc >> bits) & 31]); chars++; }
        acc &= (1u << bits) - 1;
    }
    if (bits) { vkc_put(o, (uint8_t)alphabet[(acc << (5 - bits)) & 31]); chars++; }
    while (chars % 8) { vkc_put(o, '='); chars++; }
    return !o->fail;
}
static int vkc_base32_decode_with(const uint8_t *in, size_t n, vkc_buf *o, const char *alphabet) {
    int8_t map[256]; memset(map, -1, sizeof(map));
    for (int i = 0; i < 32; i++) { map[(uint8_t)alphabet[i]] = (int8_t)i; if (alphabet[i] >= 'A' && alphabet[i] <= 'Z') map[(uint8_t)alphabet[i] + 32] = (int8_t)i; }
    uint32_t acc = 0; int bits = 0; size_t chars = 0, pads = 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t c = in[i];
        if (vkc_is_space(c)) continue;
        if (c == '=') { pads++; continue; }
        if (pads) return vkc_fail(o, "base32 data continues after padding");
        if (map[c] < 0) return vkc_fail(o, "invalid base32 character");
        acc = (acc << 5) | (uint32_t)map[c]; bits += 5; chars++;
        if (bits >= 8) { bits -= 8; vkc_put(o, (uint8_t)(acc >> bits)); acc &= (1u << bits) - 1; }
    }
    size_t r = chars % 8;
    if (r == 1 || r == 3 || r == 6) return vkc_fail(o, "invalid base32 length");
    if (pads && (chars + pads) % 8 != 0) return vkc_fail(o, "invalid base32 padding");
    return !o->fail;
}
static int vkc_base32_enc(const uint8_t *in, size_t n, vkc_buf *o) { return vkc_base32_encode_with(in, n, o, "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"); }
static int vkc_base32_dec(const uint8_t *in, size_t n, vkc_buf *o) { return vkc_base32_decode_with(in, n, o, "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"); }
static int vkc_base32hex_enc(const uint8_t *in, size_t n, vkc_buf *o) { return vkc_base32_encode_with(in, n, o, "0123456789ABCDEFGHIJKLMNOPQRSTUV"); }
static int vkc_base32hex_dec(const uint8_t *in, size_t n, vkc_buf *o) { return vkc_base32_decode_with(in, n, o, "0123456789ABCDEFGHIJKLMNOPQRSTUV"); }

static int vkc_hex_enc(const uint8_t *in, size_t n, vkc_buf *o) {
    for (size_t i = 0; i < n; i++) { vkc_put(o, (uint8_t)"0123456789abcdef"[in[i] >> 4]); vkc_put(o, (uint8_t)"0123456789abcdef"[in[i] & 15]); }
    return !o->fail;
}
static int vkc_hex_dec(const uint8_t *in, size_t n, vkc_buf *o) {
    int high = -1;
    for (size_t i = 0; i < n; i++) {
        if (vkc_is_space(in[i])) continue;
        int v = vkc_hexval(in[i]);
        if (v < 0) return vkc_fail(o, "invalid hexadecimal character");
        if (high < 0) high = v; else { vkc_put(o, (uint8_t)(high * 16 + v)); high = -1; }
    }
    if (high >= 0) return vkc_fail(o, "odd number of hexadecimal digits");
    return !o->fail;
}

static const char vkc_b58[] = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
static int vkc_base58_enc(const uint8_t *in, size_t n, vkc_buf *o) {
    if (n > 65536) return vkc_fail(o, "base58 input is limited to 64 KiB");
    size_t zeros = 0; while (zeros < n && !in[zeros]) zeros++;
    size_t cap = n * 138 / 100 + 2, used = 0;
    uint8_t *digits = (uint8_t *)calloc(cap, 1);
    if (!digits) return vkc_fail(o, "out of memory");
    for (size_t i = zeros; i < n; i++) {
        uint32_t carry = in[i]; size_t j = 0;
        for (size_t k = cap; (carry || j < used) && k-- > 0; j++) { carry += 256u * digits[k]; digits[k] = (uint8_t)(carry % 58); carry /= 58; }
        used = j;
    }
    size_t start = cap - used;
    for (size_t i = 0; i < zeros; i++) vkc_put(o, '1');
    for (size_t i = start; i < cap; i++) vkc_put(o, (uint8_t)vkc_b58[digits[i]]);
    free(digits);
    return !o->fail;
}
static int vkc_base58_dec(const uint8_t *in, size_t n, vkc_buf *o) {
    if (n > 65536) return vkc_fail(o, "base58 input is limited to 64 KiB");
    int8_t map[256]; memset(map, -1, sizeof(map));
    for (int i = 0; i < 58; i++) map[(uint8_t)vkc_b58[i]] = (int8_t)i;
    size_t zeros = 0; while (zeros < n && in[zeros] == '1') zeros++;
    size_t cap = n * 733 / 1000 + 2, used = 0;
    uint8_t *bytes = (uint8_t *)calloc(cap, 1);
    if (!bytes) return vkc_fail(o, "out of memory");
    for (size_t i = zeros; i < n; i++) {
        if (vkc_is_space(in[i])) continue;
        int v = map[in[i]];
        if (v < 0) { free(bytes); return vkc_fail(o, "invalid base58 character"); }
        uint32_t carry = (uint32_t)v; size_t j = 0;
        for (size_t k = cap; (carry || j < used) && k-- > 0; j++) { carry += 58u * bytes[k]; bytes[k] = (uint8_t)(carry & 255); carry >>= 8; }
        used = j;
    }
    for (size_t i = 0; i < zeros; i++) vkc_put(o, 0);
    vkc_write(o, bytes + (cap - used), used);
    free(bytes);
    return !o->fail;
}

static int vkc_ascii85_enc(const uint8_t *in, size_t n, vkc_buf *o) {
    for (size_t i = 0; i < n; i += 4) {
        size_t k = n - i < 4 ? n - i : 4;
        uint32_t v = 0; for (size_t j = 0; j < 4; j++) v = (v << 8) | (j < k ? in[i + j] : 0);
        if (k == 4 && v == 0) { vkc_put(o, 'z'); continue; }
        uint8_t group[5]; for (int j = 4; j >= 0; j--) { group[j] = (uint8_t)(v % 85 + '!'); v /= 85; }
        vkc_write(o, group, k + 1);
    }
    return !o->fail;
}
static int vkc_ascii85_dec(const uint8_t *in, size_t n, vkc_buf *o) {
    size_t i = 0;
    while (i < n && vkc_is_space(in[i])) i++;
    if (i + 1 < n && in[i] == '<' && in[i + 1] == '~') i += 2;
    uint32_t group[5]; size_t count = 0;
    for (; i < n; i++) {
        uint8_t c = in[i];
        if (vkc_is_space(c)) continue;
        if (c == '~') break;
        if (c == 'z') { if (count) return vkc_fail(o, "invalid ascii85 'z' inside a group"); for (int k = 0; k < 4; k++) vkc_put(o, 0); continue; }
        if (c < '!' || c > 'u') return vkc_fail(o, "invalid ascii85 character");
        group[count++] = (uint32_t)(c - '!');
        if (count == 5) {
            uint64_t v = 0; for (int k = 0; k < 5; k++) v = v * 85 + group[k];
            if (v > 0xFFFFFFFFull) return vkc_fail(o, "ascii85 group overflows 32 bits");
            for (int k = 3; k >= 0; k--) vkc_put(o, (uint8_t)(v >> (k * 8)));
            count = 0;
        }
    }
    if (count == 1) return vkc_fail(o, "invalid ascii85 length");
    if (count) {
        uint64_t v = 0; for (size_t k = 0; k < 5; k++) v = v * 85 + (k < count ? group[k] : 84);
        if (v > 0xFFFFFFFFull) return vkc_fail(o, "ascii85 group overflows 32 bits");
        for (size_t k = 0; k + 1 < count; k++) vkc_put(o, (uint8_t)(v >> (24 - 8 * k)));
    }
    return !o->fail;
}

static int vkc_percent_encode(const uint8_t *in, size_t n, vkc_buf *o, int form) {
    for (size_t i = 0; i < n; i++) {
        uint8_t c = in[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~') vkc_put(o, c);
        else if (form && c == ' ') vkc_put(o, '+');
        else { vkc_put(o, '%'); vkc_put(o, (uint8_t)"0123456789ABCDEF"[c >> 4]); vkc_put(o, (uint8_t)"0123456789ABCDEF"[c & 15]); }
    }
    return !o->fail;
}
static int vkc_percent_decode(const uint8_t *in, size_t n, vkc_buf *o, int form) {
    for (size_t i = 0; i < n; i++) {
        if (in[i] == '%') {
            if (i + 2 >= n) return vkc_fail(o, "truncated percent escape");
            int a = vkc_hexval(in[i + 1]), b = vkc_hexval(in[i + 2]);
            if (a < 0 || b < 0) return vkc_fail(o, "invalid percent escape");
            vkc_put(o, (uint8_t)(a * 16 + b)); i += 2;
        } else if (form && in[i] == '+') vkc_put(o, ' ');
        else vkc_put(o, in[i]);
    }
    return !o->fail;
}
static int vkc_url_enc(const uint8_t *in, size_t n, vkc_buf *o) { return vkc_percent_encode(in, n, o, 0); }
static int vkc_url_dec(const uint8_t *in, size_t n, vkc_buf *o) { return vkc_percent_decode(in, n, o, 0); }
static int vkc_urlform_enc(const uint8_t *in, size_t n, vkc_buf *o) { return vkc_percent_encode(in, n, o, 1); }
static int vkc_urlform_dec(const uint8_t *in, size_t n, vkc_buf *o) { return vkc_percent_decode(in, n, o, 1); }

static int vkc_html_enc(const uint8_t *in, size_t n, vkc_buf *o) {
    for (size_t i = 0; i < n; i++) {
        switch (in[i]) {
            case '&': vkc_write(o, "&amp;", 5); break; case '<': vkc_write(o, "&lt;", 4); break;
            case '>': vkc_write(o, "&gt;", 4); break; case '"': vkc_write(o, "&quot;", 6); break;
            case '\'': vkc_write(o, "&#39;", 5); break; default: vkc_put(o, in[i]);
        }
    }
    return !o->fail;
}
static int vkc_html_dec(const uint8_t *in, size_t n, vkc_buf *o) {
    for (size_t i = 0; i < n; i++) {
        if (in[i] != '&') { vkc_put(o, in[i]); continue; }
        size_t j = i + 1; while (j < n && j - i <= 10 && in[j] != ';' && in[j] != '&') j++;
        if (j >= n || in[j] != ';') { vkc_put(o, '&'); continue; }
        size_t len = j - i - 1; const uint8_t *name = in + i + 1; int done = 0;
        if (len == 3 && !memcmp(name, "amp", 3)) { vkc_put(o, '&'); done = 1; }
        else if (len == 2 && !memcmp(name, "lt", 2)) { vkc_put(o, '<'); done = 1; }
        else if (len == 2 && !memcmp(name, "gt", 2)) { vkc_put(o, '>'); done = 1; }
        else if (len == 4 && !memcmp(name, "quot", 4)) { vkc_put(o, '"'); done = 1; }
        else if (len == 4 && !memcmp(name, "apos", 4)) { vkc_put(o, '\''); done = 1; }
        else if (len == 4 && !memcmp(name, "nbsp", 4)) { vkc_put_utf8(o, 0xA0); done = 1; }
        else if (len >= 2 && name[0] == '#') {
            uint32_t cp = 0; int ok = 1; size_t k = 1; int hex = (name[1] == 'x' || name[1] == 'X');
            if (hex) k = 2;
            if (k >= len) ok = 0;
            for (; k < len && ok; k++) {
                int d = hex ? vkc_hexval(name[k]) : (name[k] >= '0' && name[k] <= '9' ? name[k] - '0' : -1);
                if (d < 0) ok = 0; else { cp = cp * (hex ? 16 : 10) + (uint32_t)d; if (cp > 0x10FFFF) ok = 0; }
            }
            if (ok && cp && !(cp >= 0xD800 && cp <= 0xDFFF)) { vkc_put_utf8(o, cp); done = 1; }
        }
        if (done) i = j; else vkc_put(o, '&');
    }
    return !o->fail;
}

static int vkc_qp_enc(const uint8_t *in, size_t n, vkc_buf *o) {
    size_t line = 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t c = in[i];
        if (c == '\r' && i + 1 < n && in[i + 1] == '\n') { vkc_put(o, '\r'); vkc_put(o, '\n'); i++; line = 0; continue; }
        if (c == '\n') { vkc_put(o, '\n'); line = 0; continue; }
        int at_end = (i + 1 == n) || in[i + 1] == '\n' || in[i + 1] == '\r';
        int literal = (c >= 33 && c <= 126 && c != '=') || ((c == ' ' || c == '\t') && !at_end);
        size_t need = literal ? 1 : 3;
        if (line + need > 75) { vkc_put(o, '='); vkc_put(o, '\r'); vkc_put(o, '\n'); line = 0; }
        if (literal) vkc_put(o, c);
        else { vkc_put(o, '='); vkc_put(o, (uint8_t)"0123456789ABCDEF"[c >> 4]); vkc_put(o, (uint8_t)"0123456789ABCDEF"[c & 15]); }
        line += need;
    }
    return !o->fail;
}
static int vkc_qp_dec(const uint8_t *in, size_t n, vkc_buf *o) {
    for (size_t i = 0; i < n; i++) {
        if (in[i] != '=') { vkc_put(o, in[i]); continue; }
        if (i + 1 < n && in[i + 1] == '\n') { i += 1; continue; }
        if (i + 2 < n && in[i + 1] == '\r' && in[i + 2] == '\n') { i += 2; continue; }
        if (i + 2 >= n) return vkc_fail(o, "truncated quoted-printable escape");
        int a = vkc_hexval(in[i + 1]), b = vkc_hexval(in[i + 2]);
        if (a < 0 || b < 0) return vkc_fail(o, "invalid quoted-printable escape");
        vkc_put(o, (uint8_t)(a * 16 + b)); i += 2;
    }
    return !o->fail;
}

static int vkc_rot13(const uint8_t *in, size_t n, vkc_buf *o) {
    for (size_t i = 0; i < n; i++) {
        uint8_t c = in[i];
        if (c >= 'a' && c <= 'z') c = (uint8_t)('a' + (c - 'a' + 13) % 26);
        else if (c >= 'A' && c <= 'Z') c = (uint8_t)('A' + (c - 'A' + 13) % 26);
        vkc_put(o, c);
    }
    return !o->fail;
}
static int vkc_rot47(const uint8_t *in, size_t n, vkc_buf *o) {
    for (size_t i = 0; i < n; i++) { uint8_t c = in[i]; if (c >= 33 && c <= 126) c = (uint8_t)(33 + (c - 33 + 47) % 94); vkc_put(o, c); }
    return !o->fail;
}

static int vkc_binary_enc(const uint8_t *in, size_t n, vkc_buf *o) {
    for (size_t i = 0; i < n; i++) { if (i) vkc_put(o, ' '); for (int b = 7; b >= 0; b--) vkc_put(o, (uint8_t)('0' + ((in[i] >> b) & 1))); }
    return !o->fail;
}
static int vkc_binary_dec(const uint8_t *in, size_t n, vkc_buf *o) {
    unsigned value = 0; int bits = 0;
    for (size_t i = 0; i < n; i++) {
        if (vkc_is_space(in[i])) continue;
        if (in[i] != '0' && in[i] != '1') return vkc_fail(o, "binary text may contain only 0 and 1");
        value = (value << 1) | (unsigned)(in[i] - '0');
        if (++bits == 8) { vkc_put(o, (uint8_t)value); value = 0; bits = 0; }
    }
    if (bits) return vkc_fail(o, "binary text length must be a multiple of 8 digits");
    return !o->fail;
}

static int vkc_json_enc(const uint8_t *in, size_t n, vkc_buf *o) {
    if (!vkc_valid_utf8(in, n)) return vkc_fail(o, "input is not valid UTF-8 text");
    for (size_t i = 0; i < n;) {
        uint8_t c = in[i];
        if (c == '"') { vkc_write(o, "\\\"", 2); i++; }
        else if (c == '\\') { vkc_write(o, "\\\\", 2); i++; }
        else if (c == '\n') { vkc_write(o, "\\n", 2); i++; } else if (c == '\r') { vkc_write(o, "\\r", 2); i++; }
        else if (c == '\t') { vkc_write(o, "\\t", 2); i++; } else if (c == '\b') { vkc_write(o, "\\b", 2); i++; }
        else if (c == '\f') { vkc_write(o, "\\f", 2); i++; }
        else if (c < 0x20 || c == 0x7F) { static const char hex[] = "0123456789abcdef"; vkc_write(o, "\\u00", 4); vkc_put(o, (uint8_t)hex[c >> 4]); vkc_put(o, (uint8_t)hex[c & 15]); i++; }
        else if (c < 0x80) { vkc_put(o, c); i++; }
        else {
            size_t len = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : 2;
            uint32_t cp = len == 4 ? c & 7 : len == 3 ? c & 15 : c & 31;
            for (size_t k = 1; k < len; k++) cp = (cp << 6) | (in[i + k] & 63);
            i += len;
            static const char hex[] = "0123456789abcdef";
            uint32_t units[2]; int count = 1; units[0] = cp;
            if (cp >= 0x10000) { cp -= 0x10000; units[0] = 0xD800 + (cp >> 10); units[1] = 0xDC00 + (cp & 0x3FF); count = 2; }
            for (int u = 0; u < count; u++) { vkc_write(o, "\\u", 2); for (int s = 12; s >= 0; s -= 4) vkc_put(o, (uint8_t)hex[(units[u] >> s) & 15]); }
        }
    }
    return !o->fail;
}
static int vkc_json_hex4(const uint8_t *s, size_t avail, uint32_t *value) {
    if (avail < 4) return 0;
    uint32_t v = 0; for (int k = 0; k < 4; k++) { int d = vkc_hexval(s[k]); if (d < 0) return 0; v = v * 16 + (uint32_t)d; }
    *value = v; return 1;
}
static int vkc_json_dec(const uint8_t *in, size_t n, vkc_buf *o) {
    for (size_t i = 0; i < n; i++) {
        if (in[i] != '\\') { vkc_put(o, in[i]); continue; }
        if (++i >= n) return vkc_fail(o, "truncated JSON escape");
        switch (in[i]) {
            case '"': vkc_put(o, '"'); break; case '\\': vkc_put(o, '\\'); break; case '/': vkc_put(o, '/'); break;
            case 'b': vkc_put(o, '\b'); break; case 'f': vkc_put(o, '\f'); break; case 'n': vkc_put(o, '\n'); break;
            case 'r': vkc_put(o, '\r'); break; case 't': vkc_put(o, '\t'); break;
            case 'u': {
                uint32_t cp;
                if (!vkc_json_hex4(in + i + 1, n - i - 1, &cp)) return vkc_fail(o, "invalid JSON \\u escape");
                i += 4;
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    uint32_t low;
                    if (i + 2 < n && in[i + 1] == '\\' && in[i + 2] == 'u' && vkc_json_hex4(in + i + 3, n - i - 3, &low) && low >= 0xDC00 && low <= 0xDFFF) { cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00); i += 6; }
                    else return vkc_fail(o, "unpaired UTF-16 surrogate in JSON escape");
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) return vkc_fail(o, "unpaired UTF-16 surrogate in JSON escape");
                vkc_put_utf8(o, cp);
                break;
            }
            default: return vkc_fail(o, "invalid JSON escape");
        }
    }
    return !o->fail;
}

/* ---- DEFLATE (RFC 1951), zlib (RFC 1950), gzip (RFC 1952) ---- */
typedef struct { const uint8_t *in; size_t n, pos; uint32_t buf; int cnt, err; } vkc_inflate_state;
typedef struct { int16_t count[16]; int16_t symbol[288]; } vkc_huffman;

static int vkc_ibits(vkc_inflate_state *s, int need) {
    uint32_t val = s->buf;
    while (s->cnt < need) {
        if (s->pos >= s->n) { s->err = 1; return 0; }
        val |= (uint32_t)s->in[s->pos++] << s->cnt; s->cnt += 8;
    }
    s->buf = val >> need; s->cnt -= need;
    return (int)(val & ((1u << need) - 1));
}
static int vkc_idecode(vkc_inflate_state *s, const vkc_huffman *h) {
    int code = 0, first = 0, index = 0;
    for (int len = 1; len <= 15; len++) {
        code |= vkc_ibits(s, 1);
        if (s->err) return -1;
        int count = h->count[len];
        if (code - count < first) return h->symbol[index + (code - first)];
        index += count; first += count; first <<= 1; code <<= 1;
    }
    return -1;
}
static int vkc_iconstruct(vkc_huffman *h, const int16_t *length, int n) {
    int16_t offs[16]; memset(h->count, 0, sizeof(h->count));
    for (int i = 0; i < n; i++) h->count[length[i]]++;
    if (h->count[0] == n) return 0;
    int left = 1;
    for (int len = 1; len <= 15; len++) { left <<= 1; left -= h->count[len]; if (left < 0) return left; }
    offs[1] = 0; for (int len = 1; len < 15; len++) offs[len + 1] = (int16_t)(offs[len] + h->count[len]);
    for (int i = 0; i < n; i++) if (length[i]) h->symbol[offs[length[i]]++] = (int16_t)i;
    return left;
}
static int vkc_icodes(vkc_inflate_state *s, vkc_buf *o, size_t base, const vkc_huffman *lencode, const vkc_huffman *distcode) {
    static const int16_t lens[29] = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258};
    static const int16_t lext[29] = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0};
    static const int16_t dists[30] = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577};
    static const int16_t dext[30] = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13};
    for (;;) {
        int symbol = vkc_idecode(s, lencode);
        if (symbol < 0) return vkc_fail(o, "corrupt or truncated deflate data");
        if (symbol < 256) vkc_put(o, (uint8_t)symbol);
        else if (symbol == 256) return 1;
        else {
            symbol -= 257;
            if (symbol >= 29) return vkc_fail(o, "invalid deflate length code");
            int len = lens[symbol] + vkc_ibits(s, lext[symbol]);
            int ds = vkc_idecode(s, distcode);
            if (ds < 0 || ds >= 30) return vkc_fail(o, "invalid deflate distance code");
            size_t dist = (size_t)dists[ds] + (size_t)vkc_ibits(s, dext[ds]);
            if (s->err) return vkc_fail(o, "truncated deflate data");
            if (dist > o->n - base) return vkc_fail(o, "deflate distance reaches before the start of the data");
            for (int k = 0; k < len; k++) { if (o->fail) return 0; vkc_put(o, o->p[o->n - dist]); }
        }
        if (o->fail) return 0;
    }
}
static int vkc_inflate(const uint8_t *in, size_t n, size_t *consumed, vkc_buf *o) {
    vkc_inflate_state s = {in, n, 0, 0, 0, 0};
    size_t base = o->n; int last;
    do {
        last = vkc_ibits(&s, 1); int type = vkc_ibits(&s, 2);
        if (s.err) return vkc_fail(o, "truncated deflate data");
        if (type == 0) {
            s.buf = 0; s.cnt = 0;
            if (s.pos + 4 > n) return vkc_fail(o, "truncated deflate stored block");
            unsigned len = in[s.pos] | (in[s.pos + 1] << 8), nlen = in[s.pos + 2] | (in[s.pos + 3] << 8);
            s.pos += 4;
            if (len != (~nlen & 0xFFFF)) return vkc_fail(o, "corrupt deflate stored block");
            if (s.pos + len > n) return vkc_fail(o, "truncated deflate stored block");
            vkc_write(o, in + s.pos, len); s.pos += len;
        } else if (type == 1) {
            vkc_huffman lencode, distcode; int16_t lengths[288];
            int i = 0; for (; i < 144; i++) lengths[i] = 8; for (; i < 256; i++) lengths[i] = 9; for (; i < 280; i++) lengths[i] = 7; for (; i < 288; i++) lengths[i] = 8;
            vkc_iconstruct(&lencode, lengths, 288);
            for (i = 0; i < 30; i++) lengths[i] = 5;
            vkc_iconstruct(&distcode, lengths, 30);
            if (!vkc_icodes(&s, o, base, &lencode, &distcode)) return 0;
        } else if (type == 2) {
            static const int16_t order[19] = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15};
            int16_t lengths[320]; vkc_huffman lencode, distcode;
            int nlen = vkc_ibits(&s, 5) + 257, ndist = vkc_ibits(&s, 5) + 1, ncode = vkc_ibits(&s, 4) + 4;
            if (s.err || nlen > 286 || ndist > 30) return vkc_fail(o, "corrupt deflate block header");
            int idx = 0;
            for (; idx < ncode; idx++) lengths[order[idx]] = (int16_t)vkc_ibits(&s, 3);
            for (; idx < 19; idx++) lengths[order[idx]] = 0;
            if (vkc_iconstruct(&lencode, lengths, 19) != 0) return vkc_fail(o, "corrupt deflate code lengths");
            idx = 0;
            while (idx < nlen + ndist) {
                int symbol = vkc_idecode(&s, &lencode);
                if (symbol < 0) return vkc_fail(o, "corrupt deflate code lengths");
                if (symbol < 16) lengths[idx++] = (int16_t)symbol;
                else {
                    int len = 0, rep;
                    if (symbol == 16) { if (!idx) return vkc_fail(o, "corrupt deflate code lengths"); len = lengths[idx - 1]; rep = 3 + vkc_ibits(&s, 2); }
                    else if (symbol == 17) rep = 3 + vkc_ibits(&s, 3); else rep = 11 + vkc_ibits(&s, 7);
                    if (idx + rep > nlen + ndist) return vkc_fail(o, "corrupt deflate code lengths");
                    while (rep--) lengths[idx++] = (int16_t)len;
                }
            }
            if (s.err) return vkc_fail(o, "truncated deflate data");
            if (lengths[256] == 0) return vkc_fail(o, "deflate block has no end code");
            int err = vkc_iconstruct(&lencode, lengths, nlen);
            if (err && (err < 0 || nlen - lencode.count[0] != 1)) return vkc_fail(o, "corrupt deflate literal codes");
            err = vkc_iconstruct(&distcode, lengths + nlen, ndist);
            if (err && (err < 0 || ndist - distcode.count[0] != 1)) return vkc_fail(o, "corrupt deflate distance codes");
            if (!vkc_icodes(&s, o, base, &lencode, &distcode)) return 0;
        } else return vkc_fail(o, "invalid deflate block type");
        if (o->fail) return 0;
    } while (!last);
    *consumed = s.pos;
    return 1;
}
static int vkc_deflate_dec(const uint8_t *in, size_t n, vkc_buf *o) { size_t used; return vkc_inflate(in, n, &used, o); }
static int vkc_zlib_dec(const uint8_t *in, size_t n, vkc_buf *o) {
    if (n < 6 || (in[0] & 15) != 8 || ((in[0] << 8) | in[1]) % 31 || (in[1] & 0x20)) return vkc_fail(o, "not a zlib stream");
    size_t base = o->n, used;
    if (!vkc_inflate(in + 2, n - 2, &used, o)) return 0;
    if (2 + used + 4 > n) return vkc_fail(o, "truncated zlib checksum");
    const uint8_t *t = in + 2 + used;
    uint32_t want = ((uint32_t)t[0] << 24) | ((uint32_t)t[1] << 16) | ((uint32_t)t[2] << 8) | t[3];
    if (want != vkc_adler32(o->p + base, o->n - base)) return vkc_fail(o, "zlib checksum mismatch");
    return 1;
}
static int vkc_gzip_dec(const uint8_t *in, size_t n, vkc_buf *o) {
    size_t p = 0; int members = 0;
    while (p < n) {
        if (n - p < 18 || in[p] != 0x1F || in[p + 1] != 0x8B || in[p + 2] != 8) { if (members && p == n) break; return vkc_fail(o, "not a gzip stream"); }
        unsigned flags = in[p + 3]; size_t q = p + 10;
        if (flags & 4) { if (q + 2 > n) return vkc_fail(o, "truncated gzip header"); q += 2 + (in[q] | (in[q + 1] << 8)); }
        if (flags & 8) { while (q < n && in[q]) q++; q++; }
        if (flags & 16) { while (q < n && in[q]) q++; q++; }
        if (flags & 2) q += 2;
        if (q >= n) return vkc_fail(o, "truncated gzip header");
        size_t base = o->n, used;
        if (!vkc_inflate(in + q, n - q, &used, o)) return 0;
        q += used;
        if (q + 8 > n) return vkc_fail(o, "truncated gzip trailer");
        if (vkc_rd32(in + q) != vkc_crc32(o->p + base, o->n - base)) return vkc_fail(o, "gzip checksum mismatch");
        if (vkc_rd32(in + q + 4) != (uint32_t)(o->n - base)) return vkc_fail(o, "gzip size mismatch");
        p = q + 8; members++;
    }
    return !o->fail;
}

typedef struct { vkc_buf *o; uint32_t acc; int cnt; } vkc_bitwriter;
static void vkc_bw_put(vkc_bitwriter *w, uint32_t v, int n) {
    w->acc |= v << w->cnt; w->cnt += n;
    while (w->cnt >= 8) { vkc_put(w->o, (uint8_t)w->acc); w->acc >>= 8; w->cnt -= 8; }
}
static uint32_t vkc_rev(uint32_t v, int n) { uint32_t r = 0; for (int i = 0; i < n; i++) { r = (r << 1) | (v & 1); v >>= 1; } return r; }
static void vkc_fixed_symbol(vkc_bitwriter *w, int s) {
    if (s < 144) vkc_bw_put(w, vkc_rev(0x30 + (uint32_t)s, 8), 8);
    else if (s < 256) vkc_bw_put(w, vkc_rev(0x190 + (uint32_t)s - 144, 9), 9);
    else if (s < 280) vkc_bw_put(w, vkc_rev((uint32_t)s - 256, 7), 7);
    else vkc_bw_put(w, vkc_rev(0xC0 + (uint32_t)s - 280, 8), 8);
}
static int vkc_deflate_raw(const uint8_t *in, size_t n, vkc_buf *o) {
    static const int16_t lens[29] = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258};
    static const int16_t lext[29] = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0};
    static const int16_t dists[30] = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577};
    static const int16_t dext[30] = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13};
    vkc_bitwriter w = {o, 0, 0};
    int32_t *head = (int32_t *)malloc(sizeof(int32_t) * (1u << 15)), *prev = (int32_t *)malloc(sizeof(int32_t) * 32768u);
    if (!head || !prev) { free(head); free(prev); return vkc_fail(o, "out of memory"); }
    for (size_t i = 0; i < (1u << 15); i++) head[i] = -1;
    vkc_bw_put(&w, 1, 1); vkc_bw_put(&w, 1, 2);
    size_t i = 0;
#define VKC_HASH(p) ((((uint32_t)(p)[0] << 10) ^ ((uint32_t)(p)[1] << 5) ^ (p)[2]) & 0x7FFF)
    while (i < n) {
        size_t best = 0, best_dist = 0;
        if (i + 2 < n) {
            int32_t cand = head[VKC_HASH(in + i)]; int chain = 0;
            while (cand >= 0 && i - (size_t)cand <= 32768 && chain++ < 48) {
                size_t len = 0, max = n - i < 258 ? n - i : 258;
                while (len < max && in[(size_t)cand + len] == in[i + len]) len++;
                if (len > best) { best = len; best_dist = i - (size_t)cand; if (len == max) break; }
                int32_t next = prev[(size_t)cand & 32767];
                if (next >= cand) break;
                cand = next;
            }
        }
        size_t advance = 1;
        if (best >= 3) {
            int lc = 28; if (best < 258) { lc = 0; while (lc < 27 && lens[lc + 1] <= (int)best) lc++; }
            vkc_fixed_symbol(&w, 257 + lc); if (lext[lc]) vkc_bw_put(&w, (uint32_t)(best - (size_t)lens[lc]), lext[lc]);
            int dc = 0; while (dc < 29 && dists[dc + 1] <= (int)best_dist) dc++;
            vkc_bw_put(&w, vkc_rev((uint32_t)dc, 5), 5); if (dext[dc]) vkc_bw_put(&w, (uint32_t)(best_dist - (size_t)dists[dc]), dext[dc]);
            advance = best;
        } else vkc_fixed_symbol(&w, in[i]);
        for (size_t k = 0; k < advance; k++) {
            if (i + k + 2 < n) { uint32_t h = VKC_HASH(in + i + k); prev[(i + k) & 32767] = head[h]; head[h] = (int32_t)(i + k); }
        }
        i += advance;
        if (o->fail) break;
    }
#undef VKC_HASH
    vkc_fixed_symbol(&w, 256);
    if (w.cnt) vkc_put(o, (uint8_t)w.acc);
    free(head); free(prev);
    return !o->fail;
}
static int vkc_zlib_enc(const uint8_t *in, size_t n, vkc_buf *o) {
    vkc_put(o, 0x78); vkc_put(o, 0x9C);
    if (!vkc_deflate_raw(in, n, o)) return 0;
    uint32_t a = vkc_adler32(in, n);
    vkc_put(o, (uint8_t)(a >> 24)); vkc_put(o, (uint8_t)(a >> 16)); vkc_put(o, (uint8_t)(a >> 8)); vkc_put(o, (uint8_t)a);
    return !o->fail;
}
static int vkc_gzip_enc(const uint8_t *in, size_t n, vkc_buf *o) {
    static const uint8_t header[10] = {0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF};
    vkc_write(o, header, 10);
    if (!vkc_deflate_raw(in, n, o)) return 0;
    vkc_put32(o, vkc_crc32(in, n)); vkc_put32(o, (uint32_t)n);
    return !o->fail;
}

/* ---- Zstandard (RFC 8878) decoder and raw/RLE-block encoder; dictionaries are not supported ---- */
typedef struct { uint8_t sym, nb; uint16_t base; } vkc_fse_entry;
typedef struct { int al, valid; vkc_fse_entry e[512]; } vkc_fse;
typedef struct { uint8_t sym[2048], nb[2048]; int maxbits, valid; } vkc_huf;
typedef struct { const uint8_t *p; int64_t pos; } vkc_rbs;
typedef struct { vkc_huf huf; vkc_fse ll, of, ml; uint32_t rep[3]; } vkc_zctx;

static int vkc_rbs_init(vkc_rbs *r, const uint8_t *p, size_t n) {
    if (!n || !p[n - 1]) return 0;
    r->p = p; r->pos = (int64_t)(n - 1) * 8 + vkc_highbit(p[n - 1]);
    return 1;
}
static uint32_t vkc_rbs_peek(const vkc_rbs *r, int nb) {
    uint32_t v = 0;
    for (int k = 1; k <= nb; k++) { int64_t i = r->pos - k; v = (v << 1) | (i >= 0 ? (uint32_t)((r->p[i >> 3] >> (i & 7)) & 1) : 0u); }
    return v;
}
static int vkc_rbs_read(vkc_rbs *r, int nb, uint32_t *out) { *out = nb ? vkc_rbs_peek(r, nb) : 0; r->pos -= nb; return r->pos >= 0; }

static int vkc_fse_build(vkc_fse *t, const int16_t *norm, int nsym, int al) {
    int size = 1 << al, high = size - 1, next[256];
    int total = 0;
    for (int s = 0; s < nsym; s++) total += norm[s] < 0 ? 1 : norm[s];
    if (total != size) return 0;
    for (int s = 0; s < nsym; s++) { if (norm[s] == -1) { t->e[high--].sym = (uint8_t)s; next[s] = 1; } else next[s] = norm[s]; }
    int pos = 0, step = (size >> 1) + (size >> 3) + 3, mask = size - 1;
    for (int s = 0; s < nsym; s++) for (int i = 0; i < norm[s]; i++) { t->e[pos].sym = (uint8_t)s; do pos = (pos + step) & mask; while (pos > high); }
    if (pos != 0) return 0;
    for (int u = 0; u < size; u++) {
        int s = t->e[u].sym, ns = next[s]++;
        int nb = al - vkc_highbit((uint32_t)ns);
        t->e[u].nb = (uint8_t)nb; t->e[u].base = (uint16_t)((ns << nb) - size);
    }
    t->al = al; t->valid = 1;
    return 1;
}
static uint32_t vkc_fb_read(const uint8_t *p, size_t n, size_t *bitpos, int k) {
    uint32_t v = 0;
    for (int i = 0; i < k; i++) { size_t b = *bitpos + (size_t)i; v |= (uint32_t)(b < n * 8 ? (p[b >> 3] >> (b & 7)) & 1 : 0) << i; }
    *bitpos += (size_t)k;
    return v;
}
/* Reads an FSE table description; returns bytes consumed or -1. */
static int vkc_fse_read_ncount(const uint8_t *p, size_t n, int16_t *norm, int maxsym, int maxal, int *nsym, int *alog) {
    size_t bitpos = 0;
    int al = (int)vkc_fb_read(p, n, &bitpos, 4) + 5;
    if (al > maxal) return -1;
    int remaining = (1 << al) + 1, threshold = 1 << al, nbbits = al + 1, sym = 0, prev0 = 0;
    while (remaining > 1 && sym <= maxsym) {
        if (prev0) {
            int r;
            do { r = (int)vkc_fb_read(p, n, &bitpos, 2); for (int k = 0; k < r; k++) { if (sym > maxsym) return -1; norm[sym++] = 0; } } while (r == 3);
            if (sym > maxsym) return -1;
        }
        int max = (2 * threshold - 1) - remaining, count;
        size_t save = bitpos; uint32_t v = vkc_fb_read(p, n, &bitpos, nbbits);
        if ((int)(v & (uint32_t)(threshold - 1)) < max) { count = (int)(v & (uint32_t)(threshold - 1)); bitpos = save + (size_t)(nbbits - 1); }
        else { count = (int)(v & (uint32_t)(2 * threshold - 1)); if (count >= threshold) count -= max; }
        count--;
        remaining -= count < 0 ? -count : count;
        if (remaining < 1 || bitpos > n * 8) return -1;
        norm[sym++] = (int16_t)count; prev0 = (count == 0);
        while (remaining < threshold) { nbbits--; threshold >>= 1; }
    }
    if (remaining != 1 || bitpos > n * 8) return -1;
    *nsym = sym; *alog = al;
    return (int)((bitpos + 7) / 8);
}
static int vkc_fse_set_predefined(vkc_fse *t, int kind) {
    static const int16_t ll[36] = {4,3,2,2,2,2,2,2,2,2,2,2,2,1,1,1,2,2,2,2,2,2,2,2,2,3,2,1,1,1,1,1,-1,-1,-1,-1};
    static const int16_t ml[53] = {1,4,3,2,2,2,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1,-1,-1};
    static const int16_t of[29] = {1,1,1,1,1,1,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1};
    if (kind == 0) return vkc_fse_build(t, ll, 36, 6);
    if (kind == 1) return vkc_fse_build(t, of, 29, 5);
    return vkc_fse_build(t, ml, 53, 6);
}
/* Reads a Huffman tree description; returns bytes consumed or -1. */
static int vkc_huf_read_tree(const uint8_t *p, size_t n, vkc_huf *h) {
    uint8_t w[256]; int nw, used;
    if (!n) return -1;
    int header = p[0];
    if (header >= 128) {
        nw = header - 127; used = 1 + (nw + 1) / 2;
        if ((size_t)used > n) return -1;
        for (int i = 0; i < nw; i++) w[i] = (i & 1) ? (p[1 + i / 2] & 15) : (p[1 + i / 2] >> 4);
    } else {
        if (!header || (size_t)header + 1 > n) return -1;
        int16_t norm[256]; int nsym, al; vkc_fse t;
        int head = vkc_fse_read_ncount(p + 1, (size_t)header, norm, 255, 6, &nsym, &al);
        if (head < 0 || !vkc_fse_build(&t, norm, nsym, al)) return -1;
        vkc_rbs r; if (!vkc_rbs_init(&r, p + 1 + head, (size_t)header - (size_t)head)) return -1;
        uint32_t s1, s2; nw = 0;
        if (!vkc_rbs_read(&r, al, &s1) || !vkc_rbs_read(&r, al, &s2)) return -1;
        for (;;) {
            if (nw >= 255) return -1;
            w[nw++] = t.e[s1].sym;
            vkc_fse_entry e = t.e[s1];
            if (e.nb > r.pos) { if (nw >= 255) return -1; w[nw++] = t.e[s2].sym; break; }
            uint32_t bits; vkc_rbs_read(&r, e.nb, &bits); s1 = e.base + bits;
            if (nw >= 255) return -1;
            w[nw++] = t.e[s2].sym; e = t.e[s2];
            if (e.nb > r.pos) { if (nw >= 255) return -1; w[nw++] = t.e[s1].sym; break; }
            vkc_rbs_read(&r, e.nb, &bits); s2 = e.base + bits;
        }
        used = 1 + header;
    }
    uint32_t sum = 0;
    for (int i = 0; i < nw; i++) { if (w[i] > 11) return -1; if (w[i]) sum += 1u << (w[i] - 1); }
    if (!sum) return -1;
    int maxbits = vkc_highbit(sum) + 1;
    if (maxbits > 11) return -1;
    uint32_t left = (1u << maxbits) - sum;
    if (!left || (left & (left - 1)) || nw > 255) return -1;
    w[nw] = (uint8_t)(vkc_highbit(left) + 1); int nsym = nw + 1;
    uint32_t pos = 0;
    for (int weight = 1; weight <= maxbits; weight++) for (int s = 0; s < nsym; s++) if (w[s] == weight) {
        uint32_t len = 1u << (weight - 1);
        for (uint32_t k = 0; k < len; k++) { h->sym[pos + k] = (uint8_t)s; h->nb[pos + k] = (uint8_t)(maxbits + 1 - weight); }
        pos += len;
    }
    if (pos != (1u << maxbits)) return -1;
    h->maxbits = maxbits; h->valid = 1;
    return used;
}
static int vkc_huf_decode_stream(const vkc_huf *h, const uint8_t *p, size_t n, uint8_t *dst, size_t count) {
    vkc_rbs r; if (!vkc_rbs_init(&r, p, n)) return 0;
    for (size_t i = 0; i < count; i++) {
        uint32_t v = vkc_rbs_peek(&r, h->maxbits);
        dst[i] = h->sym[v]; r.pos -= h->nb[v];
        if (r.pos < 0) return 0;
    }
    return r.pos == 0;
}

static int vkc_zstd_block(vkc_zctx *c, const uint8_t *p, size_t n, vkc_buf *o, size_t frame_base) {
    static const uint32_t llbase[36] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,18,20,22,24,28,32,40,48,64,128,256,512,1024,2048,4096,8192,16384,32768,65536};
    static const uint8_t llbits[36] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,2,2,3,3,4,6,7,8,9,10,11,12,13,14,15,16};
    static const uint32_t mlbase[53] = {3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,37,39,41,43,47,51,59,67,83,99,131,259,515,1027,2051,4099,8195,16387,32771,65539};
    static const uint8_t mlbits[53] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,2,2,3,3,4,4,5,7,8,9,10,11,12,13,14,15,16};
    size_t pos = 0;
    if (!n) return vkc_fail(o, "empty zstd block");
    int ltype = p[0] & 3, sf = (p[0] >> 2) & 3;
    uint8_t *lit = NULL; size_t lit_n = 0; int ok = 0;
    size_t hdr = 0, regen = 0, comp = 0;
    if (ltype <= 1) {
        if (sf == 0 || sf == 2) { hdr = 1; regen = p[0] >> 3; }
        else if (sf == 1) { hdr = 2; if (n < 2) goto fail; regen = (size_t)(p[0] >> 4) + ((size_t)p[1] << 4); }
        else { hdr = 3; if (n < 3) goto fail; regen = (size_t)(p[0] >> 4) + ((size_t)p[1] << 4) + ((size_t)p[2] << 12); }
        if (regen > 131072) goto fail;
        lit = (uint8_t *)malloc(regen ? regen : 1); if (!lit) goto fail;
        if (ltype == 0) { if (hdr + regen > n) goto fail; memcpy(lit, p + hdr, regen); pos = hdr + regen; }
        else { if (hdr + 1 > n) goto fail; memset(lit, p[hdr], regen); pos = hdr + 1; }
        lit_n = regen;
    } else {
        int streams = sf == 0 ? 1 : 4; int sizebits = sf <= 1 ? 10 : sf == 2 ? 14 : 18;
        hdr = sf <= 1 ? 3 : sf == 2 ? 4 : 5;
        if (n < hdr) goto fail;
        uint64_t bits = 0; for (size_t i = 0; i < hdr; i++) bits |= (uint64_t)p[i] << (8 * i);
        bits >>= 4; regen = (size_t)(bits & ((1u << sizebits) - 1)); comp = (size_t)((bits >> sizebits) & ((1u << sizebits) - 1));
        if (regen > 131072 || hdr + comp > n) goto fail;
        const uint8_t *data = p + hdr; size_t remaining = comp;
        if (ltype == 2) { int used = vkc_huf_read_tree(data, remaining, &c->huf); if (used < 0 || (size_t)used > remaining) goto fail; data += used; remaining -= (size_t)used; }
        else if (!c->huf.valid) goto fail;
        lit = (uint8_t *)malloc(regen ? regen : 1); if (!lit) goto fail;
        if (streams == 1) { if (!vkc_huf_decode_stream(&c->huf, data, remaining, lit, regen)) goto fail; }
        else {
            if (remaining < 6) goto fail;
            size_t s1 = (size_t)(data[0] | (data[1] << 8)), s2 = (size_t)(data[2] | (data[3] << 8)), s3 = (size_t)(data[4] | (data[5] << 8));
            if (s1 + s2 + s3 + 6 > remaining) goto fail;
            size_t s4 = remaining - 6 - s1 - s2 - s3, each = (regen + 3) / 4;
            if (each * 3 > regen) goto fail;
            const uint8_t *q = data + 6; size_t sizes[4] = {s1, s2, s3, s4}, counts[4] = {each, each, each, regen - each * 3};
            size_t out_at = 0;
            for (int k = 0; k < 4; k++) { if (!vkc_huf_decode_stream(&c->huf, q, sizes[k], lit + out_at, counts[k])) goto fail; q += sizes[k]; out_at += counts[k]; }
        }
        lit_n = regen; pos = hdr + comp;
    }
    /* Sequences section */
    if (pos >= n) goto fail;
    size_t nseq = p[pos++];
    if (nseq == 0) { vkc_write(o, lit, lit_n); ok = !o->fail; goto done; }
    if (nseq >= 128) {
        if (nseq < 255) { if (pos >= n) goto fail; nseq = ((nseq - 128) << 8) + p[pos++]; }
        else { if (pos + 2 > n) goto fail; nseq = (size_t)p[pos] + ((size_t)p[pos + 1] << 8) + 0x7F00; pos += 2; }
    }
    if (pos >= n) goto fail;
    int modes = p[pos++];
    if (modes & 3) goto fail;
    vkc_fse *tables[3] = {&c->ll, &c->of, &c->ml};
    int maxsym[3] = {35, 31, 52}, maxal[3] = {9, 8, 9};
    for (int t = 0; t < 3; t++) {
        int mode = (modes >> (6 - 2 * t)) & 3;
        if (mode == 0) { if (!vkc_fse_set_predefined(tables[t], t)) goto fail; }
        else if (mode == 1) { if (pos >= n || p[pos] > maxsym[t]) goto fail; tables[t]->e[0].sym = p[pos++]; tables[t]->e[0].nb = 0; tables[t]->e[0].base = 0; tables[t]->al = 0; tables[t]->valid = 1; }
        else if (mode == 2) {
            int16_t norm[256]; int nsym, al;
            int used = vkc_fse_read_ncount(p + pos, n - pos, norm, maxsym[t], maxal[t], &nsym, &al);
            if (used < 0 || !vkc_fse_build(tables[t], norm, nsym, al)) goto fail;
            pos += (size_t)used;
        } else if (!tables[t]->valid) goto fail;
    }
    vkc_rbs r; if (pos >= n || !vkc_rbs_init(&r, p + pos, n - pos)) goto fail;
    uint32_t sll, sof, sml, bits;
    if (!vkc_rbs_read(&r, c->ll.al, &sll) || !vkc_rbs_read(&r, c->of.al, &sof) || !vkc_rbs_read(&r, c->ml.al, &sml)) goto fail;
    size_t lit_pos = 0;
    for (size_t i = 0; i < nseq; i++) {
        int ofc = c->of.e[sof].sym, mlc = c->ml.e[sml].sym, llc = c->ll.e[sll].sym;
        if (ofc > 31) goto fail;
        if (!vkc_rbs_read(&r, ofc, &bits)) goto fail;
        uint64_t ofv = ((uint64_t)1 << ofc) + bits;
        if (!vkc_rbs_read(&r, mlbits[mlc], &bits)) goto fail;
        size_t mlen = mlbase[mlc] + bits;
        if (!vkc_rbs_read(&r, llbits[llc], &bits)) goto fail;
        size_t llen = llbase[llc] + bits;
        if (i + 1 < nseq) {
            vkc_fse_entry e = c->ll.e[sll]; if (!vkc_rbs_read(&r, e.nb, &bits)) goto fail; sll = e.base + bits;
            e = c->ml.e[sml]; if (!vkc_rbs_read(&r, e.nb, &bits)) goto fail; sml = e.base + bits;
            e = c->of.e[sof]; if (!vkc_rbs_read(&r, e.nb, &bits)) goto fail; sof = e.base + bits;
        }
        uint64_t offset;
        if (ofv > 3) { offset = ofv - 3; c->rep[2] = c->rep[1]; c->rep[1] = c->rep[0]; c->rep[0] = (uint32_t)offset; }
        else {
            int idx = (int)ofv - 1 + (llen == 0 ? 1 : 0);
            if (idx == 3) { offset = (uint64_t)c->rep[0] - 1; if (!offset) goto fail; c->rep[2] = c->rep[1]; c->rep[1] = c->rep[0]; c->rep[0] = (uint32_t)offset; }
            else {
                offset = c->rep[idx];
                if (idx == 1) { uint32_t t = c->rep[1]; c->rep[1] = c->rep[0]; c->rep[0] = t; }
                else if (idx == 2) { uint32_t t = c->rep[2]; c->rep[2] = c->rep[1]; c->rep[1] = c->rep[0]; c->rep[0] = t; }
            }
        }
        if (llen > lit_n - lit_pos) goto fail;
        vkc_write(o, lit + lit_pos, llen); lit_pos += llen;
        if (offset == 0 || offset > o->n - frame_base) goto fail;
        if (!vkc_reserve(o, mlen)) goto done_fail;
        for (size_t k = 0; k < mlen; k++) o->p[o->n + k] = o->p[o->n + k - (size_t)offset];
        o->n += mlen;
    }
    if (r.pos != 0) goto fail;
    vkc_write(o, lit + lit_pos, lit_n - lit_pos);
    ok = !o->fail;
    goto done;
fail:
    vkc_fail(o, "corrupt zstd block");
done_fail:
done:
    free(lit);
    return ok;
}
static int vkc_zstd_dec(const uint8_t *in, size_t n, vkc_buf *o) {
    size_t p = 0;
    if (!n) return vkc_fail(o, "empty zstd input");
    while (p < n) {
        if (n - p < 4) return vkc_fail(o, "truncated zstd frame");
        uint32_t magic = vkc_rd32(in + p);
        if ((magic & 0xFFFFFFF0u) == 0x184D2A50u) {
            if (n - p < 8) return vkc_fail(o, "truncated zstd skippable frame");
            uint32_t size = vkc_rd32(in + p + 4);
            if (size > n - p - 8) return vkc_fail(o, "truncated zstd skippable frame");
            p += 8 + size; continue;
        }
        if (magic != 0xFD2FB528u) return vkc_fail(o, "not a zstd frame");
        p += 4;
        if (p >= n) return vkc_fail(o, "truncated zstd frame header");
        int fhd = in[p++], fcsflag = fhd >> 6, single = (fhd >> 5) & 1, checksum = (fhd >> 2) & 1, didflag = fhd & 3;
        if (fhd & 8) return vkc_fail(o, "reserved zstd flag set");
        if (!single) { if (p >= n) return vkc_fail(o, "truncated zstd frame header"); p++; }
        static const int didsize[4] = {0, 1, 2, 4}, fcssize[4] = {0, 2, 4, 8};
        int ds = didsize[didflag], fs = fcsflag ? fcssize[fcsflag] : (single ? 1 : 0);
        if (p + (size_t)ds + (size_t)fs > n) return vkc_fail(o, "truncated zstd frame header");
        uint32_t did = 0; for (int i = 0; i < ds; i++) did |= (uint32_t)in[p + i] << (8 * i);
        p += (size_t)ds;
        if (did) return vkc_fail(o, "zstd dictionaries are not supported");
        int has_fcs = fs > 0; uint64_t fcs = 0;
        for (int i = 0; i < fs; i++) fcs |= (uint64_t)in[p + i] << (8 * i);
        if (fs == 2) fcs += 256;
        p += (size_t)fs;
        size_t base = o->n; vkc_zctx *c = (vkc_zctx *)calloc(1, sizeof(vkc_zctx));
        if (!c) return vkc_fail(o, "out of memory");
        c->rep[0] = 1; c->rep[1] = 4; c->rep[2] = 8;
        int last = 0;
        while (!last) {
            if (p + 3 > n) { free(c); return vkc_fail(o, "truncated zstd block header"); }
            uint32_t bh = (uint32_t)in[p] | ((uint32_t)in[p + 1] << 8) | ((uint32_t)in[p + 2] << 16); p += 3;
            last = bh & 1; int type = (bh >> 1) & 3; size_t size = bh >> 3;
            if (size > 131072) { free(c); return vkc_fail(o, "zstd block is too large"); }
            if (type == 0) { if (p + size > n) { free(c); return vkc_fail(o, "truncated zstd block"); } vkc_write(o, in + p, size); p += size; }
            else if (type == 1) { if (p + 1 > n) { free(c); return vkc_fail(o, "truncated zstd block"); } if (vkc_reserve(o, size)) { memset(o->p + o->n, in[p], size); o->n += size; } p += 1; }
            else if (type == 2) { if (p + size > n) { free(c); return vkc_fail(o, "truncated zstd block"); } if (!vkc_zstd_block(c, in + p, size, o, base)) { free(c); return 0; } p += size; }
            else { free(c); return vkc_fail(o, "reserved zstd block type"); }
            if (o->fail) { free(c); return 0; }
        }
        free(c);
        if (checksum) {
            if (p + 4 > n) return vkc_fail(o, "truncated zstd checksum");
            if (vkc_rd32(in + p) != (uint32_t)vkc_xxh64(o->p + base, o->n - base)) return vkc_fail(o, "zstd checksum mismatch");
            p += 4;
        }
        if (has_fcs && o->n - base != fcs) return vkc_fail(o, "zstd content size mismatch");
    }
    return !o->fail;
}
static int vkc_zstd_enc(const uint8_t *in, size_t n, vkc_buf *o) {
    vkc_put32(o, 0xFD2FB528u);
    int flag = n <= 255 ? 0 : n <= 65791 ? 1 : 2;
    vkc_put(o, (uint8_t)((flag << 6) | (1 << 5) | (1 << 2)));
    if (flag == 0) vkc_put(o, (uint8_t)n);
    else if (flag == 1) { uint32_t v = (uint32_t)(n - 256); vkc_put(o, (uint8_t)v); vkc_put(o, (uint8_t)(v >> 8)); }
    else vkc_put32(o, (uint32_t)n);
    size_t at = 0;
    do {
        size_t chunk = n - at < 131072 ? n - at : 131072;
        int last = at + chunk >= n, rle = chunk > 1;
        for (size_t i = 1; i < chunk && rle; i++) if (in[at + i] != in[at]) rle = 0;
        uint32_t header = (uint32_t)last | ((rle ? 1u : 0u) << 1) | ((uint32_t)chunk << 3);
        vkc_put(o, (uint8_t)header); vkc_put(o, (uint8_t)(header >> 8)); vkc_put(o, (uint8_t)(header >> 16));
        if (rle) vkc_put(o, in[at]); else vkc_write(o, in + at, chunk);
        at += chunk;
    } while (at < n);
    vkc_put32(o, (uint32_t)vkc_xxh64(in, n));
    return !o->fail;
}

/* ---- LZ4 frame format ---- */
static int vkc_lz4_block(const uint8_t *in, size_t n, vkc_buf *o, size_t base) {
    size_t ip = 0;
    while (ip < n) {
        uint8_t token = in[ip++]; size_t lit = token >> 4;
        if (lit == 15) { uint8_t b; do { if (ip >= n) return vkc_fail(o, "corrupt lz4 block"); b = in[ip++]; lit += b; } while (b == 255); }
        if (lit > n - ip) return vkc_fail(o, "corrupt lz4 block");
        vkc_write(o, in + ip, lit); ip += lit;
        if (ip >= n) break;
        if (ip + 2 > n) return vkc_fail(o, "corrupt lz4 block");
        size_t offset = (size_t)in[ip] | ((size_t)in[ip + 1] << 8); ip += 2;
        size_t mlen = token & 15;
        if (mlen == 15) { uint8_t b; do { if (ip >= n) return vkc_fail(o, "corrupt lz4 block"); b = in[ip++]; mlen += b; } while (b == 255); }
        mlen += 4;
        if (!offset || offset > o->n - base) return vkc_fail(o, "lz4 offset reaches before the start of the data");
        if (!vkc_reserve(o, mlen)) return 0;
        for (size_t k = 0; k < mlen; k++) o->p[o->n + k] = o->p[o->n + k - offset];
        o->n += mlen;
    }
    return !o->fail;
}
static int vkc_lz4_dec(const uint8_t *in, size_t n, vkc_buf *o) {
    size_t p = 0;
    if (!n) return vkc_fail(o, "empty lz4 input");
    while (p < n) {
        if (n - p < 4) return vkc_fail(o, "truncated lz4 frame");
        uint32_t magic = vkc_rd32(in + p);
        if ((magic & 0xFFFFFFF0u) == 0x184D2A50u) {
            if (n - p < 8) return vkc_fail(o, "truncated lz4 skippable frame");
            uint32_t size = vkc_rd32(in + p + 4);
            if (size > n - p - 8) return vkc_fail(o, "truncated lz4 skippable frame");
            p += 8 + size; continue;
        }
        if (magic != 0x184D2204u) return vkc_fail(o, "not an lz4 frame");
        size_t start = p; p += 4;
        if (p + 2 > n) return vkc_fail(o, "truncated lz4 header");
        int flg = in[p], bd = in[p + 1];
        if ((flg >> 6) != 1 || (flg & 2) || (bd & 0x8F)) return vkc_fail(o, "unsupported lz4 frame flags");
        int block_sum = (flg >> 4) & 1, has_size = (flg >> 3) & 1, content_sum = (flg >> 2) & 1, has_dict = flg & 1;
        p += 2;
        size_t extra = (size_t)(has_size ? 8 : 0) + (size_t)(has_dict ? 4 : 0);
        if (p + extra + 1 > n) return vkc_fail(o, "truncated lz4 header");
        p += extra;
        if (in[p] != (uint8_t)((vkc_xxh32(in + start + 4, p - start - 4) >> 8) & 255)) return vkc_fail(o, "lz4 header checksum mismatch");
        p++;
        if (has_dict) return vkc_fail(o, "lz4 dictionaries are not supported");
        size_t base = o->n;
        for (;;) {
            if (p + 4 > n) return vkc_fail(o, "truncated lz4 block");
            uint32_t size = vkc_rd32(in + p); p += 4;
            if (!size) break;
            int raw = size >> 31; size &= 0x7FFFFFFFu;
            if (size > n - p) return vkc_fail(o, "truncated lz4 block");
            if (raw) vkc_write(o, in + p, size); else if (!vkc_lz4_block(in + p, size, o, base)) return 0;
            p += size;
            if (block_sum) { if (p + 4 > n) return vkc_fail(o, "truncated lz4 block checksum"); if (vkc_rd32(in + p) != vkc_xxh32(in + p - size, size)) return vkc_fail(o, "lz4 block checksum mismatch"); p += 4; }
            if (o->fail) return 0;
        }
        if (content_sum) {
            if (p + 4 > n) return vkc_fail(o, "truncated lz4 checksum");
            if (vkc_rd32(in + p) != vkc_xxh32(o->p + base, o->n - base)) return vkc_fail(o, "lz4 checksum mismatch");
            p += 4;
        }
    }
    return !o->fail;
}
static void vkc_lz4_emit(vkc_buf *o, const uint8_t *src, size_t anchor, size_t ip, size_t mlen, size_t offset, int last) {
    size_t lit = ip - anchor, code = last ? 0 : mlen - 4;
    vkc_put(o, (uint8_t)(((lit < 15 ? lit : 15) << 4) | (last ? 0 : (code < 15 ? code : 15))));
    if (lit >= 15) { size_t r = lit - 15; while (r >= 255) { vkc_put(o, 255); r -= 255; } vkc_put(o, (uint8_t)r); }
    vkc_write(o, src + anchor, lit);
    if (last) return;
    vkc_put(o, (uint8_t)offset); vkc_put(o, (uint8_t)(offset >> 8));
    if (code >= 15) { size_t r = code - 15; while (r >= 255) { vkc_put(o, 255); r -= 255; } vkc_put(o, (uint8_t)r); }
}
static int vkc_lz4_enc(const uint8_t *in, size_t n, vkc_buf *o) {
    vkc_put32(o, 0x184D2204u);
    uint8_t descriptor[2] = {0x64, 0x40};
    vkc_write(o, descriptor, 2); vkc_put(o, (uint8_t)((vkc_xxh32(descriptor, 2) >> 8) & 255));
    int32_t *table = (int32_t *)malloc(sizeof(int32_t) << 14);
    vkc_buf block = {0};
    if (!table) return vkc_fail(o, "out of memory");
    for (size_t at = 0; at < n; at += 65536) {
        size_t len = n - at < 65536 ? n - at : 65536; const uint8_t *src = in + at;
        for (size_t i = 0; i < (1u << 14); i++) table[i] = -1;
        block.n = 0;
        size_t ip = 0, anchor = 0;
        if (len >= 13) {
            size_t mflimit = len - 12, matchlimit = len - 5;
            while (ip < mflimit) {
                uint32_t seq = vkc_rd32(src + ip), h = (seq * 2654435761u) >> 18;
                int32_t ref = table[h]; table[h] = (int32_t)ip;
                if (ref >= 0 && ip - (size_t)ref <= 65535 && vkc_rd32(src + ref) == seq) {
                    size_t mlen = 4; while (ip + mlen < matchlimit && src[(size_t)ref + mlen] == src[ip + mlen]) mlen++;
                    vkc_lz4_emit(&block, src, anchor, ip, mlen, ip - (size_t)ref, 0);
                    ip += mlen; anchor = ip;
                } else ip++;
            }
        }
        vkc_lz4_emit(&block, src, anchor, len, 0, 0, 1);
        if (block.fail) { free(table); vkc_free(&block); return vkc_fail(o, "out of memory"); }
        if (block.n < len) { vkc_put32(o, (uint32_t)block.n); vkc_write(o, block.p, block.n); }
        else { vkc_put32(o, (uint32_t)len | 0x80000000u); vkc_write(o, src, len); }
    }
    vkc_put32(o, 0); vkc_put32(o, vkc_xxh32(in, n));
    free(table); vkc_free(&block);
    return !o->fail;
}

/* ---- Format registry and chains such as "zstd+base64" ---- */
typedef int (*vkc_fn)(const uint8_t *, size_t, vkc_buf *);
typedef struct { const char *names; vkc_fn encode, decode; int text; } vkc_codec;
static const vkc_codec vkc_codecs[] = {
    {"base64 b64", vkc_base64_enc, vkc_base64_dec, 1}, {"base64url b64url", vkc_base64url_enc, vkc_base64url_dec, 1},
    {"base32 b32", vkc_base32_enc, vkc_base32_dec, 1}, {"base32hex b32hex", vkc_base32hex_enc, vkc_base32hex_dec, 1},
    {"hex base16 b16", vkc_hex_enc, vkc_hex_dec, 1}, {"base58 b58", vkc_base58_enc, vkc_base58_dec, 1},
    {"ascii85 base85 a85", vkc_ascii85_enc, vkc_ascii85_dec, 1}, {"url percent", vkc_url_enc, vkc_url_dec, 1},
    {"urlform", vkc_urlform_enc, vkc_urlform_dec, 1}, {"html xml entities", vkc_html_enc, vkc_html_dec, 1},
    {"qp quoted-printable", vkc_qp_enc, vkc_qp_dec, 1}, {"rot13", vkc_rot13, vkc_rot13, 1}, {"rot47", vkc_rot47, vkc_rot47, 1},
    {"binary bin", vkc_binary_enc, vkc_binary_dec, 1}, {"json jsonstring", vkc_json_enc, vkc_json_dec, 1},
    {"deflate", vkc_deflate_raw, vkc_deflate_dec, 0}, {"zlib", vkc_zlib_enc, vkc_zlib_dec, 0}, {"gzip gz", vkc_gzip_enc, vkc_gzip_dec, 0},
    {"zstd zstandard zst", vkc_zstd_enc, vkc_zstd_dec, 0}, {"lz4", vkc_lz4_enc, vkc_lz4_dec, 0}
};
#define VKC_CODEC_COUNT (sizeof(vkc_codecs) / sizeof(vkc_codecs[0]))

static const char *vkc_format_list(void) {
    return "Text: base64, base64url, base32, base32hex, hex, base58, ascii85, url, urlform, html, qp, rot13, rot47, binary, json\n"
           "Compression: deflate, zlib, gzip, zstd, lz4 (binary; chain with a text format, e.g. zstd+base64)\n"
           "Chains apply left to right: decode base64+zstd, encode zstd+base64.";
}
static int vkc_find(const char *name, size_t len) {
    for (size_t i = 0; i < VKC_CODEC_COUNT; i++) {
        const char *c = vkc_codecs[i].names;
        while (*c) {
            const char *end = strchr(c, ' '); size_t l = end ? (size_t)(end - c) : strlen(c);
            if (l == len) { size_t k = 0; while (k < l && (c[k] | 32) == (name[k] | 32)) k++; if (k == l) return (int)i; }
            if (!end) break;
            c = end + 1;
        }
    }
    return -1;
}
/* Applies a chain to the input. On success out->p holds the result. When require_text is set the result must be text. */
static int vkc_transform(int encode, const char *spec, const uint8_t *in, size_t n, int require_text, vkc_buf *out, char *err, size_t errn) {
    int steps[8], count = 0;
    const char *s = spec;
    while (*s) {
        const char *e = strchr(s, '+'); size_t len = e ? (size_t)(e - s) : strlen(s);
        int id = len ? vkc_find(s, len) : -1;
        if (id < 0 || count == 8) { snprintf(err, errn, "Unknown format \"%.*s\". Supported formats:\n%s", (int)len, s, vkc_format_list()); return 0; }
        steps[count++] = id;
        if (!e) break;
        s = e + 1;
    }
    if (!count) { snprintf(err, errn, "Missing format. Supported formats:\n%s", vkc_format_list()); return 0; }
    uint8_t *current = (uint8_t *)malloc(n ? n : 1); size_t current_n = n;
    if (!current) { snprintf(err, errn, "Out of memory."); return 0; }
    if (n) memcpy(current, in, n);
    for (int i = 0; i < count; i++) {
        vkc_buf next = {0};
        const vkc_codec *codec = &vkc_codecs[steps[i]];
        int ok = (encode ? codec->encode : codec->decode)(current, current_n, &next);
        free(current);
        if (!ok || next.fail) { snprintf(err, errn, "%s failed: %s.", encode ? "Encoding" : "Decoding", next.err ? next.err : "invalid data"); vkc_free(&next); return 0; }
        current = next.p ? next.p : (uint8_t *)malloc(1); current_n = next.n;
        if (!current) { snprintf(err, errn, "Out of memory."); return 0; }
    }
    if (require_text) {
        if (memchr(current, 0, current_n)) { free(current); snprintf(err, errn, "The result contains a NUL character, which text cannot hold."); return 0; }
        if (encode && !vkc_codecs[steps[count - 1]].text) { free(current); snprintf(err, errn, "The result is binary; end the chain with a text format, for example %s+base64.", vkc_codecs[steps[count - 1]].names); return 0; }
        if (!encode && !vkc_valid_utf8(current, current_n)) { free(current); snprintf(err, errn, "The decoded data is not valid UTF-8 text."); return 0; }
    }
    out->p = current; out->n = current_n; out->cap = current_n;
    return 1;
}

/* Command line: encode|decode FORMAT [INPUT|-] [OUTPUT|-]. Binary-safe; returns a process exit code. */
static int vkc_cli(int encode, const char *spec, const char *input_path, const char *output_path) {
    FILE *in = (!input_path || !strcmp(input_path, "-")) ? stdin : fopen(input_path, "rb");
    if (!in) { perror(input_path); return 1; }
#ifdef _WIN32
    if (in == stdin) _setmode(_fileno(stdin), _O_BINARY);
#endif
    vkc_buf data = {0}; uint8_t chunk[65536]; size_t got;
    while ((got = fread(chunk, 1, sizeof(chunk), in)) > 0) { vkc_write(&data, chunk, got); if (data.fail) break; }
    int read_error = ferror(in);
    if (in != stdin) fclose(in);
    if (read_error) { fprintf(stderr, "Could not read the input.\n"); vkc_free(&data); return 1; }
    if (data.fail) { fprintf(stderr, "Input error: %s.\n", data.err); vkc_free(&data); return 1; }
    vkc_buf result = {0}; char message[1024];
    int ok = vkc_transform(encode, spec, data.p, data.n, 0, &result, message, sizeof(message));
    vkc_free(&data);
    if (!ok) { fprintf(stderr, "%s\n", message); return 1; }
    FILE *out = (!output_path || !strcmp(output_path, "-")) ? stdout : fopen(output_path, "wb");
    if (!out) { perror(output_path); free(result.p); return 1; }
#ifdef _WIN32
    if (out == stdout) _setmode(_fileno(stdout), _O_BINARY);
#endif
    int good = (!result.n || fwrite(result.p, 1, result.n, out) == result.n) && fflush(out) == 0;
    if (out != stdout && fclose(out) != 0) good = 0;
    free(result.p);
    if (!good) { fprintf(stderr, "Could not write the output.\n"); return 1; }
    return 0;
}

#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic pop
#endif
#endif
