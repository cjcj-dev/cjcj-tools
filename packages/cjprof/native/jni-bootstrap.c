// Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
// Runtime startup only. All JNI models and profiling algorithms are Cangjie.
#include <jni.h>
#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#else
#include <dlfcn.h>
#endif
#include <stdio.h>
#include <string.h>
#include <limits.h>

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved)
{
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
#ifdef _WIN32
    // Resolve the implementation beside this DLL, independent of JVM cwd.
    static const wchar_t sibling[] = L"libcjprof-cangjie.dll";
    static const char module_anchor = 0;
    HMODULE module;
    wchar_t wide[32768];
    char library[4 * 32768];
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCWSTR)&module_anchor, &module)) return JNI_ERR;
    DWORD count = GetModuleFileNameW(module, wide, 32768);
    if (!count || count >= 32768) return JNI_ERR;
    wchar_t *slash = wcsrchr(wide, L'\\');
    if (!slash || (size_t)(slash + 1 - wide) + sizeof(sibling)/sizeof(*sibling) > 32768) return JNI_ERR;
    memcpy(slash + 1, sibling, sizeof(sibling));
    // This runtime loads through LoadLibraryA. Reject lossy conversions;
    // prefer the exact long path, then try its Windows short-path spelling.
    UINT cp = GetACP();
    DWORD flags = cp == CP_UTF8 ? 0 : WC_NO_BEST_FIT_CHARS;
    BOOL lossy = FALSE;
    BOOL *substitution = cp == CP_UTF8 ? NULL : &lossy;
    if (!WideCharToMultiByte(cp, flags, wide, -1, library, sizeof(library), NULL, substitution) || lossy) {
        wchar_t shortened[32768];
        DWORD n = GetShortPathNameW(wide, shortened, 32768);
        lossy = FALSE;
        if (!n || n >= 32768 || !WideCharToMultiByte(cp, flags, shortened, -1, library,
                                                       sizeof(library), NULL, substitution) || lossy) return JNI_ERR;
    }
#else
    Dl_info self;
    char library[PATH_MAX];
    if (!dladdr((void *)&JNI_OnLoad, &self) || !self.dli_fname) return JNI_ERR;
    const char *slash = strrchr(self.dli_fname, '/');
    if (!slash) return JNI_ERR;
    int count = snprintf(library, sizeof(library), "%.*s/libcjprof-cangjie.so",
                         (int)(slash - self.dli_fname), self.dli_fname);
    if (count < 0 || (size_t)count >= sizeof(library)) return JNI_ERR;
#endif
    struct RuntimeParam parameters = {0};
    parameters.logParam.logLevel = RTLOG_ERROR;
    int result = InitCJRuntime(&parameters);
    if (result != E_OK) { fprintf(stderr, "cjprof InitCJRuntime failed: %d\n", result); return JNI_ERR; }
    result = LoadCJLibraryWithInit(library);
    if (result != E_OK) { fprintf(stderr, "cjprof LoadCJLibraryWithInit failed: %d\n", result); return JNI_ERR; }
    // ELF uses DT_NEEDED; the PE bootstrap forwards the same JNI exports.
    // Do not FiniCJRuntime/UnloadCJLibrary: JVM unload does not own the process runtime.
    return JNI_VERSION_1_6;
}
