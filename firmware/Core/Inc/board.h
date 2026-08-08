#ifndef NAMECARD_BOARD_H
#define NAMECARD_BOARD_H

#include <stdbool.h>
#include "main.h"

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
#define NFC_GPO_PORT GPIOB

void board_early_epd_power_off(void);
void board_gpio_init(void);
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
