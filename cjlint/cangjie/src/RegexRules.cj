package cjlint

import cjcj::ast.*
import std.collection.*
import std.regex.Regex

func ruleFunctionParent(function: FuncDecl): String {
    if (let Some(body) <- function.funcBody) {
        if (let Some(parent) <- body.parentClassLike) { if (let Some(ty) <- parent.GetTy()) { return ty.name } }
        if (let Some(parent) <- body.parentStruct) { if (let Some(ty) <- parent.GetTy()) { return ty.name } }
        if (let Some(parent) <- body.parentEnum) { if (let Some(ty) <- parent.GetTy()) { return ty.name } }
    }
    return ""
}

// Fixed TaintData.h source identities shared by the original structural rule.
let regexTaintSources: Array<(String, String, String)> = [
    ("build", "HttpResponseBuilder", "stdx.net.http"), ("build", "HttpRequestBuilder", "stdx.net.http"),
    ("send", "Client", "stdx.net.http"), ("get", "Client", "stdx.net.http"), ("head", "Client", "stdx.net.http"),
    ("post", "Client", "stdx.net.http"), ("postForm", "Client", "stdx.net.http"), ("postJson", "Client", "stdx.net.http"),
    ("put", "Client", "stdx.net.http"), ("putForm", "Client", "stdx.net.http"), ("putForm", "Client", "stdx.net.http"),
    ("delete", "Client", "stdx.net.http"), ("deleteForm", "Client", "stdx.net.http"), ("deleteJson", "Client", "stdx.net.http"),
    ("read", "TcpSocket", "std.net"), ("read", "ConsoleReader", "std.console"), ("readln", "ConsoleReader", "std.console"),
    ("readToEnd", "ConsoleReader", "std.console"), ("read", "InputStream", "std.io"),
    ("readToEnd", "", "std.io"), ("gethostname", "", "std.posix")]

class RegexPayloadCheck {
    let engine: RuleEngine
    let origin: Expr
    let active = HashSet<Node>()
    init(engine: RuleEngine, origin: Expr) { this.engine = engine; this.origin = origin }
    func tainted(function: FuncDecl, name: String, checkParent: Bool): Unit {
        let parent = ruleFunctionParent(function)
        for ((funcName, parentName, packageName) in regexTaintSources) {
            if (function.identifier == funcName && function.fullPackageName == packageName && (!checkParent || parent == parentName)) {
                engine.emit(origin, "G_CHK_04_untrusted_regular_expressions_external_data",
                    [if (name.isEmpty()) { function.identifier.Val() } else { name }])
            }
        }
    }
    func text(input: Option<Expr>, name!: String = ""): String {
        if (let Some(expression) <- input) {
            if (active.contains(expression)) { return "" }
            active.add(expression)
            try {
                if (let Some(literal) <- (expression as LitConstExpr)) { return literal.stringValue }
                if (let Some(binary) <- (expression as BinaryExpr)) {
                    let content = text(binary.desugarExpr, name: name)
                    if (binary.leftExpr.isSome() && binary.rightExpr.isSome()) {
                        text(binary.leftExpr, name: name); text(binary.rightExpr, name: name)
                    }
                    return content
                }
                if (let Some(initial) <- (expression as CallExpr)) {
                    var call = initial
                    if (let Some(desugared) <- call.desugarExpr) {
                        if (let Some(expanded) <- (desugared as CallExpr)) { call = expanded }
                    }
                    var content = text(call.baseFunc, name: name)
                    for (argument in call.args) { content += text(argument.expr, name: name) }
                    return content
                }
                if (let Some(subscript) <- (expression as SubscriptExpr)) { return text(subscript.desugarExpr, name: name) }
                if (let Some(member) <- (expression as MemberAccess)) {
                    var content = text(member.baseExpr, name: name)
                    if (let Some(target) <- member.GetTarget()) {
                        if (let Some(variable) <- (target as VarDecl)) {
                            content += text(variable.initializer, name: variable.identifier.Val())
                        } else if (let Some(function) <- (target as FuncDecl)) { tainted(function, name, false) }
                    }
                    return content
                }
                if (let Some(reference) <- (expression as RefExpr)) {
                    if (let Some(target) <- reference.ref.target) {
                        let refName = if (name.isEmpty()) { reference.ref.identifier.Val() } else { name }
                        if (target.astKind == ASTKind.FUNC_PARAM) {
                            engine.emit(origin, "G_CHK_04_untrusted_regular_expressions_dynamical_regex", [refName])
                        } else if (let Some(variable) <- (target as VarDecl)) { return text(variable.initializer, name: refName) }
                        else if (let Some(function) <- (target as FuncDecl)) { tainted(function, refName, true) }
                    }
                }
            } finally { active.remove(expression) }
        }
        return ""
    }
}

func checkRegexInputs(engine: RuleEngine, root: Node): Unit {
    let settings = ruleSettings(engine, "G_CHK_04").field("CheckType")
    if (settings.kind != "array") { fail("CheckType must be an array") }
    Walker(root, visitPre: { node: Node =>
        if (let Some(call) <- (node as CallExpr)) {
            if (let Some(base) <- call.baseFunc) {
                if (let Some(reference) <- (base as RefExpr)) {
                    if (let Some(target) <- reference.ref.target) {
                        if (reference.ref.identifier == "Regex" && target.fullPackageName == "std.regex") {
                            for (argument in call.args) {
                                if (let Some(expression) <- argument.expr) {
                                    let content = RegexPayloadCheck(engine, expression).text(expression)
                                    for (check in settings.items) {
                                        let name = check.field("name").text()
                                        let kind = match (name) {
                                            case "redundantGroup" => "G_CHK_04_untrusted_regular_expressions_redundantGroup"
                                            case "itselfRepeated" => "G_CHK_04_untrusted_regular_expressions_itselfRepeated"
                                            case _ => "G_CHK_04_untrusted_regular_expressions_subexpressionsOverlap"
                                        }
                                        for (found in Regex(check.field("regex").text()).findAll(content)) {
                                            engine.emit(expression, kind, [found.matchString(0)])
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
