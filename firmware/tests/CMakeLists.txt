cmake_minimum_required(VERSION 3.22)
project(namecard_protocol_tests C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
enable_testing()

add_executable(test_protocol
    test_protocol.c
    ../Core/Src/crc.c
    ../Core/Src/fixed_image.c
    ../Core/Src/nc_protocol.c
)
target_include_directories(test_protocol PRIVATE ../Core/Inc)
target_compile_options(test_protocol PRIVATE -Wall -Wextra -Werror -UNDEBUG)
add_test(NAME protocol COMMAND test_protocol)
