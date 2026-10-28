cmake_minimum_required(VERSION 3.19)
project(cjhead NONE)
find_program(ZX_EXECUTABLE zx REQUIRED)
set(CJHEAD_CJC "$ENV{CANGJIE_HOME}/bin/cjc" CACHE FILEPATH "Cangjie compiler")
set(CJHEAD_FRONTEND_DIR "" CACHE PATH "Compiled cjcj Cangjie packages")
set(CJHEAD_FRONTEND_COMMIT "" CACHE STRING "Compiler source commit")
set(CJHEAD_SOURCE_COMMIT "" CACHE STRING "Tools source commit for build facts")
set(CJHEAD_LLVM_SHIM "" CACHE FILEPATH "Compiler LLVM boundary object")
set(CJHEAD_RUNTIME_CONFIG "" CACHE FILEPATH "Compiler runtime configuration object, when required by the frontend")
set(CJHEAD_LLVM_LIBRARY "" CACHE FILEPATH "LLVM library")
set(CJHEAD_RUNTIME_DIR "" CACHE PATH "Runtime shared libraries to install")
set(CJHEAD_JOBS "4" CACHE STRING "Compiler jobs")
set(CJHEAD_BUILD_DIR "${CMAKE_BINARY_DIR}/product")
if(WIN32)
  set(CJHEAD_EXE cjhead.exe)
else()
  set(CJHEAD_EXE cjhead)
endif()
file(GLOB CJHEAD_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cj")
file(GLOB_RECURSE CJHEAD_FRONTEND_INPUTS CONFIGURE_DEPENDS
  "${CJHEAD_FRONTEND_DIR}/*.cjo" "${CJHEAD_FRONTEND_DIR}/*.a")
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/cjhead-build-inputs.txt" CONTENT
  "${CJHEAD_CJC}\n${CJHEAD_FRONTEND_DIR}\n${CJHEAD_FRONTEND_COMMIT}\n${CJHEAD_SOURCE_COMMIT}\n${CJHEAD_LLVM_SHIM}\n${CJHEAD_RUNTIME_CONFIG}\n${CJHEAD_LLVM_LIBRARY}\n${CJHEAD_RUNTIME_DIR}\n${CJHEAD_JOBS}\n")
add_custom_command(OUTPUT "${CJHEAD_BUILD_DIR}/${CJHEAD_EXE}"
  COMMAND "${ZX_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/build/build.mjs" build
    --cjc "${CJHEAD_CJC}" --frontend-dir "${CJHEAD_FRONTEND_DIR}"
    --frontend-commit "${CJHEAD_FRONTEND_COMMIT}" --shim "${CJHEAD_LLVM_SHIM}"
    --source-commit "${CJHEAD_SOURCE_COMMIT}"
    --runtime-config "${CJHEAD_RUNTIME_CONFIG}"
    --llvm-lib "${CJHEAD_LLVM_LIBRARY}" --runtime-dir "${CJHEAD_RUNTIME_DIR}"
    --build-dir "${CJHEAD_BUILD_DIR}" --jobs "${CJHEAD_JOBS}"
  DEPENDS ${CJHEAD_SOURCES} ${CJHEAD_FRONTEND_INPUTS} "${CJHEAD_CJC}"
    "${CMAKE_BINARY_DIR}/cjhead-build-inputs.txt"
    "${CJHEAD_LLVM_SHIM}" "${CJHEAD_RUNTIME_CONFIG}" "${CJHEAD_LLVM_LIBRARY}"
    "${CMAKE_CURRENT_SOURCE_DIR}/build/build.mjs"
  VERBATIM)
add_custom_target(cjhead ALL DEPENDS "${CJHEAD_BUILD_DIR}/${CJHEAD_EXE}")
install(CODE "execute_process(COMMAND \"${ZX_EXECUTABLE}\" \"${CMAKE_CURRENT_SOURCE_DIR}/build/build.mjs\" install --build-dir \"${CJHEAD_BUILD_DIR}\" --prefix \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}\" RESULT_VARIABLE rc)\nif(NOT rc EQUAL 0)\nmessage(FATAL_ERROR \"cjhead install failed: \${rc}\")\nendif()")
