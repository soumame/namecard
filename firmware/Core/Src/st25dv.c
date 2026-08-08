#include "st25dv.h"

#define ST25DV_USER_I2C_ADDRESS (0x53U << 1)
#define ST25DV_EH_CTRL_DYN 0x2002U
#define ST25DV_MB_CTRL_DYN 0x2006U
#define ST25DV_MB_LEN_DYN 0x2007U
#define ST25DV_MAILBOX 0x2008U
#define ST25DV_I2C_TIMEOUT_MS 20U

static I2C_HandleTypeDef *st25_i2c;

static st25dv_result_t read_register(uint16_t address, uint8_t *data, uint16_t length)
{
    return HAL_I2C_Mem_Read(st25_i2c, ST25DV_USER_I2C_ADDRESS, address,
                            I2C_MEMADD_SIZE_16BIT, data, length,
                            ST25DV_I2C_TIMEOUT_MS) == HAL_OK
               ? ST25DV_OK
               : ST25DV_IO_ERROR;
}

static st25dv_result_t write_register(uint16_t address, const uint8_t *data,
                                     uint16_t length)
{
    return HAL_I2C_Mem_Write(st25_i2c, ST25DV_USER_I2C_ADDRESS, address,
                             I2C_MEMADD_SIZE_16BIT, (uint8_t *)data, length,
                             ST25DV_I2C_TIMEOUT_MS) == HAL_OK
               ? ST25DV_OK
               : ST25DV_IO_ERROR;
}

void st25dv_bind(I2C_HandleTypeDef *i2c)
{
    st25_i2c = i2c;
}

st25dv_result_t st25dv_probe(void)
{
    if (st25_i2c == NULL) {
        return ST25DV_IO_ERROR;
    }
    return HAL_I2C_IsDeviceReady(st25_i2c, ST25DV_USER_I2C_ADDRESS, 2U,
                                 ST25DV_I2C_TIMEOUT_MS) == HAL_OK
               ? ST25DV_OK
               : ST25DV_IO_ERROR;
}

st25dv_result_t st25dv_read_mailbox_control(uint8_t *control)
{
    return read_register(ST25DV_MB_CTRL_DYN, control, 1U);
}

st25dv_result_t st25dv_read_eh_control(uint8_t *control)
{
    return read_register(ST25DV_EH_CTRL_DYN, control, 1U);
}

st25dv_result_t st25dv_enable_mailbox(void)
{
    uint8_t control = 0U;
    st25dv_result_t result = st25dv_read_mailbox_control(&control);
    if (result != ST25DV_OK) {
        return result;
    }
    if ((control & ST25DV_MB_CTRL_MB_EN) != 0U) {
        return ST25DV_OK;
    }
    const uint8_t enable = ST25DV_MB_CTRL_MB_EN;
    return write_register(ST25DV_MB_CTRL_DYN, &enable, 1U);
}

st25dv_result_t st25dv_read_rf_message(uint8_t message[NC_FRAME_MAX_SIZE],
                                      uint16_t *length)
{
    uint8_t control = 0U;
    st25dv_result_t result = st25dv_read_mailbox_control(&control);
    if (result != ST25DV_OK) {
        return result;
    }
    if ((control & ST25DV_MB_CTRL_RF_PUT_MSG) == 0U) {
        return ST25DV_NO_MESSAGE;
    }

    /* ES0616 workaround: MB_CTRL_Dyn is intentionally read before MB_LEN_Dyn.
       A 256-byte RF message can otherwise clear RF_PUT_MSG prematurely. */
    uint8_t encoded_length = 0U;
    result = read_register(ST25DV_MB_LEN_DYN, &encoded_length, 1U);
    if (result != ST25DV_OK) {
        return result;
    }
    const uint16_t message_length = (uint16_t)encoded_length + 1U;
    if (message_length > NC_FRAME_MAX_SIZE) {
        return ST25DV_BUFFER_TOO_SMALL;
    }
    result = read_register(ST25DV_MAILBOX, message, message_length);
    if (result == ST25DV_OK) {
        *length = message_length;
    }
    return result;
}

st25dv_result_t st25dv_write_host_message(const uint8_t *message, uint16_t length)
{
    if ((length == 0U) || (length > NC_FRAME_MAX_SIZE)) {
        return ST25DV_BUFFER_TOO_SMALL;
    }
    uint8_t control = 0U;
    st25dv_result_t result = st25dv_read_mailbox_control(&control);
    if (result != ST25DV_OK) {
        return result;
    }
    if (((control & ST25DV_MB_CTRL_MB_EN) == 0U) ||
        ((control & (ST25DV_MB_CTRL_HOST_PUT_MSG | ST25DV_MB_CTRL_RF_PUT_MSG)) != 0U)) {
        return ST25DV_MAILBOX_BUSY;
    }
    result = write_register(ST25DV_MAILBOX, message, length);
    if (result == ST25DV_OK) {
        /* ES0616 1.6.1: the next I2C stop starts the FTM watchdog. */
        (void)HAL_I2C_IsDeviceReady(st25_i2c, ST25DV_USER_I2C_ADDRESS, 1U, 2U);
    }
    return result;
}
