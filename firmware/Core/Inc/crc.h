#ifndef NAMECARD_CRC_H
#define NAMECARD_CRC_H

#include <stddef.h>
#include <stdint.h>

uint16_t nc_crc16_ccitt(const uint8_t *data, size_t length);
uint16_t nc_crc16_ccitt_update(uint16_t crc, const uint8_t *data, size_t length);
uint32_t nc_crc32_ieee(const uint8_t *data, size_t length);

#endif
