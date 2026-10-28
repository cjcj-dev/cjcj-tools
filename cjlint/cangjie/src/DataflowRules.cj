package cjlint

import cjcj::chir.*
import cjcj::basic.Position as SourcePosition
import cjcj::basic.DiagnosticEngine as FlowDiagnostics
import std.collection.*

let dataflowRuleIds = ["G.FIO.01", "G.CHK.03", "G.CHK.01", "G.OTH.01", "G.VAR.01", "G.SER.03", "P.02"]

func flowCall(expression: Expression): Option<(Value, ArrayList<Value>)> {
    if (let Some(call) <- (expression as Apply)) { return (call.GetCallee(), call.GetArgs()) }
    if (let Some(call) <- (expression as TryApply)) { return (call.GetCallee(), call.GetArgs()) }
    return None
}

func flowLiteral(value: Value): String {
    if (let Some(local) <- (value as LocalVar)) {
        if (let Some(expression) <- local.GetExpr()) {
            if (let Some(constant) <- (expression as Constant)) {
                if (constant.IsStringLit()) { return constant.GetStringLitVal() }
            }
        }
    }
    return ""
}

func flowEmit(findings: ArrayList<Finding>, location: DebugLocation, kind: String, args: Array<String>): Unit {
    let begin = location.GetBeginPos(); let end = location.GetEndPos()
    findings.add(Finding(location.GetAbsPath(), SourcePosition(UInt64(location.GetFileID()), Int64(begin.line), Int64(begin.column)),
        SourcePosition(UInt64(location.GetFileID()), Int64(end.line), Int64(end.column)), kind, args))
}

func walkFlow(body: BlockGroup, action: (Expression) -> Unit): Unit {
    for (block in body.GetBlocks()) {
        for (expression in block.GetExpressions()) {
            action(expression)
            if (let Some(lambdaExpr) <- (expression as Lambda)) {
                if (let Some(nested) <- lambdaExpr.GetBody()) { walkFlow(nested, action) }
            }
        }
    }
}

func flowGeneric(function: Function): Bool {
    if (function.TestAttr(Attribute.GENERIC_INSTANTIATED)) { return true }
    if (let Some(parent) <- function.GetOuterDeclaredOrExtendedDef()) { return parent.TestAttr(Attribute.GENERIC_INSTANTIATED) }
    return false
}

func runDataflowRules(selected: HashSet<String>, findings: ArrayList<Finding>, pkg: Package, config: String, context: CHIRContext, diagnostics: FlowDiagnostics, source: FlowSourceInfo): Unit {
    if (selected.contains("P.02")) { SpawnMutexCheck(findings).run(pkg) }
    if (selected.contains("G.SER.03")) { checkSerializationFlow(findings, pkg) }
    if (selected.contains("G.VAR.01")) { ImmutableCheck(findings, source).run(pkg) }
    if (selected.contains("G.OTH.01")) { checkSensitiveLogs(findings, pkg, readJson(config + "/config/dataflow_rule_G_OTH_01.json"), context, diagnostics) }
    if (selected.contains("G.CHK.01")) { ExternalFlowCheck(findings).run(pkg) }
    if (selected.contains("G.FIO.01")) { checkTemporaryFiles(findings, pkg) }
    if (selected.contains("G.CHK.03")) { checkPathValidation(findings, pkg, readJson(config + "/config/dataflow_rule_G_CHK_03.json")) }
}

func flowBaseType(ty: Type): Type {
    if (let Some(reference) <- (ty as RefType)) { return flowBaseType(reference.GetBaseType()) }
    return ty
}

func flowFunctionMatches(value: Value, settings: JsonValue, category: String): Bool {
    if (let Some(function) <- (value as Function)) {
        var parent = ""
        if (let Some(owner) <- function.GetParentCustomTypeDef()) { parent = owner.GetSrcCodeIdentifier() }
        let list = settings.field(category)
        if (list.kind != "array") { fail(category + " must be an array") }
        for (item in list.items) {
            if (item.field("name").text() == function.GetSrcCodeIdentifier() && item.field("parent").text() == parent &&
                item.field("lib").text() == function.GetPackageName()) { return true }
        }
    }
    return false
}

func flowDebug(value: Value): Option<Debug> {
    if (let Some(parameter) <- (value as Parameter)) { return parameter.GetDebugExpr() }
    if (let Some(local) <- (value as LocalVar)) {
        if (let Some(debug) <- local.GetDebugExpr()) { return debug }
        if (let Some(expression) <- local.GetExpr()) {
            if (let Some(load) <- (expression as Load)) { return flowDebug(load.GetLocation()) }
        }
    }
    return None
}

func flowStoredLocal(value: Value): Option<LocalVar> {
    if (let Some(local) <- (value as LocalVar)) {
        if (local.GetDebugExpr().isSome()) { return local }
        let users = local.GetUsers()
        if (!users.isEmpty()) {
            if (let Some(store) <- (users[0] as Store)) {
                if (let Some(location) <- (store.GetLocation() as LocalVar)) {
                    if (location.GetDebugExpr().isSome()) { return location }
                }
            }
        }
    }
    return None
}
