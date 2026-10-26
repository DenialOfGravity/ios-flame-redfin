/* fastrpcd: <endian.h> for Darwin (iOS has none); every target here is little-endian. GPL-3.0-or-later. */
#ifndef FASTRPCD_ENDIAN_H
#define FASTRPCD_ENDIAN_H
#include <stdint.h>
#ifndef le32toh
#define le32toh(x) ((uint32_t)(x))
#define htole32(x) ((uint32_t)(x))
#define le64toh(x) ((uint64_t)(x))
#define htole64(x) ((uint64_t)(x))
#endif
#endif
