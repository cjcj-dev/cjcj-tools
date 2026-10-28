# Copyright (c) Huawei Technologies Co., Ltd. 2025. All rights reserved.
# Licensed under Apache-2.0 with Runtime Library Exception.
cmake_minimum_required(VERSION 3.14.1)
project(cjfmt LANGUAGES NONE)

# The sole producer is CJPM. No C++ compiler or language-server library is used.
find_program(CJFMT_NODE NAMES node)
if(NOT CJFMT_NODE)
    message(FATAL_ERROR "Node.js is required to run the zx ESM build entry")
endif()
foreach(name CANGJIE_HOME CJFMT_FRONTEND_CJO CJFMT_FRONTEND_LIB CJFMT_FRONTEND_NATIVE CJFMT_FRONTEND_REF CJFMT_SOURCE_REF)
    if(NOT DEFINED ${name} AND DEFINED ENV{${name}})
        set(${name} "$ENV{${name}}" CACHE STRING "Cangjie producer input")
    endif()
endforeach()
if(NOT CJFMT_FRONTEND_LIB)
    set(CJFMT_FRONTEND_LIB "${CJFMT_FRONTEND_CJO}")
endif()
foreach(name CANGJIE_HOME CJFMT_FRONTEND_CJO CJFMT_FRONTEND_LIB)
    if(NOT IS_DIRECTORY "${${name}}")
        message(FATAL_ERROR "${name} must name an existing directory in the selected SDK/frontend closure")
    endif()
endforeach()
if(NOT CJFMT_SOURCE_REF)
    execute_process(COMMAND git rev-parse HEAD WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        OUTPUT_VARIABLE CJFMT_SOURCE_REF OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
endif()
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "Debug or Release" FORCE)
endif()
string(TOLOWER "${CMAKE_BUILD_TYPE}" cjfmt_mode)
if(NOT cjfmt_mode MATCHES "^(debug|release)$")
    message(FATAL_ERROR "CMAKE_BUILD_TYPE must be Debug or Release")
endif()
set(CJFMT_JOBS 4 CACHE STRING "CJPM build parallelism")
set(CJFMT_TARGET x86_64-unknown-linux-gnu CACHE STRING "Target of the selected frontend binary closure")
option(CJFMT_CODE_COVERAGE "Enable Cangjie compiler coverage" OFF)
set(cjfmt_args --sdk "${CANGJIE_HOME}" --frontend-cjo "${CJFMT_FRONTEND_CJO}"
    --frontend-lib "${CJFMT_FRONTEND_LIB}" --build-dir "${CMAKE_CURRENT_BINARY_DIR}/cangjie"
    --output "${CMAKE_CURRENT_BINARY_DIR}/bin/cjfmt" --build-type "${cjfmt_mode}" --jobs "${CJFMT_JOBS}" --target "${CJFMT_TARGET}")
foreach(pair "frontend-native;CJFMT_FRONTEND_NATIVE" "frontend-ref;CJFMT_FRONTEND_REF" "source-ref;CJFMT_SOURCE_REF")
    list(GET pair 0 flag)
    list(GET pair 1 variable)
    if(${variable})
        list(APPEND cjfmt_args "--${flag}" "${${variable}}")
    endif()
endforeach()
if(CJFMT_CODE_COVERAGE)
    list(APPEND cjfmt_args --coverage)
endif()
file(GLOB cjfmt_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/cangjie/*.cj")
file(GLOB_RECURSE cjfmt_frontend CONFIGURE_DEPENDS
    "${CJFMT_FRONTEND_CJO}/*.cjo" "${CJFMT_FRONTEND_LIB}/*.a")
# Reconfiguration, including Debug/Release or closure selection, invalidates the producer.
file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/cjfmt-producer-inputs.txt" CONTENT "${cjfmt_args}\n")
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/bin/cjfmt" "${CMAKE_CURRENT_BINARY_DIR}/cjfmt-build.json"
    COMMAND "${CMAKE_COMMAND}" -E remove "${CMAKE_CURRENT_BINARY_DIR}/cjfmt-ready"
    COMMAND "${CJFMT_NODE}" "${CMAKE_CURRENT_SOURCE_DIR}/build/cangjie.mjs" build ${cjfmt_args}
    COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_CURRENT_BINARY_DIR}/cangjie/inputs.json" "${CMAKE_CURRENT_BINARY_DIR}/cjfmt-build.json"
    COMMAND "${CMAKE_COMMAND}" -E touch "${CMAKE_CURRENT_BINARY_DIR}/cjfmt-ready"
    DEPENDS ${cjfmt_sources} ${cjfmt_frontend} ${CJFMT_FRONTEND_NATIVE}
        "${CMAKE_CURRENT_BINARY_DIR}/cjfmt-producer-inputs.txt"
        "${CMAKE_CURRENT_SOURCE_DIR}/build/cangjie.mjs" "${CMAKE_CURRENT_SOURCE_DIR}/build/cjpm.toml.in"
    COMMENT "Building cjfmt with the Cangjie frontend and CJPM" VERBATIM)
add_custom_target(cjfmt ALL DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/bin/cjfmt" "${CMAKE_CURRENT_BINARY_DIR}/cjfmt-build.json")
# Install consumes an already built product; missing outputs are errors.
install(CODE "if(NOT EXISTS \"${CMAKE_CURRENT_BINARY_DIR}/cjfmt-ready\")\nmessage(FATAL_ERROR \"cjfmt has no completed Cangjie build; install never builds implicitly\")\nendif()")
install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/bin/cjfmt" DESTINATION bin)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/cjfmt-build.json" DESTINATION .)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/config/cangjie-format.toml" DESTINATION config)
