#include "power_monitor.h"

static ADC_HandleTypeDef *vref_adc;
static uint16_t minimum_mv = UINT16_MAX;

HAL_StatusTypeDef power_monitor_init(ADC_HandleTypeDef *adc)
{
    ADC_ChannelConfTypeDef channel = {0};
    vref_adc = adc;
    if (HAL_ADCEx_Calibration_Start(adc) != HAL_OK) {
        return HAL_ERROR;
    }
    channel.Channel = ADC_CHANNEL_VREFINT;
    channel.Rank = ADC_REGULAR_RANK_1;
    channel.SamplingTime = ADC_SAMPLINGTIME_COMMON_1;
    return HAL_ADC_ConfigChannel(adc, &channel);
}

uint16_t power_monitor_read_vdd_mv(void)
{
    if ((vref_adc == NULL) || (HAL_ADC_Start(vref_adc) != HAL_OK)) {
        return 0U;
    }
    if (HAL_ADC_PollForConversion(vref_adc, 5U) != HAL_OK) {
        (void)HAL_ADC_Stop(vref_adc);
        return 0U;
    }
    const uint32_t raw = HAL_ADC_GetValue(vref_adc);
    (void)HAL_ADC_Stop(vref_adc);
    if (raw == 0U) {
        return 0U;
    }
    const uint32_t millivolts = __HAL_ADC_CALC_VREFANALOG_VOLTAGE(raw, ADC_RESOLUTION_12B);
    return millivolts > UINT16_MAX ? UINT16_MAX : (uint16_t)millivolts;
}

void power_monitor_reset_minimum(void)
{
    minimum_mv = UINT16_MAX;
}

uint16_t power_monitor_sample_minimum(void)
{
    const uint16_t current = power_monitor_read_vdd_mv();
    if ((current != 0U) && (current < minimum_mv)) {
        minimum_mv = current;
    }
    return current;
}

uint16_t power_monitor_minimum_mv(void)
{
    return minimum_mv == UINT16_MAX ? 0U : minimum_mv;
}
