#include "fixed_image.h"

#include "nc_protocol.h"

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
