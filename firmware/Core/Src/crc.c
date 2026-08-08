#include "crc.h"

uint16_t nc_crc16_ccitt_update(uint16_t crc, const uint8_t *data, size_t length)
{
    for (size_t i = 0; i < length; ++i) {
        crc ^= (uint16_t)data[i] << 8;
        for (uint8_t bit = 0; bit < 8U; ++bit) {
            crc = (crc & 0x8000U) != 0U
                      ? (uint16_t)((crc << 1) ^ 0x1021U)
                      : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

uint16_t nc_crc16_ccitt(const uint8_t *data, size_t length)
{
    return nc_crc16_ccitt_update(0xFFFFU, data, length);
}

uint32_t nc_crc32_ieee(const uint8_t *data, size_t length)
{
    uint32_t crc = 0xFFFFFFFFUL;
    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (uint8_t bit = 0; bit < 8U; ++bit) {
            const uint32_t mask = (uint32_t)-(int32_t)(crc & 1U);
            crc = (crc >> 1) ^ (0xEDB88320UL & mask);
        }
    }
    return crc ^ 0xFFFFFFFFUL;
}
