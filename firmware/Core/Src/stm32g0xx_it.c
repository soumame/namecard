#include "main.h"
#include "board.h"

void NMI_Handler(void)
{
}

void HardFault_Handler(void)
{
    board_epd_power_off();
    while (1) {
    }
}

void SVC_Handler(void)
{
}

void PendSV_Handler(void)
{
}

void SysTick_Handler(void)
{
    HAL_IncTick();
}

void EXTI4_15_IRQHandler(void)
{
    HAL_GPIO_EXTI_IRQHandler(EPD_BUSY_PIN);
    HAL_GPIO_EXTI_IRQHandler(NFC_GPO_PIN);
}

void HAL_GPIO_EXTI_Rising_Callback(uint16_t pin)
{
    if (pin == EPD_BUSY_PIN) {
        board_note_epd_busy_edge();
    } else if (pin == NFC_GPO_PIN) {
        board_note_nfc_gpo_edge();
    }
}

void HAL_GPIO_EXTI_Falling_Callback(uint16_t pin)
{
    HAL_GPIO_EXTI_Rising_Callback(pin);
}
