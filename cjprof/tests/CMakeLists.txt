# Tests must consume an independently installed prefix, never build-tree binaries.
set(CJPROF_TEST_PREFIX "" CACHE PATH "Installed cjprof directory to test")
if(NOT IS_ABSOLUTE "${CJPROF_TEST_PREFIX}")
  message(FATAL_ERROR "BUILD_TESTING requires CJPROF_TEST_PREFIX with an independently installed product")
endif()
# Installed and unpacked consumers keep independent inputs and raw evidence.
string(SHA256 consumer_id "${CJPROF_TEST_PREFIX}")
set(consumer_work "${CMAKE_CURRENT_BINARY_DIR}/${consumer_id}")
add_test(NAME cjprof-installed-cli COMMAND "${NODE_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/cangjie-functional.mjs"
  "${CJPROF_TEST_PREFIX}/bin/cjprof" "${consumer_work}/cli")
add_test(NAME cjprof-installed-http COMMAND "${NODE_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/cangjie-http.mjs"
  "${CJPROF_TEST_PREFIX}" "${consumer_work}/cli/diamond-2-8.data" "${consumer_work}/http")
add_test(NAME cjprof-installed-jni COMMAND "${NODE_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/cangjie-jni.mjs"
  "${CJPROF_TEST_PREFIX}" "${CJPROF_JNI_HOME}" "${consumer_work}/cli" "${consumer_work}/jni")
add_test(NAME cjprof-installed-dump COMMAND "${NODE_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/cangjie-dump.mjs"
  "${CJPROF_TEST_PREFIX}" "${consumer_work}/dump")
add_test(NAME cjprof-installed-record COMMAND "${NODE_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/cangjie-record.mjs"
  "${CJPROF_TEST_PREFIX}" "${consumer_work}/record")
add_test(NAME cjprof-installed-categories COMMAND "${NODE_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/cangjie-categories.mjs"
  "${CJPROF_TEST_PREFIX}" "${consumer_work}/categories")
add_test(NAME cjprof-installed-cli-compat COMMAND "${NODE_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/cangjie-cli-compat.mjs"
  "${CJPROF_TEST_PREFIX}" "${consumer_work}/cli" "${consumer_work}/cli-compat")
add_test(NAME cjprof-installed-boundaries COMMAND "${NODE_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/cangjie-boundaries.mjs"
  "${CJPROF_TEST_PREFIX}" "${CJPROF_JNI_HOME}" "${consumer_work}/boundaries")

set_tests_properties(cjprof-installed-http cjprof-installed-jni cjprof-installed-cli-compat PROPERTIES DEPENDS cjprof-installed-cli)
set_tests_properties(cjprof-installed-cli cjprof-installed-http cjprof-installed-jni cjprof-installed-dump cjprof-installed-record cjprof-installed-categories cjprof-installed-cli-compat cjprof-installed-boundaries PROPERTIES
  ENVIRONMENT "CANGJIE_HOME=${CJPROF_SDK};LD_LIBRARY_PATH=${CJPROF_SDK}/runtime/lib/linux_x86_64_cjnative:${CJPROF_SDK}/tools/lib")
