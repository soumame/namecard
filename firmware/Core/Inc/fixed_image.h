#ifndef NAMECARD_FIXED_IMAGE_H
#define NAMECARD_FIXED_IMAGE_H

#include <stdint.h>

void fixed_image_make_test_pattern(uint8_t *image);
void fixed_image_make_nfc_ok_pattern(uint8_t *image);
void fixed_image_make_fw_ok_pattern(uint8_t *image);
void fixed_image_make_pattern(uint8_t *image, uint8_t pattern_id);

#endif
