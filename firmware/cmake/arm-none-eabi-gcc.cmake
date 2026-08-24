set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(NAMECARD_ARM_TOOLCHAIN_ROOT "" CACHE PATH
    "Arm GNU Toolchain root (directory containing bin/arm-none-eabi-gcc)")

set(_namecard_arm_toolchain_hints)
if(NAMECARD_ARM_TOOLCHAIN_ROOT)
    list(APPEND _namecard_arm_toolchain_hints
         "${NAMECARD_ARM_TOOLCHAIN_ROOT}/bin")
endif()
if(DEFINED ENV{ARM_NONE_EABI_ROOT})
    list(APPEND _namecard_arm_toolchain_hints
         "$ENV{ARM_NONE_EABI_ROOT}/bin")
endif()
if(DEFINED ENV{HOME})
    # sudo不要で展開したArm公式ツールチェーンの標準位置。
    list(APPEND _namecard_arm_toolchain_hints
         "$ENV{HOME}/Library/ArmGNUToolchain/current/bin")
endif()

find_program(CMAKE_C_COMPILER arm-none-eabi-gcc
             HINTS ${_namecard_arm_toolchain_hints} REQUIRED)
find_program(CMAKE_ASM_COMPILER arm-none-eabi-gcc
             HINTS ${_namecard_arm_toolchain_hints} REQUIRED)
find_program(CMAKE_OBJCOPY arm-none-eabi-objcopy
             HINTS ${_namecard_arm_toolchain_hints} REQUIRED)
find_program(CMAKE_SIZE arm-none-eabi-size
             HINTS ${_namecard_arm_toolchain_hints} REQUIRED)

set(CMAKE_EXECUTABLE_SUFFIX ".elf")
