package cjlint

import cjcj::ast.*
import std.collection.*

class ExternalLogRecord {
    let node: MemberAccess
    let name: String
    var purified = false
    init(node: MemberAccess, name: String) { this.node = node; this.name = name }
}

class LogInputCheck {
    let engine: RuleEngine
    let logs = ArrayList<ExternalLogRecord>()
    let tainted = ArrayList<RefExpr>()
    let active = HashSet<Node>()
    init(engine: RuleEngine) { this.engine = engine }
    func source(function: FuncDecl, key: String): Bool {
        let settings = ruleSettings(engine, "G_CHK_02").field(key)
        if (settings.kind != "array") { fail(key + " must be an array") }
        for (item in settings.items) {
            if (function.identifier == item.field("name").text() && function.fullPackageName == item.field("lib").text() &&
                ruleFunctionParent(function) == item.field("parent").text()) { return true }
        }
        return false
    }
    func logger(member: MemberAccess): Bool {
        if (!["trace", "debug", "info", "warn", "error", "log"].contains(member.field.Val())) { return false }
        if (let Some(target) <- member.target) {
            if (let Some(function) <- (target as FuncDecl)) {
                if (let Some(body) <- function.funcBody) {
                    if (let Some(parent) <- body.parentClassLike) {
                        if (parent.identifier.GetRawText() == "Logger") { return true }
                        for (inherited in parent.inheritedTypes) {
                            if (let Some(ty) <- inherited.GetTy()) { if (ty.name == "Logger") { return true } }
                        }
                    }
                }
            }
        }
        return false
    }
    func collectTaint(root: Node): Unit {
        Walker(root, visitPre: { node: Node =>
            if (let Some(call) <- (node as CallExpr)) {
                if (call.args.isEmpty()) { return VisitAction.SKIP_CHILDREN }
                if (let Some(expanded) <- call.desugarExpr) { collectTaint(expanded); return VisitAction.SKIP_CHILDREN }
                if (let Some(base) <- call.baseFunc) {
                    if (let Some(member) <- (base as MemberAccess)) {
                        if (let Some(target) <- member.target) {
                            if (let Some(function) <- (target as FuncDecl)) {
                                if (source(function, "ExternalDateFuncPassToVar")) {
                                    for (argument in call.args) {
                                        if (let Some(expression) <- argument.expr) {
                                            if (let Some(reference) <- (expression as RefExpr)) { tainted.add(reference) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                return VisitAction.SKIP_CHILDREN
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
    }
    func record(node: MemberAccess, name: String): Unit {
        for (log in logs) { if (log.node.begin == node.begin && log.name == name) { return } }
        logs.add(ExternalLogRecord(node, name))
    }
    func payload(input: Option<Expr>, log: MemberAccess, name!: String = ""): Unit {
        if (let Some(root) <- input) {
            if (active.contains(root)) { return }; active.add(root)
            try {
                Walker(root, visitPre: { node: Node =>
                    if (let Some(reference) <- (node as RefExpr)) {
                        let refName = if (name.isEmpty()) { reference.ref.identifier.Val() } else { name }
                        for (variable in tainted) {
                            if (reference.ref.identifier == variable.ref.identifier && variable.begin < log.begin) { record(log, refName) }
                        }
                        if (let Some(target) <- reference.ref.target) {
                            if (let Some(function) <- (target as FuncDecl)) {
                                if (source(function, "ExternalDateFunc")) {
                                    record(log, if (name.isEmpty()) { reference.ref.identifier.Val() + "()" } else { name })
                                }
                            } else if (let Some(variable) <- (target as VarDecl)) { payload(variable.initializer, log, name: refName) }
                        }
                        return VisitAction.SKIP_CHILDREN
                    }
                    if (let Some(member) <- (node as MemberAccess)) {
                        if (member.field == "+") { return VisitAction.WALK_CHILDREN }
                        let refName = if (name.isEmpty()) { engine.sources.GetContentBetween(member.begin, member.end) } else { name }
                        payload(member.baseExpr, log, name: refName)
                        if (let Some(target) <- member.target) {
                            if (let Some(function) <- (target as FuncDecl)) {
                                var hasBody = false
                                if (let Some(body) <- function.funcBody) {
                                    if (let Some(block) <- body.body) {
                                        hasBody = true
                                        for (statement in block.body) {
                                            if (let Some(result) <- (statement as ReturnExpr)) { payload(result.expr, log, name: refName) }
                                        }
                                    }
                                }
                                if (!hasBody && source(function, "ExternalDateFunc")) { record(log, refName) }
                            } else if (let Some(variable) <- (target as VarDecl)) { payload(variable.initializer, log, name: refName) }
                        }
                        return VisitAction.SKIP_CHILDREN
                    }
                    return VisitAction.WALK_CHILDREN
                }).Walk()
            } finally { active.remove(root) }
        }
    }
    func external(input: Option<Expr>): Bool {
        let found = HashSet<String>()
        if (let Some(root) <- input) {
            if (active.contains(root)) { return false }; active.add(root)
            try {
                Walker(root, visitPre: { node: Node =>
                    if (let Some(reference) <- (node as RefExpr)) {
                        if (let Some(target) <- reference.ref.target) {
                            if (let Some(function) <- (target as FuncDecl)) {
                                if (source(function, "ExternalDateFunc")) { found.add("external") }
                                return VisitAction.SKIP_CHILDREN
                            }
                            if (let Some(variable) <- (target as VarDecl)) {
                                if (external(variable.initializer)) { found.add("external") }
                                return VisitAction.SKIP_CHILDREN
                            }
                        } else { return VisitAction.SKIP_CHILDREN }
                    }
                    return VisitAction.WALK_CHILDREN
                }).Walk()
            } finally { active.remove(root) }
        }
        return !found.isEmpty()
    }
    func argumentName(input: Option<Expr>): String {
        if (let Some(expression) <- input) {
            if (let Some(reference) <- (expression as RefExpr)) { return reference.ref.identifier.Val() }
            if (let Some(member) <- (expression as MemberAccess)) { return member.ToString() }
            if (let Some(call) <- (expression as CallExpr)) { return argumentName(call.baseFunc) }
        }
        return ""
    }
    func regex(call: CallExpr): Bool {
        if (let Some(base) <- call.baseFunc) {
            if (let Some(member) <- (base as MemberAccess)) {
                if (let Some(receiver) <- member.baseExpr) {
                    if (let Some(constructor) <- (receiver as CallExpr)) {
                        if (let Some(target) <- constructor.baseFunc) {
                            if (let Some(reference) <- (target as RefExpr)) { return reference.ref.identifier == "Regex" }
                        }
                    }
                }
            }
        }
        return false
    }
    func run(root: Node): Unit {
        collectTaint(root)
        Walker(root, visitPre: { node: Node =>
            if (let Some(call) <- (node as CallExpr)) {
                if (let Some(base) <- call.baseFunc) {
                    if (let Some(member) <- (base as MemberAccess)) {
                        if (logger(member)) { for (argument in call.args) { payload(argument.expr, member) } }
                        return VisitAction.SKIP_CHILDREN
                    }
                }
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
        Walker(root, visitPre: { node: Node =>
            if (let Some(assignment) <- (node as AssignExpr)) {
                let name = argumentName(assignment.leftValue)
                for (log in logs) {
                    if (name != log.name) { continue }
                    if (assignment.scopeName == log.node.scopeName && assignment.assignPos.fileID == log.node.begin.fileID &&
                        assignment.assignPos.line < log.node.begin.line) { log.purified = !external(assignment.rightExpr) }
                }
                return VisitAction.SKIP_CHILDREN
            }
            if (let Some(matchExpr) <- (node as MatchExpr)) {
                if (let Some(selector) <- matchExpr.selector) {
                    if (let Some(call) <- (selector as CallExpr)) {
                        if (regex(call)) {
                            for (argument in call.args) {
                                let name = argumentName(argument.expr)
                                for (log in logs) {
                                    if (name == log.name && log.node.begin.fileID == matchExpr.leftCurlPos.fileID &&
                                        log.node.begin.line > matchExpr.leftCurlPos.line && log.node.begin.line < matchExpr.rightCurlPos.line) {
                                        log.purified = true
                                    }
                                }
                            }
                        }
                        return VisitAction.WALK_CHILDREN
                    }
                }
                return VisitAction.SKIP_CHILDREN
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
        for (log in logs) { if (!log.purified) { engine.emit(log.node, "G_CHK_02_external_data_record_logs", [log.name]) } }
    }
}
