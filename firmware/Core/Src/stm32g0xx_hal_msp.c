#include "main.h"

void HAL_MspInit(void)
{
    __HAL_RCC_SYSCFG_CLK_ENABLE();
    __HAL_RCC_PWR_CLK_ENABLE();
    HAL_NVIC_SetPriority(PendSV_IRQn, 3U, 0U);
}

void HAL_ADC_MspInit(ADC_HandleTypeDef *hadc)
{
    if (hadc->Instance == ADC1) {
        __HAL_RCC_ADC_CLK_ENABLE();
    }
}

void HAL_ADC_MspDeInit(ADC_HandleTypeDef *hadc)
{
    if (hadc->Instance == ADC1) {
        __HAL_RCC_ADC_CLK_DISABLE();
    }
}

void HAL_I2C_MspInit(I2C_HandleTypeDef *hi2c)
{
    if (hi2c->Instance != I2C1) {
        return;
    }
    __HAL_RCC_GPIOB_CLK_ENABLE();
    GPIO_InitTypeDef gpio = {0};
    gpio.Pin = GPIO_PIN_6 | GPIO_PIN_7;
    gpio.Mode = GPIO_MODE_AF_OD;
    gpio.Pull = GPIO_NOPULL;
    gpio.Speed = GPIO_SPEED_FREQ_LOW;
    gpio.Alternate = GPIO_AF6_I2C1;
    HAL_GPIO_Init(GPIOB, &gpio);
    __HAL_RCC_I2C1_CLK_ENABLE();
}

void HAL_I2C_MspDeInit(I2C_HandleTypeDef *hi2c)
{
    if (hi2c->Instance == I2C1) {
        __HAL_RCC_I2C1_CLK_DISABLE();
        HAL_GPIO_DeInit(GPIOB, GPIO_PIN_6 | GPIO_PIN_7);
    }
}

void HAL_SPI_MspInit(SPI_HandleTypeDef *hspi)
{
    if (hspi->Instance == SPI1) {
        /* Pins are deliberately configured only while the switched EPD rail is
           on, preventing back-power through CS/DC/RST/SCK/MOSI. */
        __HAL_RCC_SPI1_CLK_ENABLE();
    }
}

void HAL_SPI_MspDeInit(SPI_HandleTypeDef *hspi)
{
    if (hspi->Instance == SPI1) {
        __HAL_RCC_SPI1_CLK_DISABLE();
    }
}
