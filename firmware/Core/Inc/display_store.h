#ifndef NAMECARD_DISPLAY_STORE_H
#define NAMECARD_DISPLAY_STORE_H

#include <stdbool.h>
#include <stdint.h>

#include "nc_protocol.h"

/* Two 6 KiB slots occupy the final 12 KiB of STM32 Flash. */
void display_store_init(void);

bool display_store_has_committed(void);
const uint8_t *display_store_committed_image(void);
uint16_t display_store_committed_transfer_id(void);
uint16_t display_store_committed_sequence(void);
uint8_t display_store_committed_pattern_id(void);

bool display_store_has_pending(void);
const uint8_t *display_store_pending_image(void);
uint16_t display_store_pending_transfer_id(void);
uint16_t display_store_pending_sequence(void);
uint8_t display_store_pending_pattern_id(void);

bool display_store_stage(const uint8_t image[NC_IMAGE_SIZE],
                         uint16_t transfer_id, uint16_t expected_sequence,
                         uint8_t pattern_id);
bool display_store_commit(void);

#endif
