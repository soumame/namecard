#ifndef NAMECARD_PROTOCOL_H
#define NAMECARD_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define NC_PROTOCOL_MAGIC0 ((uint8_t)'N')
#define NC_PROTOCOL_MAGIC1 ((uint8_t)'C')
#define NC_PROTOCOL_VERSION 1U
#define NC_FRAME_HEADER_SIZE 16U
#define NC_FRAME_MAX_PAYLOAD 240U
#define NC_FRAME_MAX_SIZE 256U
#define NC_IMAGE_WIDTH 296U
#define NC_IMAGE_HEIGHT 128U
#define NC_IMAGE_SIZE 4736U
#define NC_IMAGE_FORMAT_NATIVE_1BPP 1U
#define NC_IMAGE_FORMAT_GRAY4_PLANE 2U
#define NC_GRAY4_PLANE_COUNT 2U
#define NC_TRANSFER_FLAG_BATCH_CLEAN 0x00000001UL
#define NC_TRANSFER_FLAGS_SUPPORTED NC_TRANSFER_FLAG_BATCH_CLEAN
#define NC_PATTERN_CHECKER 1U
#define NC_PATTERN_NFC_OK 2U
#define NC_PATTERN_BLACK 3U
#define NC_PATTERN_WHITE 4U
#define NC_PATTERN_LONG_BARS 5U
#define NC_PATTERN_SHORT_BARS 6U
#define NC_PATTERN_GRID 7U
#define NC_PATTERN_DIAGONAL 8U
#define NC_PATTERN_TARGET 9U
#define NC_PATTERN_TEST_10 10U
#define NC_PATTERN_FIRST NC_PATTERN_CHECKER
#define NC_PATTERN_LAST NC_PATTERN_TEST_10

typedef enum {
    NC_TYPE_START = 0x01,
    NC_TYPE_DATA = 0x02,
    NC_TYPE_COMMIT = 0x03,
    NC_TYPE_STATUS = 0x04,
    NC_TYPE_EXECUTE = 0x05,
    NC_TYPE_PATTERN = 0x06,
    NC_TYPE_ACK = 0x80,
    NC_TYPE_ERROR = 0x81
} nc_frame_type_t;

typedef enum {
    NC_ERROR_NONE = 0,
    NC_ERROR_FRAME_LENGTH = 1,
    NC_ERROR_MAGIC = 2,
    NC_ERROR_VERSION = 3,
    NC_ERROR_HEADER_CRC = 4,
    NC_ERROR_PAYLOAD_CRC = 5,
    NC_ERROR_COMMAND = 6,
    NC_ERROR_TRANSFER_ID = 7,
    NC_ERROR_SEQUENCE = 8,
    NC_ERROR_OFFSET = 9,
    NC_ERROR_IMAGE_FORMAT = 10,
    NC_ERROR_IMAGE_LENGTH = 11,
    NC_ERROR_IMAGE_CRC = 12,
    NC_ERROR_NOT_COMMITTED = 13,
    NC_ERROR_VDD_TIMEOUT = 14,
    NC_ERROR_VDD_DROOP = 15,
    NC_ERROR_EPD_TIMEOUT = 16,
    NC_ERROR_EPD_IO = 17,
    NC_ERROR_NFC_IO = 18,
    NC_ERROR_EXECUTE_ACK_TIMEOUT = 19,
    NC_ERROR_HARDWARE_GATE = 20,
    NC_ERROR_FLASH_STORE = 21
} nc_error_t;

typedef struct {
    uint8_t type;
    uint16_t transfer_id;
    uint16_t sequence;
    uint16_t offset;
    uint16_t payload_length;
    uint16_t payload_crc;
    const uint8_t *payload;
} nc_frame_t;

typedef enum {
    NC_TRANSFER_ACCEPTED = 0,
    NC_TRANSFER_DUPLICATE,
    NC_TRANSFER_STATUS_ONLY,
    NC_TRANSFER_COMMITTED,
    NC_TRANSFER_PATTERN,
    NC_TRANSFER_EXECUTE,
    NC_TRANSFER_REJECTED
} nc_transfer_result_t;

typedef struct {
    bool active;
    bool committed;
    bool execute_requested;
    uint16_t transfer_id;
    uint16_t expected_sequence;
    uint16_t expected_offset;
    uint32_t expected_crc32;
    uint32_t flags;
    uint8_t image_format;
    uint8_t plane_index;
    uint8_t last_type;
    uint16_t last_sequence;
    uint16_t last_offset;
    uint16_t last_payload_length;
    uint16_t last_payload_crc;
    uint8_t pattern_id;
    nc_error_t last_error;
} nc_transfer_t;

typedef struct {
    nc_transfer_result_t result;
    nc_error_t error;
    uint16_t expected_sequence;
    uint16_t expected_offset;
} nc_transfer_reply_t;

void nc_protocol_put_u16(uint8_t *dst, uint16_t value);
void nc_protocol_put_u32(uint8_t *dst, uint32_t value);
uint16_t nc_protocol_get_u16(const uint8_t *src);
uint32_t nc_protocol_get_u32(const uint8_t *src);

nc_error_t nc_frame_parse(const uint8_t *raw, size_t raw_length, nc_frame_t *frame);
size_t nc_frame_build(uint8_t *raw, size_t capacity, uint8_t type,
                      uint16_t transfer_id, uint16_t sequence, uint16_t offset,
                      const uint8_t *payload, uint16_t payload_length);

void nc_transfer_reset(nc_transfer_t *transfer);
nc_transfer_reply_t nc_transfer_apply(nc_transfer_t *transfer,
                                      const nc_frame_t *frame,
                                      uint8_t image[NC_IMAGE_SIZE]);

#endif
