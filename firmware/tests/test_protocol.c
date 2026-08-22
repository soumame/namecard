#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "crc.h"
#include "fixed_image.h"
#include "nc_protocol.h"

static uint8_t raw[NC_FRAME_MAX_SIZE];
static uint8_t image[NC_IMAGE_SIZE];
static uint8_t received[NC_IMAGE_SIZE];

static nc_frame_t make_frame(uint8_t type, uint16_t transfer_id,
                             uint16_t sequence, uint16_t offset,
                             const uint8_t *payload, uint16_t payload_length)
{
    const size_t length = nc_frame_build(raw, sizeof(raw), type, transfer_id,
                                         sequence, offset, payload, payload_length);
    assert(length != 0U);
    nc_frame_t frame;
    assert(nc_frame_parse(raw, length, &frame) == NC_ERROR_NONE);
    return frame;
}

static void test_crc_and_frame(void)
{
    static const uint8_t check[] = "123456789";
    assert(nc_crc16_ccitt(check, 9U) == 0x29B1U);
    assert(nc_crc32_ieee(check, 9U) == 0xCBF43926UL);

    const uint8_t payload[] = {1U, 2U, 3U};
    const size_t length = nc_frame_build(raw, sizeof(raw), NC_TYPE_DATA, 7U,
                                         4U, 240U, payload, sizeof(payload));
    assert(length == NC_FRAME_HEADER_SIZE + sizeof(payload));
    nc_frame_t frame;
    assert(nc_frame_parse(raw, length, &frame) == NC_ERROR_NONE);
    assert(frame.transfer_id == 7U && frame.sequence == 4U && frame.offset == 240U);
    raw[0] ^= 1U;
    assert(nc_frame_parse(raw, length, &frame) == NC_ERROR_MAGIC);
    raw[0] ^= 1U;
    raw[4] ^= 1U;
    assert(nc_frame_parse(raw, length, &frame) == NC_ERROR_HEADER_CRC);
    raw[4] ^= 1U;
    raw[16] ^= 1U;
    assert(nc_frame_parse(raw, length, &frame) == NC_ERROR_PAYLOAD_CRC);
}

static void start_transfer(nc_transfer_t *transfer, uint32_t crc)
{
    uint8_t start[16] = {0};
    nc_protocol_put_u16(&start[0], NC_IMAGE_WIDTH);
    nc_protocol_put_u16(&start[2], NC_IMAGE_HEIGHT);
    nc_protocol_put_u16(&start[4], NC_IMAGE_SIZE);
    start[6] = NC_IMAGE_FORMAT_NATIVE_1BPP;
    start[7] = 1U;
    nc_protocol_put_u32(&start[8], crc);
    nc_frame_t frame = make_frame(NC_TYPE_START, 0x1234U, 0U, 0U,
                                  start, sizeof(start));
    nc_transfer_reply_t reply = nc_transfer_apply(transfer, &frame, received);
    assert(reply.result == NC_TRANSFER_ACCEPTED);
    reply = nc_transfer_apply(transfer, &frame, received);
    assert(reply.result == NC_TRANSFER_DUPLICATE);
}

static void test_complete_transfer(void)
{
    for (size_t i = 0U; i < sizeof(image); ++i) {
        image[i] = (uint8_t)(i * 37U + 11U);
    }
    nc_transfer_t transfer;
    nc_transfer_reset(&transfer);
    start_transfer(&transfer, nc_crc32_ieee(image, sizeof(image)));

    uint16_t sequence = 1U;
    uint16_t offset = 0U;
    while (offset < NC_IMAGE_SIZE) {
        const uint16_t remaining = (uint16_t)(NC_IMAGE_SIZE - offset);
        const uint16_t chunk = remaining > NC_FRAME_MAX_PAYLOAD
                                   ? NC_FRAME_MAX_PAYLOAD
                                   : remaining;
        nc_frame_t frame = make_frame(NC_TYPE_DATA, 0x1234U, sequence,
                                      offset, &image[offset], chunk);
        nc_transfer_reply_t reply = nc_transfer_apply(&transfer, &frame, received);
        assert(reply.result == NC_TRANSFER_ACCEPTED);
        if (sequence == 10U) {
            reply = nc_transfer_apply(&transfer, &frame, received);
            assert(reply.result == NC_TRANSFER_DUPLICATE);
        }
        offset = (uint16_t)(offset + chunk);
        ++sequence;
    }
    assert(sequence == 21U && offset == NC_IMAGE_SIZE);
    assert(memcmp(image, received, sizeof(image)) == 0);

    nc_frame_t frame = make_frame(NC_TYPE_COMMIT, 0x1234U, sequence,
                                  offset, NULL, 0U);
    nc_transfer_reply_t reply = nc_transfer_apply(&transfer, &frame, received);
    assert(reply.result == NC_TRANSFER_COMMITTED);
    reply = nc_transfer_apply(&transfer, &frame, received);
    assert(reply.result == NC_TRANSFER_DUPLICATE);

    frame = make_frame(NC_TYPE_EXECUTE, 0x1234U, (uint16_t)(sequence + 1U),
                       offset, NULL, 0U);
    reply = nc_transfer_apply(&transfer, &frame, received);
    assert(reply.result == NC_TRANSFER_EXECUTE);
}

static void test_rejections_and_restart(void)
{
    memset(image, 0xA5, sizeof(image));
    nc_transfer_t transfer;
    nc_transfer_reset(&transfer);
    start_transfer(&transfer, nc_crc32_ieee(image, sizeof(image)));

    nc_frame_t wrong = make_frame(NC_TYPE_DATA, 0x1234U, 2U, 0U,
                                  image, NC_FRAME_MAX_PAYLOAD);
    nc_transfer_reply_t reply = nc_transfer_apply(&transfer, &wrong, received);
    assert(reply.result == NC_TRANSFER_REJECTED);
    assert(reply.error == NC_ERROR_SEQUENCE);
    assert(reply.expected_sequence == 1U && reply.expected_offset == 0U);

    wrong = make_frame(NC_TYPE_DATA, 0x1234U, 1U, 1U,
                       image, NC_FRAME_MAX_PAYLOAD);
    reply = nc_transfer_apply(&transfer, &wrong, received);
    assert(reply.error == NC_ERROR_OFFSET);

    nc_frame_t accepted = make_frame(NC_TYPE_DATA, 0x1234U, 1U, 0U,
                                     image, NC_FRAME_MAX_PAYLOAD);
    reply = nc_transfer_apply(&transfer, &accepted, received);
    assert(reply.result == NC_TRANSFER_ACCEPTED);

    /* A fresh START is the only recovery after RAM loss or an abandoned session. */
    start_transfer(&transfer, nc_crc32_ieee(image, sizeof(image)));
    assert(transfer.expected_sequence == 1U && transfer.expected_offset == 0U);
}

static void test_image_crc_rejection(void)
{
    memset(image, 0x3CU, sizeof(image));
    nc_transfer_t transfer;
    nc_transfer_reset(&transfer);
    start_transfer(&transfer, nc_crc32_ieee(image, sizeof(image)) ^ 1U);

    uint16_t sequence = 1U;
    uint16_t offset = 0U;
    while (offset < NC_IMAGE_SIZE) {
        const uint16_t remaining = (uint16_t)(NC_IMAGE_SIZE - offset);
        const uint16_t chunk = remaining > NC_FRAME_MAX_PAYLOAD
                                   ? NC_FRAME_MAX_PAYLOAD
                                   : remaining;
        nc_frame_t data = make_frame(NC_TYPE_DATA, 0x1234U, sequence++, offset,
                                     &image[offset], chunk);
        assert(nc_transfer_apply(&transfer, &data, received).result ==
               NC_TRANSFER_ACCEPTED);
        offset = (uint16_t)(offset + chunk);
    }
    nc_frame_t commit = make_frame(NC_TYPE_COMMIT, 0x1234U, sequence,
                                   offset, NULL, 0U);
    nc_transfer_reply_t reply = nc_transfer_apply(&transfer, &commit, received);
    assert(reply.result == NC_TRANSFER_REJECTED);
    assert(reply.error == NC_ERROR_IMAGE_CRC);
    assert(!transfer.committed);
}

static void test_builtin_pattern_transfer(void)
{
    nc_transfer_t transfer;
    nc_transfer_reset(&transfer);
    const uint8_t pattern[] = {NC_PATTERN_NFC_OK};
    nc_frame_t frame = make_frame(NC_TYPE_PATTERN, 0x4321U, 0U, 0U,
                                  pattern, sizeof(pattern));
    nc_transfer_reply_t reply = nc_transfer_apply(&transfer, &frame, received);
    assert(reply.result == NC_TRANSFER_PATTERN);
    assert(transfer.active && transfer.committed);
    assert(transfer.pattern_id == NC_PATTERN_NFC_OK);
    assert(reply.expected_sequence == 1U && reply.expected_offset == NC_IMAGE_SIZE);

    reply = nc_transfer_apply(&transfer, &frame, received);
    assert(reply.result == NC_TRANSFER_DUPLICATE);

    frame = make_frame(NC_TYPE_EXECUTE, 0x4321U, 1U, NC_IMAGE_SIZE,
                       NULL, 0U);
    reply = nc_transfer_apply(&transfer, &frame, received);
    assert(reply.result == NC_TRANSFER_EXECUTE);

    const uint8_t invalid[] = {0xFFU};
    frame = make_frame(NC_TYPE_PATTERN, 0x2222U, 0U, 0U,
                       invalid, sizeof(invalid));
    reply = nc_transfer_apply(&transfer, &frame, received);
    assert(reply.result == NC_TRANSFER_REJECTED);
    assert(reply.error == NC_ERROR_COMMAND);

    for (uint8_t id = NC_PATTERN_FIRST; id <= NC_PATTERN_LAST; ++id) {
        nc_transfer_reset(&transfer);
        frame = make_frame(NC_TYPE_PATTERN, (uint16_t)(0x5000U + id),
                           0U, 0U, &id, 1U);
        reply = nc_transfer_apply(&transfer, &frame, received);
        assert(reply.result == NC_TRANSFER_PATTERN);
        assert(transfer.pattern_id == id);
    }

    const uint8_t too_low[] = {0U};
    frame = make_frame(NC_TYPE_PATTERN, 0x6000U, 0U, 0U,
                       too_low, sizeof(too_low));
    assert(nc_transfer_apply(&transfer, &frame, received).error == NC_ERROR_COMMAND);

    const uint8_t too_high[] = {NC_PATTERN_LAST + 1U};
    frame = make_frame(NC_TYPE_PATTERN, 0x6001U, 0U, 0U,
                       too_high, sizeof(too_high));
    assert(nc_transfer_apply(&transfer, &frame, received).error == NC_ERROR_COMMAND);
}

static void test_nfc_ok_pattern_pixels(void)
{
    fixed_image_make_nfc_ok_pattern(image);
    assert(nc_crc32_ieee(image, sizeof(image)) == 0xBF59E395UL);
    size_t black = 0U;
    size_t white = 0U;
    for (size_t index = 0U; index < sizeof(image); ++index) {
        for (uint8_t bit = 0U; bit < 8U; ++bit) {
            if ((image[index] & (uint8_t)(0x80U >> bit)) == 0U) {
                ++black;
            } else {
                ++white;
            }
        }
    }
    assert(black > 2000U);
    assert(white > black);
}

static void test_all_pattern_images_are_distinct(void)
{
    uint32_t crc[NC_PATTERN_LAST];
    for (uint8_t id = NC_PATTERN_FIRST; id <= NC_PATTERN_LAST; ++id) {
        fixed_image_make_pattern(image, id);
        crc[id - 1U] = nc_crc32_ieee(image, sizeof(image));
        for (uint8_t previous = NC_PATTERN_FIRST; previous < id; ++previous) {
            assert(crc[id - 1U] != crc[previous - 1U]);
        }
    }
}

int main(void)
{
    test_crc_and_frame();
    test_complete_transfer();
    test_rejections_and_restart();
    test_image_crc_rejection();
    test_builtin_pattern_transfer();
    test_nfc_ok_pattern_pixels();
    test_all_pattern_images_are_distinct();
    puts("protocol tests passed");
    return 0;
}
