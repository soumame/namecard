#ifndef NAMECARD_POWER_MONITOR_H
#define NAMECARD_POWER_MONITOR_H

#include <stdint.h>
#include "main.h"

HAL_StatusTypeDef power_monitor_init(ADC_HandleTypeDef *adc);
uint16_t power_monitor_read_vdd_mv(void);
void power_monitor_reset_minimum(void);
uint16_t power_monitor_sample_minimum(void);
uint16_t power_monitor_minimum_mv(void);

#endif
