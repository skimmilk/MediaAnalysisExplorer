#include "CAtlasSupport.h"
/* A streaming pass of Apple's observed signed-byte FNV-1a variant. */
uint64_t atlas_signed_fnv(uint64_t seed, const uint8_t *bytes, size_t count) {
    for (size_t i = 0; i < count; ++i) {
        seed ^= (uint64_t)(int64_t)(int8_t)bytes[i];
        seed *= UINT64_C(0x100000001b3);
    }
    return seed;
}
