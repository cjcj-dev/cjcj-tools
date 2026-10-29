package cjlint

import cjcj::ast.*
import std.collection.*
import std.sort.*

func responsibilityMax(left: Int64, right: Int64): Int64 { return if (left > right) { left } else { right } }

// Follow the reference rule's direct control-body edges. In particular, a nested
// function or a control expression hidden in another expression is not an edge.
func responsibilityControl(node: Node): Bool {
    return (node as IfExpr).isSome() || (node as WhileExpr).isSome() ||
        (node as DoWhileExpr).isSome() || (node as ForInExpr).isSome() || (node as MatchExpr).isSome()
}

func responsibilityBlockDepth(block: Block): Int64 {
    var depth: Int64 = 0
    for (node in block.body) {
        if (responsibilityControl(node)) { depth = responsibilityMax(depth, responsibilityDepth(node)) }
    }
    return depth
}

func responsibilityDepth(node: Node): Int64 {
    if (let Some(expr) <- (node as IfExpr)) {
        var depth = if (let Some(block) <- expr.thenBody) { responsibilityBlockDepth(block) } else { 0 }
        if (let Some(other) <- expr.elseBody) {
            if (let Some(block) <- (other as Block)) { depth += responsibilityBlockDepth(block) }
        }
        return 1 + depth
    }
    if (let Some(expr) <- (node as WhileExpr)) {
        return 1 + if (let Some(block) <- expr.body) { responsibilityBlockDepth(block) } else { 0 }
    }
    if (let Some(expr) <- (node as DoWhileExpr)) {
        return 1 + if (let Some(block) <- expr.body) { responsibilityBlockDepth(block) } else { 0 }
    }
    if (let Some(expr) <- (node as ForInExpr)) {
        return 1 + if (let Some(block) <- expr.body) { responsibilityBlockDepth(block) } else { 0 }
    }
    if (let Some(expr) <- (node as MatchExpr)) {
        var depth: Int64 = 0
        for (item in expr.matchCases) {
            if (let Some(block) <- item.exprOrDecls) { depth = responsibilityMax(depth, responsibilityBlockDepth(block)) }
        }
        for (item in expr.matchCaseOthers) {
            if (let Some(block) <- item.exprOrDecls) { depth = responsibilityMax(depth, responsibilityBlockDepth(block)) }
        }
        return depth + 1
    }
    return 0
}

// This is the source-line policy of StructuralRuleGFUN01, including its quote
// parity and same-line comment accounting. Source semantics always come from AST.
func responsibilityLines(source: String): Int64 {
    var count: Int64 = 0
    var inBlock = false
    for (raw in source.split("\n")) {
        let line = if (raw.endsWith("\r")) { raw[..raw.size - 1] } else { raw }
        if (line.trimAscii().isEmpty()) { continue }
        if (inBlock) {
            if (let Some(end) <- line.lastIndexOf("*/")) {
                inBlock = false
                if (!line[end + 2..].trimAscii().isEmpty()) { count++ }
            }
            continue
        }
        if (let Some(start) <- line.indexOf("/*")) {
            var single: Int64 = 0
            var double: Int64 = 0
            for (c in line[..start].toArray()) {
                if (c == 39) { single++ }
                if (c == 34) { double++ }
            }
            if (single % 2 != 0 || double % 2 != 0) { count++; continue }
            inBlock = true
            if (!line[..start].trimAscii().isEmpty()) { count++ }
            if (let Some(end) <- line.lastIndexOf("*/")) {
                if (end > start) {
                    inBlock = false
                    if (!line[end + 2..].trimAscii().isEmpty()) { count++ }
                }
            }
        } else if (let Some(start) <- line.indexOf("//")) {
            if (!line[..start].trimAscii().isEmpty()) { count++ }
        } else { count++ }
    }
    return count
}

func responsibilityDiagnostic(engine: RuleEngine, node: Node, offset: Int64, name: String): Unit {
    engine.emit(node, "G_FUN_01_function_single_responsibility_information_" + offset.toString(), [name])
}

func checkResponsibilityBody(engine: RuleEngine, node: Node, body: FuncBody, lambda: Bool, name: String): Unit {
    let offset: Int64 = if (lambda) { 3 } else { 0 }
    let constructor = if (let Some(fn) <- (node as FuncDecl)) { fn.TestAttr(Attribute.CONSTRUCTOR) } else { false }
    if (!constructor && !body.paramLists.isEmpty() && body.paramLists[0].params.size > 5) {
        responsibilityDiagnostic(engine, node, offset, name)
    }
    if (lambda) {
        if (let Some(block) <- body.body) {
            for (item in block.body) {
                if (responsibilityControl(item) && responsibilityDepth(item) > 4) {
                    responsibilityDiagnostic(engine, item, offset + 2, "")
                }
            }
        }
    } else {
        Walker(node, visitPre: { item: Node =>
            if (responsibilityControl(item)) {
                if (responsibilityDepth(item) > 4) { responsibilityDiagnostic(engine, item, offset + 2, "") }
                return VisitAction.SKIP_CHILDREN
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
    }
    if (node.end.line - node.begin.line + 1 > 50 &&
        responsibilityLines(engine.sources.GetContentBetween(node.begin, node.end)) > 50) {
        responsibilityDiagnostic(engine, node, offset + 1, name)
    }
}

func checkSingleResponsibility(engine: RuleEngine, file: File): Unit {
    Walker(file, visitPre: { node: Node =>
        if (let Some(fn) <- (node as FuncDecl)) {
            if (let Some(body) <- fn.funcBody) { checkResponsibilityBody(engine, fn, body, false, fn.identifier.Val()) }
        }
        if (let Some(expr) <- (node as LambdaExpr)) {
            if (let Some(body) <- expr.funcBody) { checkResponsibilityBody(engine, expr, body, true, "") }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

func eraseReferencedParameters(root: Node, parameters: HashMap<String, FuncParam>): Unit {
    Walker(root, visitPre: { node: Node =>
        if (let Some(reference) <- (node as RefExpr)) { parameters.remove(reference.ref.identifier.GetRawText()) }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

func checkFunctionParameters(engine: RuleEngine, function: FuncDecl): Unit {
    if (let Some(body) <- function.funcBody) {
        let parameters = HashMap<String, FuncParam>()
        for (list in body.paramLists) {
            for (parameter in list.params) { parameters[parameter.identifier.Val()] = parameter }
        }
        for (list in body.paramLists) {
            for (parameter in list.params) {
                if (let Some(value) <- parameter.assignment) { eraseReferencedParameters(value, parameters) }
            }
        }
        if (let Some(block) <- body.body) {
            eraseReferencedParameters(block, parameters)
            let names = ArrayList<String>()
            for ((name, _) in parameters) { names.add(name) }
            let sorted = names.toArray()
            sort(sorted)
            for (name in sorted) {
                if (name != "_") {
                    let parameter = parameters[name]
                    engine.findings.add(Finding(engine.path, parameter.identifier.Begin(), parameter.identifier.End(),
                        "G_FUN_02_unused_param_information", [name]))
                }
            }
            // The reference recursively checks direct nested declarations only.
            for (item in block.body) {
                if (let Some(nested) <- (item as FuncDecl)) { checkFunctionParameters(engine, nested) }
            }
        }
    }
}

func checkUnusedParameters(engine: RuleEngine, file: File): Unit {
    Walker(file, visitPre: { node: Node =>
        if (let Some(function) <- (node as FuncDecl)) {
            checkFunctionParameters(engine, function)
            return VisitAction.SKIP_CHILDREN
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
