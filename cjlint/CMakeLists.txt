cmake_minimum_required(VERSION 3.14.1)
project(cjlint LANGUAGES NONE)

# The product is Cangjie. src/ retains the fixed C++ behavior reference only.
find_program(CJLINT_NODE NAMES node)
if(NOT CJLINT_NODE)
    message(FATAL_ERROR "Node.js is required for the cjlint build driver")
endif()
set(CJLINT_FRONTEND_SOURCE "" CACHE PATH "Fixed read-only cjcj frontend source")
set(CJLINT_FRONTEND_REF "" CACHE STRING "Full commit of the frontend producer")
set(CJLINT_FRONTEND_ARTIFACTS "" CACHE PATH "Normal complete frontend CJO/archive root")
set(CJLINT_FRONTEND_RUNTIME_OBJECT "" CACHE FILEPATH "Normal frontend runtime configuration object")
set(CJLINT_LLVM_SHIM "" CACHE FILEPATH "Normal frontend LLVM infrastructure object")
set(CJLINT_LLVM_LIBRARY "" CACHE FILEPATH "Matching frontend LLVM shared library")
set(CJLINT_ANALYSIS_SDK "" CACHE PATH "SDK modules to analyze, separate from the host execution SDK")
set(CJLINT_JOBS "4" CACHE STRING "Jobs for a normal frontend dependency build")
if(NOT CANGJIE_HOME AND DEFINED ENV{CANGJIE_HOME})
    set(CANGJIE_HOME "$ENV{CANGJIE_HOME}")
endif()
if(NOT EXISTS "${CANGJIE_HOME}/bin/cjc")
    message(FATAL_ERROR "Set CANGJIE_HOME to the host Cangjie SDK")
endif()
if(NOT EXISTS "${CJLINT_FRONTEND_SOURCE}/packages/parse/cjpm.toml")
    message(FATAL_ERROR "CJLINT_FRONTEND_SOURCE must select the fixed Cangjie frontend source")
endif()
string(LENGTH "${CJLINT_FRONTEND_REF}" frontend_ref_length)
if(NOT frontend_ref_length EQUAL 40 OR NOT CJLINT_FRONTEND_REF MATCHES "^[0-9a-f]+$")
    message(FATAL_ERROR "CJLINT_FRONTEND_REF must identify the frontend producer with a full commit")
endif()
if(NOT CJLINT_JOBS MATCHES "^[1-9][0-9]*$")
    message(FATAL_ERROR "CJLINT_JOBS must be positive")
endif()
set(cangjie_build "${CMAKE_CURRENT_BINARY_DIR}/cangjie")
set(frontend_artifact_args)
if(CJLINT_FRONTEND_ARTIFACTS)
    list(APPEND frontend_artifact_args --frontend-artifacts "${CJLINT_FRONTEND_ARTIFACTS}")
endif()
foreach(required_input CJLINT_FRONTEND_ARTIFACTS CJLINT_FRONTEND_RUNTIME_OBJECT CJLINT_LLVM_SHIM CJLINT_LLVM_LIBRARY CJLINT_ANALYSIS_SDK)
    if(NOT EXISTS "${${required_input}}")
        message(FATAL_ERROR "${required_input} must select a normal full frontend producer input")
    endif()
endforeach()
file(GLOB_RECURSE cjlint_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/cangjie/src/*.cj")
file(GLOB cjlint_configs CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/config/*")
add_custom_command(OUTPUT "${cangjie_build}/product.json"
    COMMAND "${CJLINT_NODE}" "${CMAKE_CURRENT_SOURCE_DIR}/build/build.mjs" build
        --sdk "${CANGJIE_HOME}" --frontend-source "${CJLINT_FRONTEND_SOURCE}"
        --frontend-ref "${CJLINT_FRONTEND_REF}" --build-dir "${cangjie_build}"
        --jobs "${CJLINT_JOBS}" ${frontend_artifact_args}
        --frontend-runtime-object "${CJLINT_FRONTEND_RUNTIME_OBJECT}"
        --llvm-shim "${CJLINT_LLVM_SHIM}" --llvm-library "${CJLINT_LLVM_LIBRARY}"
        --analysis-sdk "${CJLINT_ANALYSIS_SDK}"
    DEPENDS ${cjlint_sources} ${cjlint_configs} "${CMAKE_CURRENT_SOURCE_DIR}/build/build.mjs"
    VERBATIM USES_TERMINAL)
add_custom_target(cjlint ALL DEPENDS "${cangjie_build}/product.json")
install(CODE "
    execute_process(COMMAND \"${CJLINT_NODE}\" \"${CMAKE_CURRENT_SOURCE_DIR}/build/build.mjs\" install
        --build-dir \"${cangjie_build}\" --prefix \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}\"
        --analysis-sdk \"${CJLINT_ANALYSIS_SDK}\"
        RESULT_VARIABLE install_rc)
    if(NOT install_rc EQUAL 0)
        message(FATAL_ERROR \"Cangjie cjlint install failed: \${install_rc}\")
    endif()
")

# Package the same normal install tree; CPack executes the install rule above.
set(CPACK_GENERATOR "TGZ")
set(CPACK_PACKAGE_NAME "cjlint")
set(CPACK_PACKAGE_VERSION "1.3.0-alpha.08")
set(CPACK_PACKAGE_FILE_NAME "cjlint-${CPACK_PACKAGE_VERSION}-${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}")
set(CPACK_PACKAGING_INSTALL_PREFIX "/")
include(CPack)
