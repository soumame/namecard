#include "st25dv.h"

#define ST25DV_USER_I2C_ADDRESS (0x53U << 1)
#define ST25DV_SYSTEM_I2C_ADDRESS (0x57U << 1)
#define ST25DV_EH_MODE 0x0002U
#define ST25DV_FTM 0x000DU
#define ST25DV_EH_CTRL_DYN 0x2002U
#define ST25DV_I2C_SSO_DYN 0x2004U
#define ST25DV_MB_CTRL_DYN 0x2006U
#define ST25DV_MB_LEN_DYN 0x2007U
#define ST25DV_MAILBOX 0x2008U
#define ST25DV_I2C_TIMEOUT_MS 20U
#define ST25DV_I2C_ATTEMPTS 3U

static I2C_HandleTypeDef *st25_i2c;

static st25dv_result_t read_register_at(uint16_t device, uint16_t address,
                                       uint8_t *data, uint16_t length)
{
    for (uint32_t attempt = 0U; attempt < ST25DV_I2C_ATTEMPTS; ++attempt) {
        if (HAL_I2C_Mem_Read(st25_i2c, device, address,
                             I2C_MEMADD_SIZE_16BIT, data, length,
                             ST25DV_I2C_TIMEOUT_MS) == HAL_OK) {
            return ST25DV_OK;
        }
        if ((attempt + 1U) < ST25DV_I2C_ATTEMPTS) {
            HAL_Delay(1U);
        }
    }
    return ST25DV_IO_ERROR;
}

static st25dv_result_t read_register(uint16_t address, uint8_t *data,
                                     uint16_t length)
{
    return read_register_at(ST25DV_USER_I2C_ADDRESS, address, data, length);
}

static st25dv_result_t write_register_at(uint16_t device, uint16_t address,
                                        const uint8_t *data, uint16_t length)
{
    for (uint32_t attempt = 0U; attempt < ST25DV_I2C_ATTEMPTS; ++attempt) {
        if (HAL_I2C_Mem_Write(st25_i2c, device, address,
                              I2C_MEMADD_SIZE_16BIT, (uint8_t *)data, length,
                              ST25DV_I2C_TIMEOUT_MS) == HAL_OK) {
            return ST25DV_OK;
        }
        if ((attempt + 1U) < ST25DV_I2C_ATTEMPTS) {
            HAL_Delay(1U);
        }
    }
    return ST25DV_IO_ERROR;
}

static st25dv_result_t write_register(uint16_t address, const uint8_t *data,
                                      uint16_t length)
{
    return write_register_at(ST25DV_USER_I2C_ADDRESS, address, data, length);
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

st25dv_result_t st25dv_factory_enable_eh_at_boot(void)
{
    uint8_t eh_mode = 0xFFU;
    uint8_t ftm = 0U;
    if (read_register_at(ST25DV_SYSTEM_I2C_ADDRESS, ST25DV_EH_MODE,
                         &eh_mode, 1U) != ST25DV_OK ||
        read_register_at(ST25DV_SYSTEM_I2C_ADDRESS, ST25DV_FTM,
                         &ftm, 1U) != ST25DV_OK) {
        return ST25DV_IO_ERROR;
    }
    if ((eh_mode == 0U) && ((ftm & 0x01U) != 0U)) {
        return ST25DV_OK;
    }

    /* I2C Present Password: address 0900h, password MSB first, validation
       code 09h, then the same password again. Factory password is all zero. */
    uint8_t present_password[19] = {0};
    present_password[0] = 0x09U;
    present_password[1] = 0x00U;
    present_password[10] = 0x09U;
    if (HAL_I2C_Master_Transmit(st25_i2c, ST25DV_SYSTEM_I2C_ADDRESS,
                                present_password, sizeof(present_password),
                                ST25DV_I2C_TIMEOUT_MS) != HAL_OK) {
        return ST25DV_IO_ERROR;
    }

    uint8_t security = 0U;
    if ((read_register(ST25DV_I2C_SSO_DYN, &security, 1U) != ST25DV_OK) ||
        ((security & 0x01U) == 0U)) {
        return ST25DV_IO_ERROR;
    }
    if (eh_mode != 0U) {
        eh_mode = 0U;
        if (write_register_at(ST25DV_SYSTEM_I2C_ADDRESS, ST25DV_EH_MODE,
                              &eh_mode, 1U) != ST25DV_OK ||
            HAL_I2C_IsDeviceReady(st25_i2c, ST25DV_SYSTEM_I2C_ADDRESS, 20U,
                                  ST25DV_I2C_TIMEOUT_MS) != HAL_OK) {
            return ST25DV_IO_ERROR;
        }
    }

    /* FTM.MB_MODE is a nonvolatile authorization bit. A fresh KC device
     * ships with it clear; MB_CTRL_Dyn.MB_EN cannot be set until this bit is
     * programmed. Preserve the watchdog selection in bits 3:1. */
    if ((ftm & 0x01U) == 0U) {
        ftm |= 0x01U;
        if (write_register_at(ST25DV_SYSTEM_I2C_ADDRESS, ST25DV_FTM,
                              &ftm, 1U) != ST25DV_OK ||
            HAL_I2C_IsDeviceReady(st25_i2c, ST25DV_SYSTEM_I2C_ADDRESS, 20U,
                                  ST25DV_I2C_TIMEOUT_MS) != HAL_OK) {
            return ST25DV_IO_ERROR;
        }
    }

    eh_mode = 0xFFU;
    ftm = 0U;
    return (read_register_at(ST25DV_SYSTEM_I2C_ADDRESS, ST25DV_EH_MODE,
                             &eh_mode, 1U) == ST25DV_OK) &&
                   (read_register_at(ST25DV_SYSTEM_I2C_ADDRESS, ST25DV_FTM,
                                     &ftm, 1U) == ST25DV_OK) &&
                   (eh_mode == 0U) && ((ftm & 0x01U) != 0U)
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

st25dv_result_t st25dv_disable_mailbox(void)
{
    const uint8_t disable = 0U;
    return write_register(ST25DV_MB_CTRL_DYN, &disable, 1U);
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
