#ifndef NAMECARD_BOARD_H
#define NAMECARD_BOARD_H

#include <stdbool.h>
#include "main.h"

#define PWR_HOLD_PIN GPIO_PIN_0
#define PWR_HOLD_PORT GPIOA
#define EPD_CS_PIN GPIO_PIN_1
#define EPD_CS_PORT GPIOA
#define EPD_DC_PIN GPIO_PIN_2
#define EPD_DC_PORT GPIOA
#define EPD_RST_PIN GPIO_PIN_3
#define EPD_RST_PORT GPIOA
#define EPD_BUSY_PIN GPIO_PIN_4
#define EPD_BUSY_PORT GPIOA
#define EPD_SCK_PIN GPIO_PIN_5
#define EPD_SCK_PORT GPIOA
#define EPD_POWER_EN_PIN GPIO_PIN_6
#define EPD_POWER_EN_PORT GPIOA
#define EPD_MOSI_PIN GPIO_PIN_7
#define EPD_MOSI_PORT GPIOA
#define NFC_GPO_PIN GPIO_PIN_8
#define NFC_GPO_PORT GPIOA

void board_early_power_safe(void);
void board_gpio_init(void);
HAL_StatusTypeDef board_power_guard_init(void);
void board_power_hold_enable(void);
void board_power_hold_release(void);
void board_brownout_shutdown_isr(void);
bool board_brownout_detected(void);
void board_epd_power_on(void);
void board_epd_power_off(void);
bool board_epd_is_busy(void);
void board_epd_bus_active(void);
void board_epd_bus_hiz(void);

void board_note_epd_busy_edge(void);
void board_note_nfc_gpo_edge(void);
bool board_take_epd_busy_edge(void);
bool board_take_nfc_gpo_edge(void);

#endif
