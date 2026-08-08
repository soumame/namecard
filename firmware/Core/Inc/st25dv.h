#ifndef NAMECARD_ST25DV_H
#define NAMECARD_ST25DV_H

#include <stdbool.h>
#include <stdint.h>

#include "main.h"
#include "nc_protocol.h"

#define ST25DV_MB_CTRL_MB_EN 0x01U
#define ST25DV_MB_CTRL_HOST_PUT_MSG 0x02U
#define ST25DV_MB_CTRL_RF_PUT_MSG 0x04U

typedef enum {
    ST25DV_OK = 0,
    ST25DV_NO_MESSAGE,
    ST25DV_MAILBOX_BUSY,
    ST25DV_BUFFER_TOO_SMALL,
    ST25DV_IO_ERROR
} st25dv_result_t;

void st25dv_bind(I2C_HandleTypeDef *i2c);
st25dv_result_t st25dv_probe(void);
st25dv_result_t st25dv_enable_mailbox(void);
st25dv_result_t st25dv_read_mailbox_control(uint8_t *control);
st25dv_result_t st25dv_read_eh_control(uint8_t *control);
st25dv_result_t st25dv_read_rf_message(uint8_t message[NC_FRAME_MAX_SIZE],
                                      uint16_t *length);
st25dv_result_t st25dv_write_host_message(const uint8_t *message, uint16_t length);

#endif
