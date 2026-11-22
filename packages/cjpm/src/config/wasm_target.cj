// Copyright (c) Huawei Technologies Co., Ltd. 2025. All rights reserved.
// This source file is part of the Cangjie project, licensed under Apache-2.0
// with Runtime Library Exception.
//
// See https://cangjie-lang.cn/pages/LICENSE for license information.

package cjpm.config

import std.collection.*

// wasm32-wasi (WASI preview1 command modules), staged subset M0.
//
// cjc accepts four spellings of the one supported Wasm target and reports it as
// `wasm32-unknown-wasi`; cjpm uses that canonical spelling everywhere (target
// directory, `[target.<triple>]` lookup, artifact naming, runner selection and
// the `--target=` value handed to cjc). Every other wasm triple (wasm32-unknown-unknown,
// emscripten, wasip2, wasi-threads, wasm64-*) is rejected explicitly instead of being
// passed through as an opaque cross target.
public const WASM_WASI_TARGET: String = "wasm32-unknown-wasi"

public const WASM_WASI_ALIASES: String = "wasm32-wasi, wasm32-wasip1, wasm32-unknown-wasi, wasm32-unknown-wasip1"

// Some(canonical triple) for a supported WASI preview1 spelling, None for anything else.
public func canonicalWasmTarget(target: String): ?String {
    if (target == "wasm32-wasi" || target == "wasm32-wasip1" || target == "wasm32-unknown-wasi" ||
        target == "wasm32-unknown-wasip1") {
        return Some(WASM_WASI_TARGET)
    }
    return None
}

// True for any triple whose architecture is WebAssembly, supported or not.
public func isWasmFamilyTarget(target: String): Bool {
    let arch = target.split("-")[0]
    arch == "wasm32" || arch == "wasm64"
}

// True only for the supported (canonical or alias) wasm32-wasi target.
public func isWasmTarget(target: String): Bool {
    canonicalWasmTarget(target).isSome()
}

// True when the current cross-compile target is wasm32-wasi.
public func isWasmCrossCompile(): Bool {
    isWasmTarget(crossCompileTarget)
}

public func unsupportedWasmTargetMessage(target: String): String {
    "Error: the wasm target '${target}' is not supported, cjpm supports only WASI preview1 " +
        "(${WASM_WASI_ALIASES}); wasm32-unknown-unknown, emscripten, wasip2, wasi-threads and wasm64 are not supported"
}

// Explicitly unsupported features of the wasm32-wasi target (M0).
public func wasmUnsupportedFeatureMessage(feature: String): String {
    "Error: ${feature} is not supported for the wasm32-wasi target (${WASM_WASI_TARGET})"
}

// Every `[target.<spelling>]` section that names the wasm32-wasi target, canonical or alias.
public func wasmTargetSections(targetConfigMap: HashMap<String, TargetConfig>): ArrayList<String> {
    let keys = ArrayList<String>()
    for ((targetName, _) in targetConfigMap) {
        if (isWasmTarget(targetName)) {
            keys.add(targetName)
        }
    }
    keys
}

// `[target.wasm32-wasi]` and the other aliases name the canonical target; a single such section is
// re-keyed so that every lookup by crossCompileTarget (always canonical) finds it. Two or more spellings
// are left as they are and rejected by checkWasmTargetSections (no silent, map-order-dependent pick).
public func canonicalizeWasmTargetKeys(targetConfigMap: HashMap<String, TargetConfig>): Unit {
    let keys = wasmTargetSections(targetConfigMap)
    if (keys.size != 1 || keys[0] == WASM_WASI_TARGET) {
        return
    }
    if (let Some(config) <- targetConfigMap.remove(keys[0])) {
        targetConfigMap.add(WASM_WASI_TARGET, config)
    }
}

public func checkWasmTargetSections(targetConfigMap: HashMap<String, TargetConfig>, configFilePath: String): Bool {
    let keys = wasmTargetSections(targetConfigMap)
    if (keys.size <= 1) {
        return true
    }
    let names = ArrayList<String>()
    for (key in keys) {
        names.add("[target.${key}]")
    }
    eprintln("Error: ${String.join(names.toArray(), delimiter: ", ")} in ${configFilePath} all configure " +
        "${WASM_WASI_TARGET}; keep exactly one of these sections")
    return false
}
