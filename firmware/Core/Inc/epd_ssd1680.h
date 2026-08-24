#ifndef NAMECARD_EPD_SSD1680_H
#define NAMECARD_EPD_SSD1680_H

#include <stdbool.h>
#include <stdint.h>

#include "main.h"
#include "nc_protocol.h"

typedef enum {
    EPD_OK = 0,
    EPD_IO_ERROR,
    EPD_BUSY_TIMEOUT,
    EPD_VDD_DROOP
} epd_result_t;

void epd_ssd1680_bind(SPI_HandleTypeDef *spi);
epd_result_t epd_ssd1680_initialize(void);
epd_result_t epd_ssd1680_initialize_gray4(void);
epd_result_t epd_ssd1680_finish_gray4_initialization(void);
epd_result_t epd_ssd1680_write_frame(const uint8_t image[NC_IMAGE_SIZE]);
epd_result_t epd_ssd1680_write_previous_frame(const uint8_t image[NC_IMAGE_SIZE]);
epd_result_t epd_ssd1680_write_solid(uint8_t value);
epd_result_t epd_ssd1680_write_frame_prefix(const uint8_t image[NC_IMAGE_SIZE],
                                             uint16_t rows);
epd_result_t epd_ssd1680_write_previous_frame_prefix(
    const uint8_t image[NC_IMAGE_SIZE], uint16_t rows);
epd_result_t epd_ssd1680_write_previous_solid(uint8_t value);
epd_result_t epd_ssd1680_write_gray4_band(
    const uint8_t plane0[NC_IMAGE_SIZE], const uint8_t plane1[NC_IMAGE_SIZE],
    uint16_t first_row, uint16_t rows);
epd_result_t epd_ssd1680_prepare_partial(void);
epd_result_t epd_ssd1680_start_full(void);
epd_result_t epd_ssd1680_start_partial(void);
epd_result_t epd_ssd1680_start_gray4(void);
epd_result_t epd_ssd1680_wait_ready(uint32_t timeout_ms, bool sample_vdd);
void epd_ssd1680_deep_sleep(void);

#endif
