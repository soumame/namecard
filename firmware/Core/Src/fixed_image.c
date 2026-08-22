#include "fixed_image.h"

#include <string.h>

#include "nc_protocol.h"

static void set_black(uint8_t *image, uint16_t long_axis, uint8_t short_axis)
{
    if ((long_axis >= NC_IMAGE_WIDTH) || (short_axis >= NC_IMAGE_HEIGHT)) {
        return;
    }
    image[(size_t)long_axis * (NC_IMAGE_HEIGHT / 8U) + (short_axis / 8U)] &=
        (uint8_t)~(0x80U >> (short_axis % 8U));
}

static void draw_glyph(uint8_t *image, uint16_t origin_long,
                       uint8_t origin_short, const uint8_t rows[7],
                       uint8_t scale)
{
    for (uint8_t row = 0U; row < 7U; ++row) {
        for (uint8_t column = 0U; column < 5U; ++column) {
            if ((rows[row] & (uint8_t)(0x10U >> column)) == 0U) {
                continue;
            }
            for (uint8_t dy = 0U; dy < scale; ++dy) {
                for (uint8_t dx = 0U; dx < scale; ++dx) {
                    set_black(image,
                              (uint16_t)(origin_long + column * scale + dx),
                              (uint8_t)(origin_short + row * scale + dy));
                }
            }
        }
    }
}

void fixed_image_make_test_pattern(uint8_t *image)
{
    /* SSD1680 RAM order: 16 bytes across the 128-pixel short axis for each
       of 296 rows. Bit 1 is white, bit 0 is black. */
    for (uint16_t y = 0U; y < NC_IMAGE_WIDTH; ++y) {
        for (uint8_t x_byte = 0U; x_byte < (NC_IMAGE_HEIGHT / 8U); ++x_byte) {
            uint8_t value = 0xFFU;
            const bool border = (y < 4U) || (y >= (NC_IMAGE_WIDTH - 4U)) ||
                                (x_byte == 0U) || (x_byte == 15U);
            if (border) {
                value = 0x00U;
            } else if (((y / 24U) + (x_byte / 2U)) % 2U == 0U) {
                value = 0xAAU;
            }
            image[(size_t)y * 16U + x_byte] = value;
        }
    }
}

void fixed_image_make_nfc_ok_pattern(uint8_t *image)
{
    static const uint8_t glyphs[][7] = {
        {0x11U, 0x19U, 0x15U, 0x13U, 0x11U, 0x11U, 0x11U}, /* N */
        {0x1FU, 0x10U, 0x10U, 0x1EU, 0x10U, 0x10U, 0x10U}, /* F */
        {0x0FU, 0x10U, 0x10U, 0x10U, 0x10U, 0x10U, 0x0FU}, /* C */
        {0x0EU, 0x11U, 0x11U, 0x11U, 0x11U, 0x11U, 0x0EU}, /* O */
        {0x11U, 0x12U, 0x14U, 0x18U, 0x14U, 0x12U, 0x11U}, /* K */
    };
    enum {
        TEXT_SCALE = 6U,
        TEXT_WIDTH = 34U * TEXT_SCALE,
        TEXT_HEIGHT = 7U * TEXT_SCALE
    };

    memset(image, 0xFF, NC_IMAGE_SIZE);
    for (uint16_t x = 0U; x < NC_IMAGE_WIDTH; ++x) {
        set_black(image, x, 1U);
        set_black(image, x, (uint8_t)(NC_IMAGE_HEIGHT - 2U));
    }
    for (uint8_t y = 0U; y < NC_IMAGE_HEIGHT; ++y) {
        set_black(image, 1U, y);
        set_black(image, (uint16_t)(NC_IMAGE_WIDTH - 2U), y);
    }

    uint16_t cursor = (uint16_t)((NC_IMAGE_WIDTH - TEXT_WIDTH) / 2U);
    const uint8_t top = (uint8_t)((NC_IMAGE_HEIGHT - TEXT_HEIGHT) / 2U);
    for (uint8_t index = 0U; index < 5U; ++index) {
        if (index == 3U) {
            cursor = (uint16_t)(cursor + 5U * TEXT_SCALE); /* Space in "NFC OK". */
        }
        draw_glyph(image, cursor, top, glyphs[index], TEXT_SCALE);
        cursor = (uint16_t)(cursor + 6U * TEXT_SCALE);
    }
}

static void make_long_bars(uint8_t *image)
{
    for (uint16_t x = 0U; x < NC_IMAGE_WIDTH; ++x) {
        memset(&image[(size_t)x * 16U], ((x / 12U) & 1U) == 0U ? 0x00 : 0xFF, 16U);
    }
}

static void make_short_bars(uint8_t *image)
{
    for (uint16_t x = 0U; x < NC_IMAGE_WIDTH; ++x) {
        for (uint8_t y = 0U; y < NC_IMAGE_HEIGHT; ++y) {
            if (((y / 8U) & 1U) == 0U) {
                set_black(image, x, y);
            }
        }
    }
}

static void make_grid(uint8_t *image)
{
    for (uint16_t x = 0U; x < NC_IMAGE_WIDTH; ++x) {
        for (uint8_t y = 0U; y < NC_IMAGE_HEIGHT; ++y) {
            if (((x % 24U) < 2U) || ((y % 16U) < 2U)) {
                set_black(image, x, y);
            }
        }
    }
}

static void make_diagonal(uint8_t *image)
{
    for (uint16_t x = 0U; x < NC_IMAGE_WIDTH; ++x) {
        for (uint8_t y = 0U; y < NC_IMAGE_HEIGHT; ++y) {
            if ((((uint16_t)(x + y)) % 32U) < 4U) {
                set_black(image, x, y);
            }
        }
    }
}

static void make_target(uint8_t *image)
{
    for (uint16_t x = 0U; x < NC_IMAGE_WIDTH; ++x) {
        for (uint8_t y = 0U; y < NC_IMAGE_HEIGHT; ++y) {
            const uint16_t dx = x < (NC_IMAGE_WIDTH / 2U)
                                    ? x
                                    : (uint16_t)(NC_IMAGE_WIDTH - 1U - x);
            const uint8_t dy = y < (NC_IMAGE_HEIGHT / 2U)
                                   ? y
                                   : (uint8_t)(NC_IMAGE_HEIGHT - 1U - y);
            if (((dx % 16U) < 2U) || ((dy % 16U) < 2U)) {
                set_black(image, x, y);
            }
        }
    }
}

static void make_test_10(uint8_t *image)
{
    static const uint8_t glyphs[][7] = {
        {0x1FU, 0x04U, 0x04U, 0x04U, 0x04U, 0x04U, 0x04U}, /* T */
        {0x1FU, 0x10U, 0x10U, 0x1EU, 0x10U, 0x10U, 0x1FU}, /* E */
        {0x0FU, 0x10U, 0x10U, 0x0EU, 0x01U, 0x01U, 0x1EU}, /* S */
        {0x1FU, 0x04U, 0x04U, 0x04U, 0x04U, 0x04U, 0x04U}, /* T */
        {0x04U, 0x0CU, 0x04U, 0x04U, 0x04U, 0x04U, 0x0EU}, /* 1 */
        {0x0EU, 0x11U, 0x13U, 0x15U, 0x19U, 0x11U, 0x0EU}, /* 0 */
    };
    enum { SCALE = 5U, GLYPH_ADVANCE = 6U * SCALE };
    static const uint8_t positions[] = {0U, 1U, 2U, 3U, 5U, 6U};

    memset(image, 0xFF, NC_IMAGE_SIZE);
    const uint16_t total_width = 7U * GLYPH_ADVANCE - SCALE;
    const uint16_t origin = (uint16_t)((NC_IMAGE_WIDTH - total_width) / 2U);
    const uint8_t top = (uint8_t)((NC_IMAGE_HEIGHT - 7U * SCALE) / 2U);
    for (uint8_t i = 0U; i < 6U; ++i) {
        draw_glyph(image, (uint16_t)(origin + positions[i] * GLYPH_ADVANCE),
                   top, glyphs[i], SCALE);
    }
}

void fixed_image_make_pattern(uint8_t *image, uint8_t pattern_id)
{
    memset(image, 0xFF, NC_IMAGE_SIZE);
    switch (pattern_id) {
    case NC_PATTERN_CHECKER:
        fixed_image_make_test_pattern(image);
        break;
    case NC_PATTERN_NFC_OK:
        fixed_image_make_nfc_ok_pattern(image);
        break;
    case NC_PATTERN_BLACK:
        memset(image, 0x00, NC_IMAGE_SIZE);
        break;
    case NC_PATTERN_WHITE:
        break;
    case NC_PATTERN_LONG_BARS:
        make_long_bars(image);
        break;
    case NC_PATTERN_SHORT_BARS:
        make_short_bars(image);
        break;
    case NC_PATTERN_GRID:
        make_grid(image);
        break;
    case NC_PATTERN_DIAGONAL:
        make_diagonal(image);
        break;
    case NC_PATTERN_TARGET:
        make_target(image);
        break;
    case NC_PATTERN_TEST_10:
        make_test_10(image);
        break;
    default:
        break;
    }
}
