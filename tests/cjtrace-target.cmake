# Test the same module and SDK paths that the install rules consume. The
# compiler itself isn't invoked in script mode.
cmake_minimum_required(VERSION 3.16.3)
set(cjc_path "${CMAKE_CURRENT_BINARY_DIR}/selected sdk/bin/cjc")
set(CMAKE_HOST_SYSTEM_PROCESSOR "${HOST_CPU}")
set(CMAKE_SYSTEM_PROCESSOR "${TARGET_CPU}")
set(CMAKE_SYSTEM_NAME "${SYSTEM}")
include("${CMAKE_CURRENT_LIST_DIR}/../packages/cjtrace-recover/cmake/modules/CangjieTarget.cmake")
message(STATUS "${SYSTEM} (${HOST_CPU} -> ${TARGET_CPU}): ${CANGJIE_DYNAMIC_LIBRARY_PATH}")
if(NOT CANGJIE_LIB_TRIPLE STREQUAL EXPECTED OR
   NOT CANGJIE_DYNAMIC_LIBRARY_PATH STREQUAL "${CMAKE_CURRENT_BINARY_DIR}/selected sdk/runtime/lib/${EXPECTED}" OR
   NOT CANGJIE_STATIC_LIBRARY_PATH STREQUAL "${CMAKE_CURRENT_BINARY_DIR}/selected sdk/lib/${EXPECTED}")
    message(FATAL_ERROR "expected SDK tuple ${EXPECTED}, got ${CANGJIE_LIB_TRIPLE}")
endif()
