#include "app.h"

#include <stdbool.h>
#include <string.h>

#include "board.h"
#include "display_store.h"
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
#define GRAY4_CHARGE_STABLE_MS 500U
#define CHARGE_TIMEOUT_MS ((uint32_t)NAMECARD_CHARGE_TIMEOUT_MS)
#define EXECUTE_ACK_TIMEOUT_MS 1000U
#define EXECUTE_QUIET_GUARD_MS 100U
#define CLIENT_RF_QUIET_MS 2000U
#define CLIENT_GRAY4_QUIET_MS 60000U
#define GRAY4_BAND_ROWS 32U
#define CLIENT_BATCH_CLEAN_QUIET_MS 1000U
#define MAILBOX_POLL_MS 25U
#define ACK_PUBLISH_ATTEMPTS 20U
#define ACK_PUBLISH_RETRY_MS 10U

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
static bool ndef_write_pause_requested;
static bool ndef_write_paused;
#endif
static uint32_t execute_ack_started_at;
static uint32_t execute_ack_read_at;
static bool execute_ack_was_read;
static bool mailbox_enabled;
#if !NAMECARD_NFC_FIXED_TEST
static uint8_t pending_pattern_id;
static bool target_staged;
typedef enum {
    CLEAN_PHASE_NONE = 0,
    CLEAN_PHASE_WHITE_1,
    CLEAN_PHASE_BLACK,
    CLEAN_PHASE_WHITE_2,
    CLEAN_PHASE_TARGET
} clean_phase_t;
static bool batch_clean_active;
static clean_phase_t clean_phase;
static bool force_full_clean_first;
static uint16_t gray4_completed_rows;
#endif
#if NAMECARD_NFC_FIXED_TEST
static uint16_t fixed_completed_rows;
#endif

static void set_error(nc_error_t error)
{
    current_error = error;
    current_state = APP_STATE_ERROR;
    board_epd_power_off();
    board_power_hold_release();
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
    payload[15] = (mailbox_enabled ? 0x01U : 0U) |
                  (display_store_has_committed() ? 0x02U : 0U) |
                  (display_store_has_pending() ? 0x04U : 0U) |
                  0x08U | /* Firmware-managed batch clean supported. */
                  (batch_clean_active ? 0x10U : 0U) |
                  0x20U | /* Native four-gray transfer supported. */
                  ((display_store_committed_format() ==
                    NC_IMAGE_FORMAT_GRAY4_PLANE) ? 0x40U : 0U) |
                  ((display_store_pending_format() ==
                    NC_IMAGE_FORMAT_GRAY4_PLANE) ? 0x80U : 0U);

    const uint8_t response_type = reply.result == NC_TRANSFER_REJECTED
                                      ? NC_TYPE_ERROR
                                      : NC_TYPE_ACK;
    const size_t length = nc_frame_build(mailbox_buffer, sizeof(mailbox_buffer),
                                         response_type, request->transfer_id,
                                         request->sequence, reply.expected_offset,
                                         payload, sizeof(payload));
    if (length == 0U) {
        return false;
    }

    /* RF reads of MB_CTRL_Dyn can briefly overlap the I2C mailbox write.
       Keep the already-applied transfer state and retry publication instead
       of treating one arbitration/transient error as a fatal power fault. */
    for (uint32_t attempt = 0U; attempt < ACK_PUBLISH_ATTEMPTS; ++attempt) {
        if (st25dv_write_host_message(mailbox_buffer, (uint16_t)length) == ST25DV_OK) {
            return true;
        }
        HAL_Delay(ACK_PUBLISH_RETRY_MS);
    }
    return false;
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

    /* A brief VCC/RF transition can make one I2C poll fail even though the
       following mailbox transaction succeeds. Do not report that recovered
       poll as a permanent STATUS error. Fatal reply-write failures still use
       set_error() and remain latched in APP_STATE_ERROR. */
    if ((current_error == NC_ERROR_NFC_IO) &&
        (current_state != APP_STATE_ERROR)) {
        current_error = NC_ERROR_NONE;
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

    if (frame.type == NC_TYPE_NDEF_WRITE_PREPARE) {
        if ((frame.sequence != 0U) || (frame.offset != 0U) ||
            (frame.payload_length != 0U) ||
            (current_state == APP_STATE_REFRESHING) ||
            (current_state == APP_STATE_EXECUTE_ACK)) {
            (void)send_reply(&frame, rejected(NC_ERROR_COMMAND), 0U);
            return;
        }
        current_error = NC_ERROR_NONE;
        if (send_reply(&frame, status_reply(), 0U)) {
            /* The phone disables MB_EN after reading this ACK. Suppress the
               normal 100 ms auto-enable loop until it explicitly enables the
               mailbox again after the EEPROM/NDEF write. */
            ndef_write_pause_requested = true;
        } else {
            current_error = NC_ERROR_NFC_IO;
        }
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

    if ((frame.type == NC_TYPE_START) && (frame.payload_length == 16U) &&
        (frame.payload[6] == NC_IMAGE_FORMAT_GRAY4_PLANE) &&
        (frame.payload[7] == 1U) &&
        (!display_store_has_pending() ||
         (display_store_pending_format() != NC_IMAGE_FORMAT_GRAY4_PLANE) ||
         (display_store_pending_transfer_id() != frame.transfer_id))) {
        (void)send_reply(&frame, rejected(NC_ERROR_NOT_COMMITTED), 0U);
        return;
    }
    if ((frame.type == NC_TYPE_EXECUTE) &&
        (transfer.image_format == NC_IMAGE_FORMAT_GRAY4_PLANE) &&
        (transfer.plane_index != 1U)) {
        (void)send_reply(&frame, rejected(NC_ERROR_NOT_COMMITTED), 0U);
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
        pending_pattern_id = 0U;
        gray4_completed_rows = 0U;
        target_staged =
            (transfer.image_format == NC_IMAGE_FORMAT_GRAY4_PLANE) &&
            (transfer.plane_index == 1U);
        batch_clean_active = false;
        clean_phase = CLEAN_PHASE_NONE;
        force_full_clean_first =
            (transfer.image_format == NC_IMAGE_FORMAT_NATIVE_1BPP) &&
            (display_store_committed_format() ==
             NC_IMAGE_FORMAT_GRAY4_PLANE);
        current_state = APP_STATE_RECEIVING;
        power_monitor_reset_minimum();
    } else if ((reply.result == NC_TRANSFER_COMMITTED) ||
               (reply.result == NC_TRANSFER_PATTERN)) {
        if (reply.result == NC_TRANSFER_PATTERN) {
            pending_pattern_id = transfer.pattern_id;
            fixed_image_make_pattern(image_buffer, pending_pattern_id);
        }
        batch_clean_active = false;
        clean_phase = CLEAN_PHASE_NONE;
        target_staged =
            (transfer.image_format == NC_IMAGE_FORMAT_GRAY4_PLANE) &&
            (transfer.plane_index == 1U);
        if (reply.result == NC_TRANSFER_PATTERN) {
            force_full_clean_first =
                display_store_committed_format() ==
                NC_IMAGE_FORMAT_GRAY4_PLANE;
        }
        current_state = APP_STATE_CHARGING;
        charge_started_at = HAL_GetTick();
        stable_started_at = 0U;
    } else if (reply.result == NC_TRANSFER_EXECUTE) {
        if (transfer.image_format == NC_IMAGE_FORMAT_GRAY4_PLANE) {
            gray4_completed_rows = 0U;
        }
        if (((transfer.flags & NC_TRANSFER_FLAG_BATCH_CLEAN) != 0U) ||
            force_full_clean_first) {
            batch_clean_active = true;
            clean_phase = CLEAN_PHASE_WHITE_1;
        }
        current_state = APP_STATE_EXECUTE_ACK;
    }

    const uint16_t quiet = reply.result == NC_TRANSFER_EXECUTE
                               ? ((transfer.image_format ==
                                   NC_IMAGE_FORMAT_GRAY4_PLANE)
                                      ? CLIENT_GRAY4_QUIET_MS
                                      : (batch_clean_active
                                      ? CLIENT_BATCH_CLEAN_QUIET_MS
                                      : CLIENT_RF_QUIET_MS))
                               : 0U;
    if (!send_reply(&frame, reply, quiet)) {
        /* START/DATA/COMMIT/PATTERN are idempotent.  Preserve the transfer so
           the phone can resend the unacknowledged frame after a timeout or a
           new tap.  EXECUTE is intentionally still fatal because its ACK is
           the synchronization point before the RF-quiet refresh window. */
        if (reply.result == NC_TRANSFER_EXECUTE) {
            set_error(NC_ERROR_NFC_IO);
        } else {
            current_error = NC_ERROR_NFC_IO;
        }
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
#if !NAMECARD_NFC_FIXED_TEST
    const uint32_t stable_ms =
        transfer.image_format == NC_IMAGE_FORMAT_GRAY4_PLANE
            ? GRAY4_CHARGE_STABLE_MS
            : CHARGE_STABLE_MS;
#else
    const uint32_t stable_ms = CHARGE_STABLE_MS;
#endif
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
        if ((now - stable_started_at) >= stable_ms) {
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

static nc_error_t epd_error(epd_result_t result)
{
    if (result == EPD_VDD_DROOP) return NC_ERROR_VDD_DROOP;
    if (result == EPD_BUSY_TIMEOUT) return NC_ERROR_EPD_TIMEOUT;
    return NC_ERROR_EPD_IO;
}

static void finish_epd_failure(epd_result_t result)
{
    if (!board_brownout_detected()) {
        epd_ssd1680_deep_sleep();
    }
    board_epd_power_off();
    set_error(epd_error(result));
}

#if !NAMECARD_NFC_FIXED_TEST
static epd_result_t write_previous_for_refresh(void)
{
    if (batch_clean_active) {
        if ((clean_phase == CLEAN_PHASE_BLACK) ||
            (clean_phase == CLEAN_PHASE_TARGET)) {
            return epd_ssd1680_write_previous_solid(0xFFU);
        }
        if (clean_phase == CLEAN_PHASE_WHITE_2) {
            return epd_ssd1680_write_previous_solid(0x00U);
        }
    }

    const uint8_t *previous = display_store_committed_image();
    return (previous != NULL) &&
                   (display_store_committed_format() ==
                    NC_IMAGE_FORMAT_NATIVE_1BPP)
               ? epd_ssd1680_write_previous_frame(previous)
               : epd_ssd1680_write_previous_solid(0xFFU);
}

static epd_result_t write_current_for_refresh(void)
{
    if (batch_clean_active) {
        if ((clean_phase == CLEAN_PHASE_WHITE_1) ||
            (clean_phase == CLEAN_PHASE_WHITE_2)) {
            return epd_ssd1680_write_solid(0xFFU);
        }
        if (clean_phase == CLEAN_PHASE_BLACK) {
            return epd_ssd1680_write_solid(0x00U);
        }
    }
    return epd_ssd1680_write_frame(image_buffer);
}
#endif

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
    if (board_brownout_detected()) {
        set_error(NC_ERROR_VDD_DROOP);
        return false;
    }
    board_power_hold_enable();
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
    if (result == EPD_OK) result = epd_ssd1680_prepare_partial();
    if (result == EPD_OK) {
        result = epd_ssd1680_write_frame_prefix(image_buffer, next_completed_rows);
    }
#else
    const bool full_clean_step = force_full_clean_first &&
                                 batch_clean_active &&
                                 (clean_phase == CLEAN_PHASE_WHITE_1);
    if (full_clean_step) {
        if (result == EPD_OK) result = epd_ssd1680_write_solid(0xFFU);
    } else {
        if (result == EPD_OK) result = write_previous_for_refresh();
        if (result == EPD_OK) result = epd_ssd1680_prepare_partial();
        if (result == EPD_OK) result = write_current_for_refresh();
    }
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
    result =
#if NAMECARD_NFC_FIXED_TEST
        epd_ssd1680_start_partial();
#else
        full_clean_step ? epd_ssd1680_start_full()
                        : epd_ssd1680_start_partial();
#endif
    if (result == EPD_OK) {
        HAL_Delay(1U);
        result = epd_ssd1680_wait_ready(
#if NAMECARD_NFC_FIXED_TEST
            2000U,
#else
            full_clean_step ? 5000U : 2000U,
#endif
            true);
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
#if !NAMECARD_NFC_FIXED_TEST
    if (batch_clean_active && (clean_phase < CLEAN_PHASE_TARGET)) {
        clean_phase = (clean_phase_t)((uint8_t)clean_phase + 1U);
        current_state = APP_STATE_CHARGING;
        charge_started_at = HAL_GetTick();
        stable_started_at = 0U;
        last_power_sample_at = charge_started_at;
        return true;
    }

    /* The target was already fully staged in the inactive Flash slot. Only
       this separate marker is written after BUSY finishes. */
    if (!display_store_commit()) {
        set_error(NC_ERROR_FLASH_STORE);
        return false;
    }
#endif
    current_state = APP_STATE_COMPLETE;
    current_error = NC_ERROR_NONE;
#if !NAMECARD_NFC_FIXED_TEST
    pending_pattern_id = 0U;
    target_staged = false;
    batch_clean_active = false;
    clean_phase = CLEAN_PHASE_NONE;
    force_full_clean_first = false;
#endif
    return true;
}

#if !NAMECARD_NFC_FIXED_TEST
static nc_error_t wait_gray4_recharge(void)
{
    const HAL_TickFreqTypeDef original_tick_frequency = HAL_GetTickFreq();
    const bool reduce_tick_frequency =
        HAL_SetTickFreq(HAL_TICK_FREQ_10HZ) == HAL_OK;
    const uint32_t started_at = HAL_GetTick();
    uint32_t stable_at = 0U;
    uint32_t last_sample_at = started_at - 100U;
    nc_error_t error = NC_ERROR_NONE;

    for (;;) {
        if (board_brownout_detected()) {
            error = NC_ERROR_VDD_DROOP;
            break;
        }
        const uint32_t now = HAL_GetTick();
        if ((now - last_sample_at) >= 100U) {
            last_sample_at = now;
            current_vdd_mv = power_monitor_sample_minimum();
            if (current_vdd_mv >= CHARGE_READY_MV) {
                if (stable_at == 0U) stable_at = now;
                if ((now - stable_at) >= GRAY4_CHARGE_STABLE_MS) break;
            } else {
                stable_at = 0U;
            }
        }
        if ((now - started_at) >= CHARGE_TIMEOUT_MS) {
            error = NC_ERROR_VDD_TIMEOUT;
            break;
        }
        __WFI();
    }

    if (reduce_tick_frequency) {
        (void)HAL_SetTickFreq(original_tick_frequency);
    }
    return error;
}

static bool recharge_gray4_or_stop(void)
{
    const nc_error_t error = wait_gray4_recharge();
    if (error == NC_ERROR_NONE) return true;
    if (!board_brownout_detected()) epd_ssd1680_deep_sleep();
    set_error(error);
    return false;
}

static bool refresh_gray4(void)
{
    const uint8_t *plane0 = display_store_pending_image();
    if ((plane0 == NULL) ||
        (display_store_pending_format() != NC_IMAGE_FORMAT_GRAY4_PLANE) ||
        (display_store_pending_transfer_id() != transfer.transfer_id)) {
        set_error(NC_ERROR_NOT_COMMITTED);
        return false;
    }
    if (board_brownout_detected()) {
        set_error(NC_ERROR_VDD_DROOP);
        return false;
    }
    board_power_hold_enable();
    current_state = APP_STATE_REFRESHING;
    if (gray4_completed_rows == 0U) power_monitor_reset_minimum();
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

    epd_result_t result = epd_ssd1680_initialize_gray4();
    if ((result == EPD_OK) && !recharge_gray4_or_stop()) return false;
    if (result == EPD_OK) {
        result = epd_ssd1680_finish_gray4_initialization();
    }
    if ((result == EPD_OK) && !recharge_gray4_or_stop()) return false;

    if (result != EPD_OK) {
        finish_epd_failure(result);
        return false;
    }

    const uint16_t remaining =
        (uint16_t)(NC_IMAGE_WIDTH - gray4_completed_rows);
    uint16_t first_row = gray4_completed_rows;
    uint16_t rows = remaining > GRAY4_BAND_ROWS
                        ? GRAY4_BAND_ROWS
                        : remaining;
    if (rows < 16U) {
        first_row = (uint16_t)(NC_IMAGE_WIDTH - 16U);
        rows = 16U;
    }
    result = epd_ssd1680_write_gray4_band(
        plane0, image_buffer, first_row, rows);
    if (result != EPD_OK) {
        finish_epd_failure(result);
        return false;
    }
    if (!recharge_gray4_or_stop()) return false;
    if (power_monitor_sample_minimum() < EPD_START_MIN_MV) {
        epd_ssd1680_deep_sleep();
        set_error(NC_ERROR_VDD_DROOP);
        return false;
    }
    result = epd_ssd1680_start_gray4();
    if (result == EPD_OK) {
        HAL_Delay(1U);
        result = epd_ssd1680_wait_ready(5000U, true);
    }
    if (result != EPD_OK) {
        finish_epd_failure(result);
        return false;
    }

    epd_ssd1680_deep_sleep();
    board_epd_power_off();
    gray4_completed_rows =
        (uint16_t)(gray4_completed_rows + GRAY4_BAND_ROWS);
    if (gray4_completed_rows > NC_IMAGE_WIDTH) {
        gray4_completed_rows = NC_IMAGE_WIDTH;
    }
    if (gray4_completed_rows < NC_IMAGE_WIDTH) {
        current_state = APP_STATE_CHARGING;
        charge_started_at = HAL_GetTick();
        stable_started_at = 0U;
        last_power_sample_at = charge_started_at;
        return true;
    }
    if (!display_store_commit()) {
        set_error(NC_ERROR_FLASH_STORE);
        return false;
    }
    current_state = APP_STATE_COMPLETE;
    current_error = NC_ERROR_NONE;
    target_staged = false;
    force_full_clean_first = false;
    gray4_completed_rows = 0U;
    return true;
}
#endif

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
    if (!board_brownout_detected()) {
        epd_ssd1680_deep_sleep();
    }
    board_epd_power_off();
    if ((result == EPD_OK) &&
        (!display_store_stage(image_buffer, 0U, 0U, 0U,
                              NC_IMAGE_FORMAT_NATIVE_1BPP, false) ||
         !display_store_commit())) {
        set_error(NC_ERROR_FLASH_STORE);
    } else if (result != EPD_OK) {
        set_error(epd_error(result));
    }
#endif
}

#if NAMECARD_PREPARE_WHITE || NAMECARD_FACTORY_CONFIRM
static bool external_power_full_refresh_and_store(void)
{
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
    if (!board_brownout_detected()) {
        epd_ssd1680_deep_sleep();
    }
    board_epd_power_off();
    if ((result == EPD_OK) &&
        (!display_store_stage(image_buffer, 0U, 0U, 0U,
                              NC_IMAGE_FORMAT_NATIVE_1BPP, false) ||
         !display_store_commit())) {
        set_error(NC_ERROR_FLASH_STORE);
        return false;
    } else if (result == EPD_OK) {
        current_state = APP_STATE_COMPLETE;
    } else {
        set_error(epd_error(result));
        return false;
    }
    return true;
}
#endif

#if NAMECARD_PREPARE_WHITE
static void external_power_prepare_white(void)
{
    if ((st25dv_probe() != ST25DV_OK) ||
        (st25dv_factory_enable_eh_at_boot() != ST25DV_OK)) {
        set_error(NC_ERROR_HARDWARE_GATE);
        return;
    }
    memset(image_buffer, 0xFF, sizeof(image_buffer));
    (void)external_power_full_refresh_and_store();
}
#endif

void app_init(void)
{
    current_state = APP_STATE_BOOT;
    current_error = NC_ERROR_NONE;
    nc_transfer_reset(&transfer);
    power_monitor_reset_minimum();
    display_store_init();
    epd_ssd1680_bind(&hspi1);
    st25dv_bind(&hi2c1);
    board_epd_power_off();

#if NAMECARD_PREPARE_WHITE
    external_power_prepare_white();
    return;
#endif
    external_power_self_test();
#if NAMECARD_BOOT_SELF_TEST
    /* This image is a dedicated externally-powered display diagnostic. Keep
       the completed result on screen instead of starting the release mailbox
       application after the test. */
    return;
#endif
#if NAMECARD_NFC_FIXED_TEST
    mailbox_enabled = false;
    fixed_image_make_test_pattern(image_buffer);
    fixed_completed_rows = 0U;
    current_state = APP_STATE_CHARGING;
    charge_started_at = HAL_GetTick();
#else
    ndef_write_pause_requested = false;
    ndef_write_paused = false;
    /* A freshly assembled ST25DV ships with EH_MODE=1 and MB_MODE=0.  The
     * release image is programmed while external 3.3 V is present, so use
     * that first boot to provision both nonvolatile settings before enabling
     * the dynamic mailbox.  The helper only reads the registers once a board
     * is provisioned, so normal NFC-powered boots do not rewrite EEPROM. */
    mailbox_enabled =
        (st25dv_probe() == ST25DV_OK) &&
        (st25dv_factory_enable_eh_at_boot() == ST25DV_OK) &&
        (st25dv_enable_mailbox() == ST25DV_OK);
#if NAMECARD_FACTORY_CONFIRM
    if (mailbox_enabled && !display_store_has_committed()) {
        fixed_image_make_fw_ok_pattern(image_buffer);
        if (!external_power_full_refresh_and_store()) {
            mailbox_enabled = false;
        }
    }
#endif
    (void)st25dv_read_eh_control(&eh_control);
    if (current_state != APP_STATE_ERROR) {
        if (display_store_has_pending()) {
            transfer.active = true;
            transfer.committed = true;
            transfer.transfer_id = display_store_pending_transfer_id();
            transfer.expected_sequence = display_store_pending_sequence();
            transfer.expected_offset = NC_IMAGE_SIZE;
            transfer.pattern_id = display_store_pending_pattern_id();
            transfer.image_format = display_store_pending_format();
            transfer.flags = display_store_pending_batch_clean()
                                 ? NC_TRANSFER_FLAG_BATCH_CLEAN
                                 : 0U;
            pending_pattern_id = transfer.pattern_id;
            target_staged = true;
            batch_clean_active = false;
            clean_phase = CLEAN_PHASE_NONE;
            force_full_clean_first =
                (transfer.image_format == NC_IMAGE_FORMAT_NATIVE_1BPP) &&
                (display_store_committed_format() ==
                 NC_IMAGE_FORMAT_GRAY4_PLANE);
            if (transfer.image_format == NC_IMAGE_FORMAT_GRAY4_PLANE) {
                transfer.plane_index = 0U;
                current_state = APP_STATE_RECEIVING;
            } else {
                memcpy(image_buffer, display_store_pending_image(),
                       NC_IMAGE_SIZE);
                current_state = APP_STATE_CHARGING;
                charge_started_at = HAL_GetTick();
                stable_started_at = 0U;
            }
        } else if (display_store_has_committed()) {
            /* If power disappeared after the EPD/Flash commit but before the
               phone read COMPLETE, let that same Android session finish
               without retransmitting all 4,736 bytes. */
            transfer.active = true;
            transfer.committed = true;
            transfer.execute_requested = true;
            transfer.transfer_id = display_store_committed_transfer_id();
            transfer.expected_sequence =
                (uint16_t)(display_store_committed_sequence() + 1U);
            transfer.expected_offset = NC_IMAGE_SIZE;
            transfer.pattern_id = display_store_committed_pattern_id();
            transfer.image_format = display_store_committed_format();
            transfer.plane_index =
                transfer.image_format == NC_IMAGE_FORMAT_GRAY4_PLANE ? 1U : 0U;
            pending_pattern_id = 0U;
            target_staged = false;
            batch_clean_active = false;
            clean_phase = CLEAN_PHASE_NONE;
            force_full_clean_first = false;
            current_state = APP_STATE_COMPLETE;
        } else {
            pending_pattern_id = 0U;
            target_staged = false;
            batch_clean_active = false;
            clean_phase = CLEAN_PHASE_NONE;
            force_full_clean_first = false;
            current_state = APP_STATE_RECEIVING;
        }
    }
#endif
}

void app_process(void)
{
#if NAMECARD_PREPARE_WHITE || NAMECARD_BOOT_SELF_TEST
    __WFI();
    return;
#endif
    if (board_brownout_detected()) {
        set_error(NC_ERROR_VDD_DROOP);
        __WFI();
        return;
    }
    const uint32_t now = HAL_GetTick();
#if !NAMECARD_NFC_FIXED_TEST
    const bool nfc_gpo_edge = board_take_nfc_gpo_edge();
#endif
#if !NAMECARD_NFC_FIXED_TEST
    if (ndef_write_pause_requested) {
        uint8_t mailbox_control = 0U;
        if ((st25dv_read_mailbox_control(&mailbox_control) == ST25DV_OK) &&
            (((mailbox_control & ST25DV_MB_CTRL_HOST_PUT_MSG) == 0U) ||
             ((mailbox_control & ST25DV_MB_CTRL_MB_EN) == 0U)) &&
            (st25dv_disable_mailbox() == ST25DV_OK)) {
            mailbox_enabled = false;
            ndef_write_pause_requested = false;
            ndef_write_paused = true;
            last_mailbox_poll_at = now;
        }
    }
    if (ndef_write_paused && ((now - last_mailbox_poll_at) >= 100U)) {
        uint8_t mailbox_control = 0U;
        last_mailbox_poll_at = now;
        if ((st25dv_read_mailbox_control(&mailbox_control) == ST25DV_OK) &&
            ((mailbox_control & ST25DV_MB_CTRL_MB_EN) != 0U)) {
            mailbox_enabled = true;
            ndef_write_paused = false;
        }
    }
    if (ndef_write_paused || ndef_write_pause_requested) {
        __WFI();
        return;
    }
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
        if (!target_staged) {
            if (!display_store_stage(image_buffer, transfer.transfer_id,
                                     transfer.expected_sequence,
                                     pending_pattern_id,
                                     transfer.image_format,
                                     (transfer.flags &
                                      NC_TRANSFER_FLAG_BATCH_CLEAN) != 0U)) {
                set_error(NC_ERROR_FLASH_STORE);
            } else {
                target_staged = true;
                /* Flash erase/program consumes stored energy. Recharge to the
                   same 3.20 V gate before allowing EXECUTE. */
                charge_started_at = HAL_GetTick();
                stable_started_at = 0U;
                last_power_sample_at = charge_started_at;
            }
        } else if (batch_clean_active &&
                   (clean_phase != CLEAN_PHASE_NONE)) {
            HAL_Delay(EXECUTE_QUIET_GUARD_MS);
            (void)refresh_partial();
        } else if ((transfer.image_format == NC_IMAGE_FORMAT_GRAY4_PLANE) &&
                   transfer.execute_requested &&
                   (gray4_completed_rows < NC_IMAGE_WIDTH)) {
            HAL_Delay(EXECUTE_QUIET_GUARD_MS);
            (void)refresh_gray4();
        } else {
            current_state = APP_STATE_READY;
        }
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
#if !NAMECARD_NFC_FIXED_TEST
            if (transfer.image_format == NC_IMAGE_FORMAT_GRAY4_PLANE) {
                (void)refresh_gray4();
            } else {
                (void)refresh_partial();
            }
#else
            (void)refresh_partial();
#endif
        } else if (!execute_ack_was_read &&
                   ((now - execute_ack_started_at) >= EXECUTE_ACK_TIMEOUT_MS)) {
            set_error(NC_ERROR_EXECUTE_ACK_TIMEOUT);
        }
    }

#if !NAMECARD_NFC_FIXED_TEST
    if (mailbox_enabled && (current_state != APP_STATE_REFRESHING) &&
        (nfc_gpo_edge || ((now - last_mailbox_poll_at) >= MAILBOX_POLL_MS))) {
        last_mailbox_poll_at = now;
        handle_message();
    }
#endif
#if NAMECARD_NFC_FIXED_TEST
    (void)board_take_nfc_gpo_edge();
#endif
    __WFI();
}

app_state_t app_state(void)
{
    return current_state;
}
