// Copyright (c) Huawei Technologies Co., Ltd. 2025. All rights reserved.
// This source file is part of the Cangjie project, licensed under Apache-2.0
// with Runtime Library Exception.
//
// See https://cangjie-lang.cn/pages/LICENSE for license information.

package cjpm.implement

import cjpm.config.*

// Append native data for cross-compile.
func appendNativeData(buildConfig: BuildConfig, data: ModuleResolve): Unit {
    if (!buildConfig.isCrossCompile) {
        return
    }

    for (item in data.resolves) {
        // macro packages are executeed on native platform
        if (buildConfig.packageList.isMacro(item.fullName)) {
            item.nativePlatform = true
            // if user didn't explicitly asked to cross compile macro package
            // via `compile-macros-for-target`, we don't do it
            if (!buildConfig.targetMacroMods.contains(item.rootPkgName) &&
                !buildConfig.targetMacroPkgs.contains(item.fullName)) {
                item.targetPlatform = false
            }
        // regular `package` is used by `macro package`
        } else if (buildConfig.pkgRequireByMacro.contains(item.fullName)) {
            item.nativePlatform = true
        }
    }
    return
}

// wasm32-wasi has no dynamic linking. Only packages compiled for the target are checked, after
// appendNativeData decided the platforms: macro packages stay host libraries (lib-macro_*.so).
func checkWasmTargetOutputTypes(buildConfig: BuildConfig, data: ModuleResolve): Bool {
    if (!buildConfig.isCrossCompile || !isWasmCrossCompile()) {
        return true
    }
    for (item in data.resolves) {
        if (item.targetPlatform && !buildConfig.packageList.isMacro(item.fullName) && item.outputType == Dynamic) {
            eprintln(wasmUnsupportedFeatureMessage(
                "'output-type = \"dynamic\"' of package '${item.fullName}' (no dynamic libraries)"))
            return false
        }
    }
    return true
}
