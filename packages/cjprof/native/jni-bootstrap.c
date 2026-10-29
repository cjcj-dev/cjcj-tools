// Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
// Runtime startup only. All JNI models and profiling algorithms are Cangjie.
#include <jni.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved)
{
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    Dl_info self;
    char library[PATH_MAX];
    if (!dladdr((void *)&JNI_OnLoad, &self) || !self.dli_fname) return JNI_ERR;
    const char *slash = strrchr(self.dli_fname, '/');
    if (!slash) return JNI_ERR;
    int count = snprintf(library, sizeof(library), "%.*s/libcjprof-cangjie.so",
                         (int)(slash - self.dli_fname), self.dli_fname);
    if (count < 0 || (size_t)count >= sizeof(library)) return JNI_ERR;
    struct RuntimeParam parameters = {0};
    parameters.logParam.logLevel = RTLOG_ERROR;
    int result = InitCJRuntime(&parameters);
    if (result != E_OK) { fprintf(stderr, "cjprof InitCJRuntime failed: %d\n", result); return JNI_ERR; }
    result = LoadCJLibraryWithInit(library);
    if (result != E_OK) { fprintf(stderr, "cjprof LoadCJLibraryWithInit failed: %d\n", result); return JNI_ERR; }
    // JNI exports are resolved from this library's Cangjie DT_NEEDED dependency.
    // Do not FiniCJRuntime/UnloadCJLibrary: JVM unload does not own the process runtime.
    return JNI_VERSION_1_6;
}
