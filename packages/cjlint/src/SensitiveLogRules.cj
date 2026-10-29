package cjlint

import cjcj::chir.*
import cjcj::basic.DiagnosticEngine as FlowDiagnostics
import std.collection.*

func flowSubtype(definition: CustomTypeDef, name: String, packageName: String, visited: HashSet<Int64>): Bool {
    if (visited.contains(definition.nodeId)) { return false }; visited.add(definition.nodeId)
    if (definition.GetSrcCodeIdentifier() == name && definition.GetPackageName() == packageName) { return true }
    for (parent in definition.GetImplementedInterfaceDefs()) { if (flowSubtype(parent, name, packageName, visited)) { return true } }
    for (extension in definition.GetExtends()) {
        for (parent in extension.GetImplementedInterfaceDefs()) { if (flowSubtype(parent, name, packageName, visited)) { return true } }
    }
    if (let Some(classDef) <- (definition as ClassDef)) {
        if (let Some(parent) <- classDef.GetSuperClassDef()) { return flowSubtype(parent, name, packageName, visited) }
    }
    return false
}

func flowLogText(value: Value, visited: HashSet<Int64>): String {
    if (visited.contains(value.nodeId)) { return "" }; visited.add(value.nodeId)
    if (let Some(local) <- (value as LocalVar)) {
        if (let Some(expression) <- local.GetExpr()) {
            if (let Some(constant) <- (expression as Constant)) {
                if (constant.IsStringLit()) { return constant.GetStringLitVal() }
            }
            if (let Some(call) <- (expression as Apply)) {
                if (let Some(function) <- (call.GetCallee() as Function)) {
                    let args = call.GetArgs()
                    if (function.IsImportedFunc() && function.GetSrcCodeIdentifier() == "+" && function.GetPackageName() == "std.core" && args.size >= 2) {
                        return flowLogText(args[0], visited) + flowLogText(args[1], visited)
                    }
                }
            }
        }
    }
    return ""
}

func flowLogLevel(value: Value): Bool {
    if (let Some(local) <- (value as LocalVar)) {
        if (let Some(expression) <- local.GetExpr()) {
            if (let Some(load) <- (expression as Load)) {
                let location = load.GetLocation()
                return (location.IsImportedVar() || location.IsGlobalVarWithInitializer()) && location.GetSrcCodeIdentifier() != "OFF"
            }
        }
    }
    return false
}

func checkSensitiveLogCall(findings: ArrayList<Finding>, expression: Expression, state: ConstDomain, keywords: Array<String>): Unit {
    var name = ""; var owner: Option<CustomTypeDef> = None; var resultType: Option<Type> = None
    let args = ArrayList<Value>()
    if (let Some((callee, arguments)) <- flowCall(expression)) {
        if (let Some(function) <- (callee as Function)) {
            name = function.GetSrcCodeIdentifier(); owner = function.GetParentCustomTypeDef(); resultType = function.GetReturnType()
            for (argument in arguments) { args.add(argument) }
        }
    } else if (let Some(call) <- (expression as Invoke)) {
        name = call.GetMethodName(); resultType = call.GetMethodType().GetReturnType()
        let ty = flowBaseType(call.GetObject().GetType().getOrThrow())
        if (let Some(custom) <- (ty as CustomType)) { owner = custom.GetCustomTypeDef() }
        for (argument in call.GetArgs()) { args.add(argument) }
    }
    if (!["trace", "debug", "info", "warn", "error", "log"].contains(name)) { return }
    if (let Some(ty) <- resultType) { if (flowTypeName(ty) != "Unit") { return } } else { return }
    if (let Some(definition) <- owner) {
        if (!flowSubtype(definition, "Logger", "stdx.log", HashSet<Int64>())) { return }
    } else { return }
    let index = if (name == "log") { 2 } else { 1 }
    if (args.size <= index || (name == "log" && !flowLogLevel(args[1]))) { return }
    var content = ""
    if (let Some(value) <- state.CheckAbstractValue(args[index])) {
        if (let Some(text) <- (value as ConstStrVal)) { content = text.GetVal() }
    }
    if (content.isEmpty()) { content = flowLogText(args[index], HashSet<Int64>()) }
    let emitted = HashSet<String>()
    for (keyword in keywords) {
        if (!keyword.isEmpty() && content.contains(keyword) && !emitted.contains(keyword)) {
            emitted.add(keyword); flowEmit(findings, expression.GetDebugLocation(), "G_OTH_01_log_sensitive_information", [keyword])
        }
    }
}

func checkSensitiveLogs(findings: ArrayList<Finding>, pkg: Package, settings: JsonValue,
    context: CHIRContext, diagnostics: FlowDiagnostics): Unit {
    let keywords = settingStrings(settings, "SensitiveKeyword")
    let analysis = ConstAnalysisWrapper(CHIRBuilder(context))
    analysis.RunOnPackage(pkg, diagnostics, 1)
    for (function in pkg.GetGlobalFuncsWithBody(includeSrcCodeImported: false)) {
        if (let Some(result) <- analysis.CheckFuncResult(function)) {
            result.VisitWith({ _: ConstDomain, _: Expression, _: Int64 => },
                { state: ConstDomain, expression: Expression, _: Int64 => checkSensitiveLogCall(findings, expression, state, keywords) },
                { state: ConstDomain, expression: Expression, _: Option<Block> => checkSensitiveLogCall(findings, expression, state, keywords) })
        }
    }
}
