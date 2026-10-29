# Copyright (c) Huawei Technologies Co., Ltd. 2025. All rights reserved.
# Licensed under Apache-2.0 with Runtime Library Exception.
cmake_minimum_required(VERSION 3.16.3)
project(cjtrace-recover LANGUAGES NONE)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/modules")
include(CangjieTarget)
find_program(ZX_EXECUTABLE zx REQUIRED)

# Reuse the compiler's Cangjie demangler, without bringing the AST/mangler
# front end into this tool. This is source input, never the old native library.
set(CANGJIE_MANGLE_SOURCE_DIR "$ENV{CANGJIE_MANGLE_SOURCE_DIR}" CACHE PATH
    "Directory containing the compiler packages/mangle/src Cangjie sources")
if(NOT CANGJIE_MANGLE_SOURCE_DIR)
    message(FATAL_ERROR "Set CANGJIE_MANGLE_SOURCE_DIR to packages/mangle/src from the compiler source input")
endif()
set(mangle_sources)
foreach(name CangjieDemangle DeCompression Demangler DemangleUtils MangleUtils Compression)
    list(APPEND mangle_sources "${CANGJIE_MANGLE_SOURCE_DIR}/${name}.cj")
endforeach()
set(mangle_dir "${CMAKE_CURRENT_BINARY_DIR}/demangler-source")
set(mangle_lib "${CMAKE_CURRENT_BINARY_DIR}/lib/libcjcj.mangle.a")
set(mangle_cjo "${CMAKE_CURRENT_BINARY_DIR}/lib/mangle@cjcj.cjo")
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/lib")
set(cj_flags)
if(CMAKE_BUILD_TYPE MATCHES "WithDebInfo$|^Debug$")
    list(APPEND cj_flags -g)
endif()
if(CMAKE_BUILD_TYPE MATCHES "^MinSize")
    list(APPEND cj_flags -Os)
elseif(CMAKE_BUILD_TYPE MATCHES "^Rel")
    list(APPEND cj_flags -O2)
endif()
if(CMAKE_CROSSCOMPILING)
    if(NOT CANGJIE_TRIPLE)
        message(FATAL_ERROR "CANGJIE_TRIPLE is required for cross compilation")
    endif()
    list(APPEND cj_flags "--target=${CANGJIE_TRIPLE}" "--sysroot=${CMAKE_SYSROOT}")
endif()

add_custom_command(OUTPUT "${mangle_lib}" "${mangle_cjo}"
    COMMAND "${ZX_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/build/prepare-demangler.mjs"
        "${CANGJIE_MANGLE_SOURCE_DIR}" "${mangle_dir}"
    COMMAND "${CANGJIE_COMPILER_PATH}" --package "${mangle_dir}" --module-name cjcj
        --output-type=staticlib ${cj_flags} -o "${mangle_lib}"
    DEPENDS ${mangle_sources} build/prepare-demangler.mjs build/mangle-bare-D.diff
    VERBATIM)
set(link_flags)
if(NOT RUNTIME_RPATH)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        set(RUNTIME_RPATH "$ORIGIN/../lib")
    elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        set(RUNTIME_RPATH "@loader_path/../lib")
    endif()
endif()
if(RUNTIME_RPATH)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        list(APPEND link_flags "--link-options=--disable-new-dtags -rpath ${RUNTIME_RPATH}")
    elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        list(APPEND link_flags "--link-options=-rpath ${RUNTIME_RPATH}")
    endif()
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    list(APPEND link_flags "--link-options=-z noexecstack -z relro -z now")
endif()
set(trace_binary "${CMAKE_CURRENT_BINARY_DIR}/cjtrace-recover${CMAKE_EXECUTABLE_SUFFIX}")
if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(trace_binary "${CMAKE_CURRENT_BINARY_DIR}/cjtrace-recover.exe")
endif()
add_custom_command(OUTPUT "${trace_binary}"
    COMMAND "${CANGJIE_COMPILER_PATH}" ${cj_flags}
        --import-path "${CMAKE_CURRENT_BINARY_DIR}/lib"
        "-L${CMAKE_CURRENT_BINARY_DIR}/lib" -lcjcj.mangle ${link_flags}
        "${CMAKE_CURRENT_SOURCE_DIR}/src/cjtrace-recover.cj" -o "${trace_binary}"
    DEPENDS "${mangle_lib}" "${mangle_cjo}" src/cjtrace-recover.cj
    VERBATIM)
add_custom_target(cj_cjtrace-recover ALL DEPENDS "${trace_binary}")
install(PROGRAMS "${trace_binary}" DESTINATION bin)
option(CJTRACE_BUNDLE_RUNTIME "Install the target SDK runtime dependencies with the tool" ON)
if(CJTRACE_BUNDLE_RUNTIME)
    set(runtime_destination lib)
    if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
        set(runtime_destination bin)
    endif()
    install(DIRECTORY "${CANGJIE_DYNAMIC_LIBRARY_PATH}/" DESTINATION "${runtime_destination}"
        FILES_MATCHING PATTERN "*.so*" PATTERN "*.dylib" PATTERN "*.dll")
endif()
install(FILES doc/LICENSE doc/COPYRIGHT DESTINATION share/cjtrace-recover)
