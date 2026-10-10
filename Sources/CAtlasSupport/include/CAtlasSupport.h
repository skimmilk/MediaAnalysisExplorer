#ifndef C_ATLAS_SUPPORT_H
#define C_ATLAS_SUPPORT_H
#include <stddef.h>
#include <stdint.h>
uint64_t atlas_signed_fnv(uint64_t seed, const uint8_t *bytes, size_t count);
#endif
