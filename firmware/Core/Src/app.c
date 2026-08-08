#include "app.h"

#include <stdbool.h>
#include <string.h>

#include "board.h"
#include "epd_ssd1680.h"
#include "fixed_image.h"
#include "main.h"
#include "nc_protocol.h"
#include "power_monitor.h"
#include "st25dv.h"

#define CHARGE_READY_MV ((uint16_t)NAMECARD_CHARGE_READY_MV)
#define EPD_ON_MIN_MV ((uint16_t)NAMECARD_EPD_ON_MIN_MV)
#define EPD_START_MIN_MV ((uint16_t)NAMECARD_EPD_START_MIN_MV)
#define NFC_FIXED_BAND_ROWS ((uint16_t)NAMECARD_NFC_BAND_ROWS)
#define CHARGE_STABLE_MS 100U
#define CHARGE_TIMEOUT_MS ((uint32_t)NAMECARD_CHARGE_TIMEOUT_MS)
#define EXECUTE_ACK_TIMEOUT_MS 1000U
#define EXECUTE_QUIET_GUARD_MS 100U
#define CLIENT_RF_QUIET_MS 2000U
#define MAILBOX_POLL_MS 5U

typedef enum {
    ACK_OK = 0,
    ACK_DUPLICATE = 1,
    ACK_STATUS = 2,
    ACK_CHARGING = 3,
    ACK_READY = 4,
    ACK_ERROR = 0x80
} ack_code_t;

static uint8_t image_buffer[NC_IMAGE_SIZE];
#if !NAMECARD_NFC_FIXED_TEST
static uint8_t mailbox_buffer[NC_FRAME_MAX_SIZE];
#endif
static nc_transfer_t transfer;
static app_state_t current_state;
static nc_error_t current_error;
static uint16_t current_vdd_mv;
static uint8_t eh_control;
static uint32_t charge_started_at;
static uint32_t stable_started_at;
static uint32_t last_power_sample_at;
#if !NAMECARD_NFC_FIXED_TEST
static uint32_t last_mailbox_poll_at;
#endif
static uint32_t execute_ack_started_at;
static uint32_t execute_ack_read_at;
static bool execute_ack_was_read;
static bool mailbox_enabled;
#if NAMECARD_NFC_FIXED_TEST
static uint16_t fixed_completed_rows;
#endif

static void set_error(nc_error_t error)
{
    board_epd_power_off();
    current_error = error;
    current_state = APP_STATE_ERROR;
}

#if !NAMECARD_NFC_FIXED_TEST
static uint8_t reply_code(nc_transfer_reply_t reply)
{
    if (reply.result == NC_TRANSFER_REJECTED) return ACK_ERROR;
    if (reply.result == NC_TRANSFER_DUPLICATE) return ACK_DUPLICATE;
    if (current_state == APP_STATE_CHARGING) return ACK_CHARGING;
    if (current_state == APP_STATE_READY) return ACK_READY;
    if (reply.result == NC_TRANSFER_STATUS_ONLY) return ACK_STATUS;
    return ACK_OK;
}

static bool send_reply(const nc_frame_t *request, nc_transfer_reply_t reply,
                       uint16_t quiet_ms)
{
    uint8_t payload[16] = {0};
    payload[0] = request->type;
    payload[1] = reply_code(reply);
    payload[2] = (uint8_t)current_state;
    payload[3] = (uint8_t)(reply.error != NC_ERROR_NONE ? reply.error : current_error);
    nc_protocol_put_u16(&payload[4], reply.expected_sequence);
    nc_protocol_put_u16(&payload[6], reply.expected_offset);
    current_vdd_mv = power_monitor_read_vdd_mv();
    nc_protocol_put_u16(&payload[8], current_vdd_mv);
    nc_protocol_put_u16(&payload[10], power_monitor_minimum_mv());
    nc_protocol_put_u16(&payload[12], quiet_ms);
    payload[14] = eh_control;
    payload[15] = mailbox_enabled ? 1U : 0U;

    const uint8_t response_type = reply.result == NC_TRANSFER_REJECTED
                                      ? NC_TYPE_ERROR
                                      : NC_TYPE_ACK;
    const size_t length = nc_frame_build(mailbox_buffer, sizeof(mailbox_buffer),
                                         response_type, request->transfer_id,
                                         request->sequence, reply.expected_offset,
                                         payload, sizeof(payload));
    return (length != 0U) &&
           (st25dv_write_host_message(mailbox_buffer, (uint16_t)length) == ST25DV_OK);
}

static nc_transfer_reply_t rejected(nc_error_t error)
{
    nc_transfer_reply_t value = {
        .result = NC_TRANSFER_REJECTED,
        .error = error,
        .expected_sequence = transfer.expected_sequence,
        .expected_offset = transfer.expected_offset,
    };
    return value;
}

static nc_transfer_reply_t status_reply(void)
{
    nc_transfer_reply_t value = {
        .result = NC_TRANSFER_STATUS_ONLY,
        .error = current_error,
        .expected_sequence = transfer.expected_sequence,
        .expected_offset = transfer.expected_offset,
    };
    return value;
}

static void handle_message(void)
{
    uint16_t raw_length = 0U;
    const st25dv_result_t read_result =
        st25dv_read_rf_message(mailbox_buffer, &raw_length);
    if (read_result == ST25DV_NO_MESSAGE) {
        return;
    }
    if (read_result != ST25DV_OK) {
        current_error = NC_ERROR_NFC_IO;
        return;
    }

    nc_frame_t frame = {0};
    const nc_error_t parse_error = nc_frame_parse(mailbox_buffer, raw_length, &frame);
    if (parse_error != NC_ERROR_NONE) {
        /* The transfer id and sequence are safe to use only after basic length
           checks; an invalid frame is otherwise answered with zero correlation. */
        frame.type = raw_length >= 4U ? mailbox_buffer[3] : 0U;
        frame.transfer_id = raw_length >= 6U ? nc_protocol_get_u16(&mailbox_buffer[4]) : 0U;
        frame.sequence = raw_length >= 8U ? nc_protocol_get_u16(&mailbox_buffer[6]) : 0U;
        (void)send_reply(&frame, rejected(parse_error), 0U);
        return;
    }

    if (frame.type == NC_TYPE_STATUS) {
        (void)st25dv_read_eh_control(&eh_control);
        (void)send_reply(&frame, status_reply(),
                         current_state == APP_STATE_REFRESHING ? CLIENT_RF_QUIET_MS : 0U);
        return;
    }

    if ((frame.type == NC_TYPE_EXECUTE) && (current_state != APP_STATE_READY)) {
        if (transfer.committed && (current_state == APP_STATE_CHARGING)) {
            (void)send_reply(&frame, status_reply(), 0U);
        } else {
            (void)send_reply(&frame, rejected(NC_ERROR_NOT_COMMITTED), 0U);
        }
        return;
    }

    nc_transfer_reply_t reply = nc_transfer_apply(&transfer, &frame, image_buffer);
    if (reply.result == NC_TRANSFER_REJECTED) {
        current_error = reply.error;
        (void)send_reply(&frame, reply, 0U);
        return;
    }

    current_error = NC_ERROR_NONE;
    if (frame.type == NC_TYPE_START) {
        current_state = APP_STATE_RECEIVING;
        power_monitor_reset_minimum();
    } else if (reply.result == NC_TRANSFER_COMMITTED) {
        current_state = APP_STATE_CHARGING;
        charge_started_at = HAL_GetTick();
        stable_started_at = 0U;
    } else if (reply.result == NC_TRANSFER_EXECUTE) {
        current_state = APP_STATE_EXECUTE_ACK;
    }

    const uint16_t quiet = reply.result == NC_TRANSFER_EXECUTE
                               ? CLIENT_RF_QUIET_MS
                               : 0U;
    if (!send_reply(&frame, reply, quiet)) {
        set_error(NC_ERROR_NFC_IO);
        return;
    }
    if (reply.result == NC_TRANSFER_EXECUTE) {
        execute_ack_started_at = HAL_GetTick();
        execute_ack_was_read = false;
        execute_ack_read_at = 0U;
    }
}
#endif

static bool wait_charge_ready(void)
{
    const uint32_t now = HAL_GetTick();
    if ((now - last_power_sample_at) < 20U) {
        return false;
    }
    last_power_sample_at = now;
    current_vdd_mv = power_monitor_sample_minimum();
    (void)st25dv_read_eh_control(&eh_control);

    if (current_vdd_mv >= CHARGE_READY_MV) {
        if (stable_started_at == 0U) {
            stable_started_at = now;
        }
        if ((now - stable_started_at) >= CHARGE_STABLE_MS) {
            return true;
        }
    } else {
        stable_started_at = 0U;
    }

    if ((now - charge_started_at) >= CHARGE_TIMEOUT_MS) {
        set_error(NC_ERROR_VDD_TIMEOUT);
    }
    return false;
}

static void finish_epd_failure(epd_result_t result)
{
    epd_ssd1680_deep_sleep();
    board_epd_power_off();
    set_error(result == EPD_BUSY_TIMEOUT ? NC_ERROR_EPD_TIMEOUT : NC_ERROR_EPD_IO);
}

static bool refresh_partial(void)
{
#if NAMECARD_NFC_FIXED_TEST
    const uint16_t remaining_rows = (uint16_t)(NC_IMAGE_WIDTH - fixed_completed_rows);
#if NAMECARD_NFC_BAND_ROWS == 0
    const uint16_t band_rows = remaining_rows;
#else
    const uint16_t band_rows = NFC_FIXED_BAND_ROWS > remaining_rows
                                   ? remaining_rows
                                   : NFC_FIXED_BAND_ROWS;
#endif
    const uint16_t next_completed_rows =
        (uint16_t)(fixed_completed_rows + band_rows);
#endif
    current_state = APP_STATE_REFRESHING;
    power_monitor_reset_minimum();
    if (power_monitor_sample_minimum() < CHARGE_READY_MV) {
        set_error(NC_ERROR_VDD_DROOP);
        return false;
    }

    board_epd_power_on();
    HAL_Delay(10U);
    if (power_monitor_sample_minimum() < EPD_ON_MIN_MV) {
        set_error(NC_ERROR_VDD_DROOP);
        return false;
    }
    board_epd_bus_active();

    epd_result_t result = epd_ssd1680_initialize();
#if NAMECARD_NFC_FIXED_TEST
    /* Rebuild both controller RAMs from the known physical state on every
       power cycle. Completed bands contain the target; later bands are white. */
    if (result == EPD_OK) {
        result = epd_ssd1680_write_previous_frame_prefix(image_buffer,
                                                          fixed_completed_rows);
    }
#else
    /* Initial NFC validation assumes the retained panel image is all white. */
    if (result == EPD_OK) result = epd_ssd1680_write_previous_solid(0xFFU);
#endif
    if (result == EPD_OK) result = epd_ssd1680_prepare_partial();
#if NAMECARD_NFC_FIXED_TEST
    if (result == EPD_OK) {
        result = epd_ssd1680_write_frame_prefix(image_buffer, next_completed_rows);
    }
#else
    if (result == EPD_OK) result = epd_ssd1680_write_frame(image_buffer);
#endif
    if (result != EPD_OK) {
        finish_epd_failure(result);
        return false;
    }
    if (power_monitor_sample_minimum() < EPD_START_MIN_MV) {
        epd_ssd1680_deep_sleep();
        set_error(NC_ERROR_VDD_DROOP);
        return false;
    }
    result = epd_ssd1680_start_partial();
    if (result == EPD_OK) {
        HAL_Delay(1U);
        result = epd_ssd1680_wait_ready(2000U, true);
    }
    if (result != EPD_OK) {
        finish_epd_failure(result);
        return false;
    }
    epd_ssd1680_deep_sleep();
    board_epd_power_off();
#if NAMECARD_NFC_FIXED_TEST
    fixed_completed_rows = next_completed_rows;
    if (fixed_completed_rows < NC_IMAGE_WIDTH) {
        /* Let V_EH recharge SYS_VDD before applying the next band. */
        current_state = APP_STATE_CHARGING;
        charge_started_at = HAL_GetTick();
        stable_started_at = 0U;
        last_power_sample_at = charge_started_at;
        return true;
    }
#endif
    current_state = APP_STATE_COMPLETE;
    current_error = NC_ERROR_NONE;
    return true;
}

static void external_power_self_test(void)
{
#if NAMECARD_BOOT_SELF_TEST
    fixed_image_make_test_pattern(image_buffer);
    board_epd_power_on();
    HAL_Delay(10U);
    board_epd_bus_active();
    epd_result_t result = epd_ssd1680_initialize();
    /* Mode 1 ignores the differential baseline, but prime both RAMs alike. */
    if (result == EPD_OK) result = epd_ssd1680_write_frame(image_buffer);
    if (result == EPD_OK) result = epd_ssd1680_write_previous_frame(image_buffer);
    if (result == EPD_OK) result = epd_ssd1680_start_full();
    if (result == EPD_OK) {
        HAL_Delay(1U);
        result = epd_ssd1680_wait_ready(5000U, true);
    }
    if (result == EPD_OK) {
        for (uint16_t row = 96U; row < 200U; row += 8U) {
            image_buffer[(size_t)row * 16U + 7U] ^= 0xFFU;
            image_buffer[(size_t)row * 16U + 8U] ^= 0xFFU;
        }
        result = epd_ssd1680_prepare_partial();
    }
    if (result == EPD_OK) result = epd_ssd1680_write_frame(image_buffer);
    if (result == EPD_OK) result = epd_ssd1680_start_partial();
    if (result == EPD_OK) {
        HAL_Delay(1U);
        result = epd_ssd1680_wait_ready(2000U, true);
    }
    epd_ssd1680_deep_sleep();
    board_epd_power_off();
    if (result != EPD_OK) {
        set_error(result == EPD_BUSY_TIMEOUT ? NC_ERROR_EPD_TIMEOUT : NC_ERROR_EPD_IO);
    }
#endif
}

#if NAMECARD_PREPARE_WHITE
static void external_power_prepare_white(void)
{
    memset(image_buffer, 0xFF, sizeof(image_buffer));
    board_epd_power_on();
    HAL_Delay(10U);
    board_epd_bus_active();

    epd_result_t result = epd_ssd1680_initialize();
    if (result == EPD_OK) result = epd_ssd1680_write_frame(image_buffer);
    if (result == EPD_OK) result = epd_ssd1680_start_full();
    if (result == EPD_OK) {
        HAL_Delay(1U);
        result = epd_ssd1680_wait_ready(5000U, true);
    }
    epd_ssd1680_deep_sleep();
    board_epd_power_off();
    if (result == EPD_OK) {
        current_state = APP_STATE_COMPLETE;
    } else {
        set_error(result == EPD_BUSY_TIMEOUT ? NC_ERROR_EPD_TIMEOUT : NC_ERROR_EPD_IO);
    }
}
#endif

void app_init(void)
{
    current_state = APP_STATE_BOOT;
    current_error = NC_ERROR_NONE;
    nc_transfer_reset(&transfer);
    power_monitor_reset_minimum();
    epd_ssd1680_bind(&hspi1);
    st25dv_bind(&hi2c1);
    board_epd_power_off();

#if NAMECARD_PREPARE_WHITE
    external_power_prepare_white();
    return;
#endif
    external_power_self_test();
#if NAMECARD_NFC_FIXED_TEST
    mailbox_enabled = false;
    fixed_image_make_test_pattern(image_buffer);
    fixed_completed_rows = 0U;
    current_state = APP_STATE_CHARGING;
    charge_started_at = HAL_GetTick();
#else
    mailbox_enabled = (st25dv_probe() == ST25DV_OK) &&
                      (st25dv_enable_mailbox() == ST25DV_OK);
    (void)st25dv_read_eh_control(&eh_control);
    if (current_state != APP_STATE_ERROR) {
        current_state = APP_STATE_RECEIVING;
    }
#endif
}

void app_process(void)
{
#if NAMECARD_PREPARE_WHITE
    __WFI();
    return;
#endif
    const uint32_t now = HAL_GetTick();
#if !NAMECARD_NFC_FIXED_TEST
    if (!mailbox_enabled && ((now - last_mailbox_poll_at) >= 100U)) {
        last_mailbox_poll_at = now;
        mailbox_enabled = st25dv_enable_mailbox() == ST25DV_OK;
    }
#endif

#if NAMECARD_NFC_FIXED_TEST
    if ((current_state == APP_STATE_CHARGING) && wait_charge_ready()) {
        current_state = APP_STATE_READY;
        HAL_Delay(EXECUTE_QUIET_GUARD_MS);
        (void)refresh_partial();
    }
#else
    if ((current_state == APP_STATE_CHARGING) && wait_charge_ready()) {
        current_state = APP_STATE_READY;
    }
#endif

    if (current_state == APP_STATE_EXECUTE_ACK) {
        if (!execute_ack_was_read) {
            uint8_t mailbox_control = 0U;
            if ((st25dv_read_mailbox_control(&mailbox_control) == ST25DV_OK) &&
                ((mailbox_control & ST25DV_MB_CTRL_HOST_PUT_MSG) == 0U)) {
                execute_ack_was_read = true;
                execute_ack_read_at = now;
            }
        }
        if (execute_ack_was_read && ((now - execute_ack_read_at) >= EXECUTE_QUIET_GUARD_MS)) {
            (void)refresh_partial();
        } else if (!execute_ack_was_read &&
                   ((now - execute_ack_started_at) >= EXECUTE_ACK_TIMEOUT_MS)) {
            set_error(NC_ERROR_EXECUTE_ACK_TIMEOUT);
        }
    }

#if !NAMECARD_NFC_FIXED_TEST
    if (mailbox_enabled && (current_state != APP_STATE_REFRESHING) &&
        ((now - last_mailbox_poll_at) >= MAILBOX_POLL_MS)) {
        last_mailbox_poll_at = now;
        handle_message();
    }
#endif
    (void)board_take_nfc_gpo_edge();
    __WFI();
}

app_state_t app_state(void)
{
    return current_state;
}
