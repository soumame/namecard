#include "epd_ssd1680.h"

#include "board.h"
#include "power_monitor.h"

#define EPD_SPI_TIMEOUT_MS 100U
#define EPD_BUSY_TIMEOUT_MS 2000U

static SPI_HandleTypeDef *epd_spi;

static epd_result_t activate(uint8_t update_control2);

static epd_result_t send_bytes(bool data_mode, const uint8_t *bytes, uint16_t length)
{
    if (board_brownout_detected()) {
        return EPD_VDD_DROOP;
    }
    HAL_GPIO_WritePin(EPD_DC_PORT, EPD_DC_PIN,
                      data_mode ? GPIO_PIN_SET : GPIO_PIN_RESET);
    HAL_GPIO_WritePin(EPD_CS_PORT, EPD_CS_PIN, GPIO_PIN_RESET);
    const HAL_StatusTypeDef status =
        HAL_SPI_Transmit(epd_spi, (uint8_t *)bytes, length, EPD_SPI_TIMEOUT_MS);
    HAL_GPIO_WritePin(EPD_CS_PORT, EPD_CS_PIN, GPIO_PIN_SET);
    if (board_brownout_detected()) {
        return EPD_VDD_DROOP;
    }
    return status == HAL_OK ? EPD_OK : EPD_IO_ERROR;
}

static epd_result_t command(uint8_t value)
{
    return send_bytes(false, &value, 1U);
}

static epd_result_t command_data(uint8_t cmd, const uint8_t *data, uint16_t length)
{
    epd_result_t result = command(cmd);
    if ((result == EPD_OK) && (length != 0U)) {
        result = send_bytes(true, data, length);
    }
    return result;
}

void epd_ssd1680_bind(SPI_HandleTypeDef *spi)
{
    epd_spi = spi;
}

epd_result_t epd_ssd1680_wait_ready(uint32_t timeout_ms, bool sample_vdd)
{
    /* BUSY edges wake the CPU through EXTI. Keep SysTick at 10 Hz for every
       refresh path so the release four-gray waveform does not waste the very
       small harvested-power margin on 1 kHz timeout wakeups. */
    const HAL_TickFreqTypeDef original_tick_frequency = HAL_GetTickFreq();
    const bool reduce_tick_frequency =
        HAL_SetTickFreq(HAL_TICK_FREQ_10HZ) == HAL_OK;
    const uint32_t start = HAL_GetTick();
    uint32_t last_sample = start - 20U;
    epd_result_t result = EPD_OK;
    while (board_epd_is_busy()) {
        if (board_brownout_detected()) {
            result = EPD_VDD_DROOP;
            break;
        }
        const uint32_t now = HAL_GetTick();
        if ((now - start) >= timeout_ms) {
            result = EPD_BUSY_TIMEOUT;
            break;
        }
#if NAMECARD_DIAGNOSTIC
        if (sample_vdd && ((now - last_sample) >= 20U)) {
            (void)power_monitor_sample_minimum();
            last_sample = now;
        }
#else
        (void)sample_vdd;
        (void)last_sample;
#endif
        __WFI();
    }
    if (board_brownout_detected()) {
        result = EPD_VDD_DROOP;
    }
    if (reduce_tick_frequency) {
        (void)HAL_SetTickFreq(original_tick_frequency);
    }
    return result;
}

epd_result_t epd_ssd1680_initialize(void)
{
    if (epd_spi == NULL) {
        return EPD_IO_ERROR;
    }
    HAL_GPIO_WritePin(EPD_RST_PORT, EPD_RST_PIN, GPIO_PIN_RESET);
    HAL_Delay(10U);
    HAL_GPIO_WritePin(EPD_RST_PORT, EPD_RST_PIN, GPIO_PIN_SET);
    HAL_Delay(10U);

    epd_result_t result = command(0x12U); /* SW_RESET */
    if (result == EPD_OK) {
        result = epd_ssd1680_wait_ready(EPD_BUSY_TIMEOUT_MS, false);
    }
    static const uint8_t gate_setting[] = {0x27U, 0x01U, 0x00U};
    /* Good Display GDEY029T94 demo: X increments, Y decrements. */
    static const uint8_t data_entry[] = {0x01U};
    static const uint8_t x_window[] = {0x00U, 0x0FU};
    static const uint8_t y_window[] = {0x27U, 0x01U, 0x00U, 0x00U};
    static const uint8_t border[] = {0x05U};
    static const uint8_t update_control1[] = {0x00U, 0x80U};
    static const uint8_t internal_temperature[] = {0x80U};

    if (result == EPD_OK) result = command_data(0x01U, gate_setting, sizeof(gate_setting));
    if (result == EPD_OK) result = command_data(0x11U, data_entry, sizeof(data_entry));
    if (result == EPD_OK) result = command_data(0x44U, x_window, sizeof(x_window));
    if (result == EPD_OK) result = command_data(0x45U, y_window, sizeof(y_window));
    if (result == EPD_OK) result = command_data(0x3CU, border, sizeof(border));
    if (result == EPD_OK) result = command_data(0x21U, update_control1, sizeof(update_control1));
    if (result == EPD_OK) result = command_data(0x18U, internal_temperature, sizeof(internal_temperature));
    return result;
}

epd_result_t epd_ssd1680_initialize_gray4(void)
{
    epd_result_t result = epd_ssd1680_initialize();
    if (result == EPD_OK) {
        result = activate(0xB1U); /* Load the internal temperature value. */
    }
    if (result == EPD_OK) {
        result = epd_ssd1680_wait_ready(EPD_BUSY_TIMEOUT_MS, false);
    }
    return result;
}

epd_result_t epd_ssd1680_finish_gray4_initialization(void)
{
    epd_result_t result = EPD_OK;
    static const uint8_t gray4_temperature[] = {0x5AU, 0x00U};
    result = command_data(0x1AU, gray4_temperature,
                          sizeof(gray4_temperature));
    if (result == EPD_OK) {
        result = activate(0x91U); /* Reload the four-gray waveform. */
    }
    if (result == EPD_OK) {
        result = epd_ssd1680_wait_ready(EPD_BUSY_TIMEOUT_MS, false);
    }
    return result;
}

static epd_result_t write_gray4_plane(uint8_t ram_command,
                                      const uint8_t *data,
                                      uint16_t length,
                                      const uint8_t y_address[2])
{
    static const uint8_t x_address[] = {0x00U};
    epd_result_t result =
        command_data(0x4EU, x_address, sizeof(x_address));
    if (result == EPD_OK) {
        result = command_data(0x4FU, y_address, 2U);
    }
    if (result == EPD_OK) result = command(ram_command);
    if (result == EPD_OK) result = send_bytes(true, data, length);
    return result;
}

epd_result_t epd_ssd1680_write_gray4_band(
    const uint8_t plane0[NC_IMAGE_SIZE], const uint8_t plane1[NC_IMAGE_SIZE],
    uint16_t first_row, uint16_t rows)
{
    const uint16_t mux = (uint16_t)(rows - 1U);
    const uint16_t gate_start =
        (uint16_t)(NC_IMAGE_WIDTH - first_row - rows);
    const uint16_t ram_start =
        (uint16_t)(NC_IMAGE_WIDTH - 1U - first_row);
    const uint8_t gate_setting[] = {
        (uint8_t)mux, (uint8_t)(mux >> 8), 0x00U};
    const uint8_t scan_start[] = {
        (uint8_t)gate_start, (uint8_t)(gate_start >> 8)};
    const uint8_t y_window[] = {
        (uint8_t)ram_start, (uint8_t)(ram_start >> 8),
        (uint8_t)gate_start, (uint8_t)(gate_start >> 8)};
    const uint8_t y_address[] = {
        (uint8_t)ram_start, (uint8_t)(ram_start >> 8)};

    epd_result_t result =
        command_data(0x01U, gate_setting, sizeof(gate_setting));
    if (result == EPD_OK) {
        result = command_data(0x0FU, scan_start, sizeof(scan_start));
    }
    if (result == EPD_OK) {
        result = command_data(0x45U, y_window, sizeof(y_window));
    }

    const uint16_t band_bytes = (uint16_t)(rows * (NC_IMAGE_HEIGHT / 8U));
    const uint16_t image_offset =
        (uint16_t)(first_row * (NC_IMAGE_HEIGHT / 8U));
    if (result == EPD_OK) {
        result = write_gray4_plane(0x24U, &plane0[image_offset],
                                   band_bytes, y_address);
    }
    if (result == EPD_OK) {
        result = write_gray4_plane(0x26U, &plane1[image_offset],
                                   band_bytes, y_address);
    }
    return result;
}

static epd_result_t reset_ram_address(void)
{
    static const uint8_t x_address[] = {0x00U};
    static const uint8_t y_address[] = {0x27U, 0x01U};
    epd_result_t result = command_data(0x4EU, x_address, sizeof(x_address));
    if (result == EPD_OK) {
        result = command_data(0x4FU, y_address, sizeof(y_address));
    }
    return result;
}

static epd_result_t write_frame_ram(uint8_t ram_command,
                                    const uint8_t image[NC_IMAGE_SIZE])
{
    epd_result_t result = reset_ram_address();
    if (result != EPD_OK) {
        return result;
    }
    result = command(ram_command);
    for (uint16_t offset = 0U; (result == EPD_OK) && (offset < NC_IMAGE_SIZE);) {
        const uint16_t remaining = (uint16_t)(NC_IMAGE_SIZE - offset);
        const uint16_t chunk = remaining > 256U ? 256U : remaining;
        result = send_bytes(true, &image[offset], chunk);
        offset = (uint16_t)(offset + chunk);
    }
    return result;
}

static epd_result_t write_solid_ram(uint8_t ram_command, uint8_t value)
{
    uint8_t chunk[32];
    for (size_t i = 0U; i < sizeof(chunk); ++i) {
        chunk[i] = value;
    }

    epd_result_t result = reset_ram_address();
    if (result != EPD_OK) {
        return result;
    }
    result = command(ram_command);
    for (uint16_t offset = 0U; (result == EPD_OK) && (offset < NC_IMAGE_SIZE);) {
        const uint16_t remaining = (uint16_t)(NC_IMAGE_SIZE - offset);
        const uint16_t length = remaining > sizeof(chunk) ? sizeof(chunk) : remaining;
        result = send_bytes(true, chunk, length);
        offset = (uint16_t)(offset + length);
    }
    return result;
}

static epd_result_t write_prefix_ram(uint8_t ram_command,
                                     const uint8_t image[NC_IMAGE_SIZE],
                                     uint16_t rows)
{
    if (rows > NC_IMAGE_WIDTH) {
        return EPD_IO_ERROR;
    }

    const uint16_t row_bytes = (uint16_t)(NC_IMAGE_HEIGHT / 8U);
    const uint16_t image_bytes = (uint16_t)(rows * row_bytes);
    epd_result_t result = reset_ram_address();
    if (result != EPD_OK) {
        return result;
    }
    result = command(ram_command);

    for (uint16_t offset = 0U; (result == EPD_OK) && (offset < image_bytes);) {
        const uint16_t remaining = (uint16_t)(image_bytes - offset);
        const uint16_t chunk = remaining > 256U ? 256U : remaining;
        result = send_bytes(true, &image[offset], chunk);
        offset = (uint16_t)(offset + chunk);
    }

    uint8_t white[32];
    for (size_t i = 0U; i < sizeof(white); ++i) {
        white[i] = 0xFFU;
    }
    for (uint16_t offset = image_bytes;
         (result == EPD_OK) && (offset < NC_IMAGE_SIZE);) {
        const uint16_t remaining = (uint16_t)(NC_IMAGE_SIZE - offset);
        const uint16_t chunk = remaining > sizeof(white) ? sizeof(white) : remaining;
        result = send_bytes(true, white, chunk);
        offset = (uint16_t)(offset + chunk);
    }
    return result;
}

epd_result_t epd_ssd1680_write_frame(const uint8_t image[NC_IMAGE_SIZE])
{
    return write_frame_ram(0x24U, image); /* Current/BW RAM. */
}

epd_result_t epd_ssd1680_write_previous_frame(const uint8_t image[NC_IMAGE_SIZE])
{
    return write_frame_ram(0x26U, image); /* Previous image for Mode 2. */
}

epd_result_t epd_ssd1680_write_solid(uint8_t value)
{
    return write_solid_ram(0x24U, value); /* Current/BW RAM. */
}

epd_result_t epd_ssd1680_write_frame_prefix(const uint8_t image[NC_IMAGE_SIZE],
                                             uint16_t rows)
{
    return write_prefix_ram(0x24U, image, rows);
}

epd_result_t epd_ssd1680_write_previous_frame_prefix(
    const uint8_t image[NC_IMAGE_SIZE], uint16_t rows)
{
    return write_prefix_ram(0x26U, image, rows);
}

epd_result_t epd_ssd1680_write_previous_solid(uint8_t value)
{
    return write_solid_ram(0x26U, value);
}

epd_result_t epd_ssd1680_prepare_partial(void)
{
    /*
     * The Good Display partial-update demo resets the panel and changes the
     * border waveform before writing the new 0x24 image. Controller RAM is
     * retained by this reset, so 0x26 remains the differential baseline.
     */
    HAL_GPIO_WritePin(EPD_RST_PORT, EPD_RST_PIN, GPIO_PIN_RESET);
    HAL_Delay(10U);
    HAL_GPIO_WritePin(EPD_RST_PORT, EPD_RST_PIN, GPIO_PIN_SET);
    HAL_Delay(10U);

    epd_result_t result = epd_ssd1680_wait_ready(EPD_BUSY_TIMEOUT_MS, false);
    static const uint8_t partial_border[] = {0x80U};
    if (result == EPD_OK) {
        result = command_data(0x3CU, partial_border, sizeof(partial_border));
    }
    return result;
}

static epd_result_t activate(uint8_t update_control2)
{
    epd_result_t result = command_data(0x22U, &update_control2, 1U);
    if (result == EPD_OK) {
        result = command(0x20U); /* MASTER_ACTIVATION */
    }
    return result;
}

epd_result_t epd_ssd1680_start_full(void)
{
    /* Mode 1: load temperature, load OTP LUT and update display. */
    return activate(0xF7U);
}

epd_result_t epd_ssd1680_start_partial(void)
{
    /* Good Display one-shot Mode 2 sequence, including analog/clock power-off. */
    return activate(0xFFU);
}

epd_result_t epd_ssd1680_start_gray4(void)
{
    /* Good Display's GDEY029T94 four-gray update sequence. */
    return activate(0xC7U);
}

void epd_ssd1680_deep_sleep(void)
{
    const uint8_t mode1 = 0x01U;
    (void)command_data(0x10U, &mode1, 1U);
    HAL_Delay(2U);
}
