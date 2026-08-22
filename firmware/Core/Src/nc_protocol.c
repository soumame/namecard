#include "nc_protocol.h"

#include <string.h>

#include "crc.h"

void nc_protocol_put_u16(uint8_t *dst, uint16_t value)
{
    dst[0] = (uint8_t)value;
    dst[1] = (uint8_t)(value >> 8);
}

void nc_protocol_put_u32(uint8_t *dst, uint32_t value)
{
    dst[0] = (uint8_t)value;
    dst[1] = (uint8_t)(value >> 8);
    dst[2] = (uint8_t)(value >> 16);
    dst[3] = (uint8_t)(value >> 24);
}

uint16_t nc_protocol_get_u16(const uint8_t *src)
{
    return (uint16_t)src[0] | ((uint16_t)src[1] << 8);
}

uint32_t nc_protocol_get_u32(const uint8_t *src)
{
    return (uint32_t)src[0] | ((uint32_t)src[1] << 8) |
           ((uint32_t)src[2] << 16) | ((uint32_t)src[3] << 24);
}

static uint16_t header_crc(const uint8_t *raw)
{
    uint16_t crc = nc_crc16_ccitt_update(0xFFFFU, raw, 12U);
    return nc_crc16_ccitt_update(crc, &raw[14], 2U);
}

nc_error_t nc_frame_parse(const uint8_t *raw, size_t raw_length, nc_frame_t *frame)
{
    if ((raw == NULL) || (frame == NULL) || (raw_length < NC_FRAME_HEADER_SIZE) ||
        (raw_length > NC_FRAME_MAX_SIZE)) {
        return NC_ERROR_FRAME_LENGTH;
    }
    if ((raw[0] != NC_PROTOCOL_MAGIC0) || (raw[1] != NC_PROTOCOL_MAGIC1)) {
        return NC_ERROR_MAGIC;
    }
    if (raw[2] != NC_PROTOCOL_VERSION) {
        return NC_ERROR_VERSION;
    }

    const uint16_t payload_length = nc_protocol_get_u16(&raw[10]);
    if ((payload_length > NC_FRAME_MAX_PAYLOAD) ||
        (raw_length != (size_t)NC_FRAME_HEADER_SIZE + payload_length)) {
        return NC_ERROR_FRAME_LENGTH;
    }
    if (header_crc(raw) != nc_protocol_get_u16(&raw[12])) {
        return NC_ERROR_HEADER_CRC;
    }
    if (nc_crc16_ccitt(&raw[NC_FRAME_HEADER_SIZE], payload_length) !=
        nc_protocol_get_u16(&raw[14])) {
        return NC_ERROR_PAYLOAD_CRC;
    }

    frame->type = raw[3];
    frame->transfer_id = nc_protocol_get_u16(&raw[4]);
    frame->sequence = nc_protocol_get_u16(&raw[6]);
    frame->offset = nc_protocol_get_u16(&raw[8]);
    frame->payload_length = payload_length;
    frame->payload_crc = nc_protocol_get_u16(&raw[14]);
    frame->payload = &raw[NC_FRAME_HEADER_SIZE];
    return NC_ERROR_NONE;
}

size_t nc_frame_build(uint8_t *raw, size_t capacity, uint8_t type,
                      uint16_t transfer_id, uint16_t sequence, uint16_t offset,
                      const uint8_t *payload, uint16_t payload_length)
{
    const size_t total = NC_FRAME_HEADER_SIZE + (size_t)payload_length;
    if ((raw == NULL) || (payload_length > NC_FRAME_MAX_PAYLOAD) ||
        (capacity < total) || ((payload == NULL) && (payload_length != 0U))) {
        return 0U;
    }

    raw[0] = NC_PROTOCOL_MAGIC0;
    raw[1] = NC_PROTOCOL_MAGIC1;
    raw[2] = NC_PROTOCOL_VERSION;
    raw[3] = type;
    nc_protocol_put_u16(&raw[4], transfer_id);
    nc_protocol_put_u16(&raw[6], sequence);
    nc_protocol_put_u16(&raw[8], offset);
    nc_protocol_put_u16(&raw[10], payload_length);
    raw[12] = 0U;
    raw[13] = 0U;
    if (payload_length != 0U) {
        memcpy(&raw[NC_FRAME_HEADER_SIZE], payload, payload_length);
    }
    nc_protocol_put_u16(&raw[14], nc_crc16_ccitt(payload, payload_length));
    nc_protocol_put_u16(&raw[12], header_crc(raw));
    return total;
}

void nc_transfer_reset(nc_transfer_t *transfer)
{
    memset(transfer, 0, sizeof(*transfer));
}

static nc_transfer_reply_t reply(const nc_transfer_t *transfer,
                                 nc_transfer_result_t result, nc_error_t error)
{
    nc_transfer_reply_t value = {
        .result = result,
        .error = error,
        .expected_sequence = transfer->expected_sequence,
        .expected_offset = transfer->expected_offset,
    };
    return value;
}

static bool is_duplicate(const nc_transfer_t *transfer, const nc_frame_t *frame)
{
    return (frame->type == transfer->last_type) &&
           (frame->sequence == transfer->last_sequence) &&
           (frame->offset == transfer->last_offset) &&
           (frame->payload_length == transfer->last_payload_length) &&
           (frame->payload_crc == transfer->last_payload_crc);
}

static void remember(nc_transfer_t *transfer, const nc_frame_t *frame)
{
    transfer->last_type = frame->type;
    transfer->last_sequence = frame->sequence;
    transfer->last_offset = frame->offset;
    transfer->last_payload_length = frame->payload_length;
    transfer->last_payload_crc = frame->payload_crc;
}

static nc_transfer_reply_t reject(nc_transfer_t *transfer, nc_error_t error)
{
    transfer->last_error = error;
    return reply(transfer, NC_TRANSFER_REJECTED, error);
}

nc_transfer_reply_t nc_transfer_apply(nc_transfer_t *transfer,
                                      const nc_frame_t *frame,
                                      uint8_t image[NC_IMAGE_SIZE])
{
    if (frame->type == NC_TYPE_STATUS) {
        return reply(transfer, NC_TRANSFER_STATUS_ONLY, NC_ERROR_NONE);
    }

    if (frame->type == NC_TYPE_START) {
        if (is_duplicate(transfer, frame) && transfer->active) {
            return reply(transfer, NC_TRANSFER_DUPLICATE, NC_ERROR_NONE);
        }
        if ((frame->sequence != 0U) || (frame->offset != 0U) ||
            (frame->payload_length != 16U)) {
            return reject(transfer, NC_ERROR_COMMAND);
        }
        if ((nc_protocol_get_u16(&frame->payload[0]) != NC_IMAGE_WIDTH) ||
            (nc_protocol_get_u16(&frame->payload[2]) != NC_IMAGE_HEIGHT) ||
            (nc_protocol_get_u16(&frame->payload[4]) != NC_IMAGE_SIZE) ||
            (frame->payload[6] != NC_IMAGE_FORMAT_NATIVE_1BPP) ||
            (frame->payload[7] != 1U)) {
            return reject(transfer, NC_ERROR_IMAGE_FORMAT);
        }
        nc_transfer_reset(transfer);
        transfer->active = true;
        transfer->transfer_id = frame->transfer_id;
        transfer->expected_sequence = 1U;
        transfer->expected_crc32 = nc_protocol_get_u32(&frame->payload[8]);
        remember(transfer, frame);
        return reply(transfer, NC_TRANSFER_ACCEPTED, NC_ERROR_NONE);
    }

    if (frame->type == NC_TYPE_PATTERN) {
        if (is_duplicate(transfer, frame) && transfer->active) {
            return reply(transfer, NC_TRANSFER_DUPLICATE, NC_ERROR_NONE);
        }
        if ((frame->sequence != 0U) || (frame->offset != 0U) ||
            (frame->payload_length != 1U) ||
            (frame->payload[0] < NC_PATTERN_FIRST) ||
            (frame->payload[0] > NC_PATTERN_LAST)) {
            return reject(transfer, NC_ERROR_COMMAND);
        }
        nc_transfer_reset(transfer);
        transfer->active = true;
        transfer->committed = true;
        transfer->transfer_id = frame->transfer_id;
        transfer->expected_sequence = 1U;
        transfer->expected_offset = NC_IMAGE_SIZE;
        transfer->pattern_id = frame->payload[0];
        remember(transfer, frame);
        return reply(transfer, NC_TRANSFER_PATTERN, NC_ERROR_NONE);
    }

    if (!transfer->active || (frame->transfer_id != transfer->transfer_id)) {
        return reject(transfer, NC_ERROR_TRANSFER_ID);
    }
    if (is_duplicate(transfer, frame)) {
        return reply(transfer, NC_TRANSFER_DUPLICATE, NC_ERROR_NONE);
    }
    if (frame->sequence != transfer->expected_sequence) {
        return reject(transfer, NC_ERROR_SEQUENCE);
    }
    if (frame->offset != transfer->expected_offset) {
        return reject(transfer, NC_ERROR_OFFSET);
    }

    if (frame->type == NC_TYPE_DATA) {
        if ((frame->payload_length == 0U) ||
            ((uint32_t)transfer->expected_offset + frame->payload_length > NC_IMAGE_SIZE)) {
            return reject(transfer, NC_ERROR_IMAGE_LENGTH);
        }
        memcpy(&image[transfer->expected_offset], frame->payload, frame->payload_length);
        transfer->expected_offset = (uint16_t)(transfer->expected_offset + frame->payload_length);
        ++transfer->expected_sequence;
        remember(transfer, frame);
        transfer->last_error = NC_ERROR_NONE;
        return reply(transfer, NC_TRANSFER_ACCEPTED, NC_ERROR_NONE);
    }

    if (frame->type == NC_TYPE_COMMIT) {
        if ((frame->payload_length != 0U) || (transfer->expected_offset != NC_IMAGE_SIZE)) {
            return reject(transfer, NC_ERROR_IMAGE_LENGTH);
        }
        if (nc_crc32_ieee(image, NC_IMAGE_SIZE) != transfer->expected_crc32) {
            return reject(transfer, NC_ERROR_IMAGE_CRC);
        }
        transfer->committed = true;
        ++transfer->expected_sequence;
        remember(transfer, frame);
        transfer->last_error = NC_ERROR_NONE;
        return reply(transfer, NC_TRANSFER_COMMITTED, NC_ERROR_NONE);
    }

    if (frame->type == NC_TYPE_EXECUTE) {
        if (!transfer->committed) {
            return reject(transfer, NC_ERROR_NOT_COMMITTED);
        }
        if (frame->payload_length != 0U) {
            return reject(transfer, NC_ERROR_COMMAND);
        }
        transfer->execute_requested = true;
        ++transfer->expected_sequence;
        remember(transfer, frame);
        transfer->last_error = NC_ERROR_NONE;
        return reply(transfer, NC_TRANSFER_EXECUTE, NC_ERROR_NONE);
    }

    return reject(transfer, NC_ERROR_COMMAND);
}
