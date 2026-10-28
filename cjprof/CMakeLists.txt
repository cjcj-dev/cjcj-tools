# Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
# Licensed under Apache-2.0 with Runtime Library Exception.
cmake_minimum_required(VERSION 3.16)
project(cjprof LANGUAGES NONE)
if(NOT CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux" OR NOT CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "x86_64|amd64|AMD64")
  message(FATAL_ERROR "This Cangjie producer currently supports Linux x86-64")
endif()
find_program(NODE_EXECUTABLE node REQUIRED)
set(CJPROF_SDK "$ENV{CANGJIE_HOME}" CACHE PATH "Selected compiler and matching runtime/std SDK")
set(CJPROF_JNI_HOME "$ENV{JAVA_HOME}" CACHE PATH "JDK providing the real JNI headers")
set(CJPROF_RUNTIME_HEADER "" CACHE FILEPATH "Public Cangjie.h matching the selected runtime ABI")
set(CJPROF_LOMBOK_JAR "$ENV{CJPROF_LOMBOK_JAR}" CACHE FILEPATH "Selected Lombok processor for the existing Java API")
foreach(required CJPROF_SDK CJPROF_JNI_HOME CJPROF_RUNTIME_HEADER CJPROF_LOMBOK_JAR)
  if(NOT EXISTS "${${required}}")
    message(FATAL_ERROR "Missing explicitly selected ${required}")
  endif()
endforeach()
set(product "${CMAKE_CURRENT_BINARY_DIR}/product")
file(GLOB sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/cangjie/*.cj")
file(GLOB_RECURSE assets CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/static/*")
file(GLOB_RECURSE java_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/bridge/jni/java/*.java")
set(builder "${CMAKE_CURRENT_SOURCE_DIR}/build/build.mjs")
add_custom_command(
  OUTPUT "${product}/cjprof" "${product}/libcjprof-cangjie.so" "${product}/libcjprof-jni.so" "${product}/build-facts.json" "${product}/cjprof.jar"
  COMMAND "${CMAKE_COMMAND}" -E env
    "CANGJIE_HOME=${CJPROF_SDK}"
    "LD_LIBRARY_PATH=${CJPROF_SDK}/runtime/lib/linux_x86_64_cjnative:${CJPROF_SDK}/tools/lib"
    "${NODE_EXECUTABLE}" "${builder}" build --sdk "${CJPROF_SDK}"
    --jni-home "${CJPROF_JNI_HOME}" --runtime-header "${CJPROF_RUNTIME_HEADER}" --lombok-jar "${CJPROF_LOMBOK_JAR}" --build-dir "${product}"
  DEPENDS ${sources} ${assets} ${java_sources} "${CJPROF_LOMBOK_JAR}" "${builder}" "${CMAKE_CURRENT_SOURCE_DIR}/build/jni-bootstrap.c" "${CJPROF_RUNTIME_HEADER}"
  VERBATIM)
add_custom_target(cjprof ALL DEPENDS "${product}/cjprof" "${product}/libcjprof-cangjie.so" "${product}/libcjprof-jni.so" "${product}/build-facts.json" "${product}/cjprof.jar")
install(PROGRAMS "${product}/cjprof" DESTINATION bin)
install(FILES "${product}/libcjprof-cangjie.so" "${product}/libcjprof-jni.so" DESTINATION lib)
install(DIRECTORY "${product}/config/static" DESTINATION config)
install(FILES "${product}/build-facts.json" DESTINATION .)
install(FILES "${product}/cjprof.jar" DESTINATION share/java)
option(BUILD_TESTING "Test the installed Cangjie public CLI and HTTP entry" OFF)
if(BUILD_TESTING)
  enable_testing()
  add_subdirectory(tests)
endif()
