#include "board.h"

static volatile bool epd_busy_edge;
static volatile bool nfc_gpo_edge;

void board_early_epd_power_off(void)
{
    RCC->IOPENR |= RCC_IOPENR_GPIOAEN;
    (void)RCC->IOPENR;
    GPIOA->MODER = (GPIOA->MODER & ~(3UL << (6U * 2U))) |
                   (1UL << (6U * 2U));
    GPIOA->OTYPER &= ~GPIO_OTYPER_OT6;
    GPIOA->BSRR = (uint32_t)GPIO_PIN_6 << 16U;
}

void board_epd_bus_hiz(void)
{
    GPIO_InitTypeDef gpio = {0};
    gpio.Pin = EPD_CS_PIN | EPD_DC_PIN | EPD_RST_PIN | EPD_SCK_PIN | EPD_MOSI_PIN;
    gpio.Mode = GPIO_MODE_ANALOG;
    gpio.Pull = GPIO_NOPULL;
    HAL_GPIO_Init(GPIOA, &gpio);
}

void board_epd_bus_active(void)
{
    GPIO_InitTypeDef gpio = {0};

    HAL_GPIO_WritePin(GPIOA, EPD_CS_PIN, GPIO_PIN_SET);
    HAL_GPIO_WritePin(GPIOA, EPD_DC_PIN, GPIO_PIN_RESET);
    HAL_GPIO_WritePin(GPIOA, EPD_RST_PIN, GPIO_PIN_SET);
    gpio.Pin = EPD_CS_PIN | EPD_DC_PIN | EPD_RST_PIN;
    gpio.Mode = GPIO_MODE_OUTPUT_PP;
    gpio.Pull = GPIO_NOPULL;
    gpio.Speed = GPIO_SPEED_FREQ_LOW;
    HAL_GPIO_Init(GPIOA, &gpio);

    gpio.Pin = EPD_SCK_PIN | EPD_MOSI_PIN;
    gpio.Mode = GPIO_MODE_AF_PP;
    gpio.Pull = GPIO_NOPULL;
    gpio.Speed = GPIO_SPEED_FREQ_LOW;
    gpio.Alternate = GPIO_AF0_SPI1;
    HAL_GPIO_Init(GPIOA, &gpio);
}

void board_gpio_init(void)
{
    __HAL_RCC_GPIOA_CLK_ENABLE();
    __HAL_RCC_GPIOB_CLK_ENABLE();

    HAL_GPIO_WritePin(EPD_POWER_EN_PORT, EPD_POWER_EN_PIN, GPIO_PIN_RESET);
    GPIO_InitTypeDef gpio = {0};
    gpio.Pin = EPD_POWER_EN_PIN;
    gpio.Mode = GPIO_MODE_OUTPUT_PP;
    gpio.Pull = GPIO_NOPULL;
    gpio.Speed = GPIO_SPEED_FREQ_LOW;
    HAL_GPIO_Init(EPD_POWER_EN_PORT, &gpio);

    gpio.Pin = EPD_BUSY_PIN;
    gpio.Mode = GPIO_MODE_IT_RISING_FALLING;
    gpio.Pull = GPIO_NOPULL;
    HAL_GPIO_Init(EPD_BUSY_PORT, &gpio);

    gpio.Pin = NFC_GPO_PIN;
    gpio.Mode = GPIO_MODE_IT_RISING_FALLING;
    gpio.Pull = GPIO_NOPULL;
    HAL_GPIO_Init(NFC_GPO_PORT, &gpio);

    board_epd_bus_hiz();
    HAL_NVIC_SetPriority(EXTI4_15_IRQn, 2U, 0U);
    HAL_NVIC_EnableIRQ(EXTI4_15_IRQn);
}

void board_epd_power_on(void)
{
    HAL_GPIO_WritePin(EPD_POWER_EN_PORT, EPD_POWER_EN_PIN, GPIO_PIN_SET);
}

void board_epd_power_off(void)
{
    board_epd_bus_hiz();
    HAL_GPIO_WritePin(EPD_POWER_EN_PORT, EPD_POWER_EN_PIN, GPIO_PIN_RESET);
}

bool board_epd_is_busy(void)
{
    return HAL_GPIO_ReadPin(EPD_BUSY_PORT, EPD_BUSY_PIN) == GPIO_PIN_SET;
}

void board_note_epd_busy_edge(void)
{
    epd_busy_edge = true;
}

void board_note_nfc_gpo_edge(void)
{
    nfc_gpo_edge = true;
}

bool board_take_epd_busy_edge(void)
{
    const bool value = epd_busy_edge;
    epd_busy_edge = false;
    return value;
}

bool board_take_nfc_gpo_edge(void)
{
    const bool value = nfc_gpo_edge;
    nfc_gpo_edge = false;
    return value;
}
