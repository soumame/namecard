cmake_minimum_required(VERSION 3.22)
project(namecard_fw C ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(NAMECARD_BOOT_SELF_TEST "Run external-power EPD full/partial test at boot" OFF)
option(NAMECARD_PREPARE_WHITE "Perform one external-power full refresh to white" OFF)
option(NAMECARD_NFC_FIXED_TEST "Refresh a generated image from harvested power at boot" OFF)
option(NAMECARD_DIAGNOSTIC "Retain minimum VDD during refresh" ON)

# The v4 TPS63900 rail is regulated to 3.3 V.  Starting at 3.20 V preserves
# enough stored energy for a full-screen Partial refresh; the lower checks
# reject an immediate rail collapse after the EPD load switch is enabled.
set(NAMECARD_CHARGE_READY_MV 3200 CACHE STRING
    "SYS_VDD required before enabling the EPD")
set(NAMECARD_EPD_ON_MIN_MV 2850 CACHE STRING
    "Minimum SYS_VDD after enabling the EPD load switch")
set(NAMECARD_EPD_START_MIN_MV 2800 CACHE STRING
    "Minimum SYS_VDD immediately before starting a refresh")
set(NAMECARD_CHARGE_TIMEOUT_MS 15000 CACHE STRING
    "Maximum time to wait for SYS_VDD to reach the charge-ready threshold")
set(NAMECARD_NFC_BAND_ROWS 0 CACHE STRING
    "Rows refreshed per recharge cycle in the NFC fixed-image test; 0 means full frame")

if(NAMECARD_EPD_ON_MIN_MV GREATER NAMECARD_CHARGE_READY_MV)
    message(FATAL_ERROR "EPD-on threshold must not exceed charge-ready threshold")
endif()
if(NAMECARD_EPD_START_MIN_MV GREATER NAMECARD_EPD_ON_MIN_MV)
    message(FATAL_ERROR "EPD-start threshold must not exceed EPD-on threshold")
endif()
if(NAMECARD_NFC_BAND_ROWS GREATER 296)
    message(FATAL_ERROR "NFC band height must not exceed the 296-row panel width")
endif()

set(MCU_FLAGS -mcpu=cortex-m0plus -mthumb -mfloat-abi=soft)

set(HAL_SOURCES
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_adc.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_adc_ex.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_cortex.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_dma.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_exti.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_flash.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_flash_ex.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_gpio.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_i2c.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_i2c_ex.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_pwr.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_pwr_ex.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_rcc.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_rcc_ex.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_spi.c
    Drivers/STM32G0xx_HAL_Driver/Src/stm32g0xx_hal_spi_ex.c
)

set(APP_SOURCES
    Core/Src/app.c
    Core/Src/board.c
    Core/Src/crc.c
    Core/Src/display_store.c
    Core/Src/epd_ssd1680.c
    Core/Src/fixed_image.c
    Core/Src/main.c
    Core/Src/nc_protocol.c
    Core/Src/power_monitor.c
    Core/Src/st25dv.c
    Core/Src/stm32g0xx_hal_msp.c
    Core/Src/stm32g0xx_it.c
    Drivers/CMSIS/Device/ST/STM32G0xx/Source/Templates/system_stm32g0xx.c
    Drivers/CMSIS/Device/ST/STM32G0xx/Source/Templates/gcc/startup_stm32g031xx.s
)

add_executable(namecard_fw ${APP_SOURCES} ${HAL_SOURCES})
set_target_properties(namecard_fw PROPERTIES SUFFIX ".elf")
set_property(TARGET namecard_fw APPEND PROPERTY LINK_DEPENDS
             ${CMAKE_CURRENT_SOURCE_DIR}/STM32G031K6TX_FLASH.ld)

target_include_directories(namecard_fw PRIVATE
    Core/Inc
    Drivers/STM32G0xx_HAL_Driver/Inc
    Drivers/CMSIS/Device/ST/STM32G0xx/Include
    Drivers/CMSIS/Core/Include
)
target_compile_definitions(namecard_fw PRIVATE
    STM32G031xx USE_HAL_DRIVER
    NAMECARD_BOOT_SELF_TEST=$<BOOL:${NAMECARD_BOOT_SELF_TEST}>
    NAMECARD_PREPARE_WHITE=$<BOOL:${NAMECARD_PREPARE_WHITE}>
    NAMECARD_NFC_FIXED_TEST=$<BOOL:${NAMECARD_NFC_FIXED_TEST}>
    NAMECARD_DIAGNOSTIC=$<BOOL:${NAMECARD_DIAGNOSTIC}>
    NAMECARD_CHARGE_READY_MV=${NAMECARD_CHARGE_READY_MV}
    NAMECARD_EPD_ON_MIN_MV=${NAMECARD_EPD_ON_MIN_MV}
    NAMECARD_EPD_START_MIN_MV=${NAMECARD_EPD_START_MIN_MV}
    NAMECARD_CHARGE_TIMEOUT_MS=${NAMECARD_CHARGE_TIMEOUT_MS}
    NAMECARD_NFC_BAND_ROWS=${NAMECARD_NFC_BAND_ROWS}
)
target_compile_options(namecard_fw PRIVATE
    ${MCU_FLAGS} -ffunction-sections -fdata-sections -fstack-usage
    -Wall -Wextra -Werror=implicit-function-declaration
    $<$<CONFIG:Debug>:-Og;-g3>
    $<$<NOT:$<CONFIG:Debug>>:-Os>
)
target_link_options(namecard_fw PRIVATE
    ${MCU_FLAGS}
    -T${CMAKE_CURRENT_SOURCE_DIR}/STM32G031K6TX_FLASH.ld
    -Wl,--gc-sections -Wl,--cref
    -Wl,-Map=${CMAKE_CURRENT_BINARY_DIR}/namecard_fw.map
    -Wl,--print-memory-usage
    --specs=nano.specs
)

add_custom_command(TARGET namecard_fw POST_BUILD
    COMMAND ${CMAKE_OBJCOPY} -O ihex $<TARGET_FILE:namecard_fw> ${CMAKE_CURRENT_BINARY_DIR}/namecard_fw.hex
    COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:namecard_fw> ${CMAKE_CURRENT_BINARY_DIR}/namecard_fw.bin
    COMMAND ${CMAKE_SIZE} --format=berkeley $<TARGET_FILE:namecard_fw>
    VERBATIM
)
