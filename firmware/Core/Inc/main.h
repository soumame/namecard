#ifndef NAMECARD_MAIN_H
#define NAMECARD_MAIN_H

#include "stm32g0xx_hal.h"

extern ADC_HandleTypeDef hadc1;
extern I2C_HandleTypeDef hi2c1;
extern SPI_HandleTypeDef hspi1;

void Error_Handler(void);

#endif
