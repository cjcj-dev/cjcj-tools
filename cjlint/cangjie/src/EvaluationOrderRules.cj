package cjlint

import cjcj::ast.*
import std.collection.*

func globalAssignmentTarget(input: Option<Expr>): Bool {
    if (let Some(expression) <- input) {
        if (let Some(reference) <- (expression as RefExpr)) {
            if (let Some(target) <- reference.ref.target) {
                if (target.astKind == ASTKind.VAR_DECL) {
                    return target.TestAttr(Attribute.STATIC) || target.TestAttr(Attribute.GLOBAL)
                }
            }
        }
        if (let Some(member) <- (expression as MemberAccess)) { return globalAssignmentTarget(member.baseExpr) }
    }
    return false
}

func initialGlobalAssignments(function: FuncDecl): Bool {
    if (let Some(body) <- function.funcBody) {
        if (let Some(block) <- body.body) {
            for (statement in block.body) {
                if (let Some(assignment) <- (statement as AssignExpr)) {
                    if (globalAssignmentTarget(assignment.leftValue)) { return true }
                } else { break }
            }
        }
    }
    return false
}

func orderedSideEffect(input: Option<Expr>, cache: HashMap<Decl, Bool>): Option<FuncDecl> {
    if (let Some(expression) <- input) {
        if (let Some(call) <- (expression as CallExpr)) {
            if (let Some(base) <- call.baseFunc) {
                if ((base as RefExpr).isSome()) { return orderedSideEffect(base, cache) }
            }
        }
        if (let Some(reference) <- (expression as RefExpr)) {
            if (let Some(target) <- reference.ref.target) {
                if (let Some(function) <- (target as FuncDecl)) {
                    if (function.astKind != ASTKind.FUNC_DECL) { return None }
                    if (!cache.contains(function)) { cache[function] = initialGlobalAssignments(function) }
                    if (cache[function]) { return function }
                }
            }
        }
        if (let Some(member) <- (expression as MemberAccess)) { return orderedSideEffect(member.baseExpr, cache) }
    }
    return None
}

func reorderedArguments(call: CallExpr): Bool {
    if (let Some(base) <- call.baseFunc) {
        if (let Some(reference) <- (base as RefExpr)) {
            if (let Some(target) <- reference.ref.target) {
                if (let Some(function) <- (target as FuncDecl)) {
                    if (let Some(body) <- function.funcBody) {
                        if (body.paramLists.isEmpty()) { return false }
                        let parameters = body.paramLists[0].params
                        var index: Int64 = 0
                        for (argument in call.args) {
                            if (index < parameters.size && parameters[index].identifier == argument.name) { index++ }
                        }
                        return index != parameters.size
                    }
                }
            }
        }
    }
    return false
}

func checkEvaluationOrder(engine: RuleEngine, root: Node): Unit {
    let cache = HashMap<Decl, Bool>()
    Walker(root, visitPre: { node: Node =>
        if (let Some(call) <- (node as CallExpr)) {
            let reordered = reorderedArguments(call)
            var hasNothing = false
            for (argument in call.args) {
                if (let Some(ty) <- argument.GetTy()) { if (ty.IsNothing()) { hasNothing = true } }
                if (!hasNothing && !reordered) { continue }
                if (let Some(function) <- orderedSideEffect(argument.expr, cache)) {
                    if (let Some(expression) <- argument.expr) {
                        engine.emit(expression, "G_EXP_04_side_effect_depend_on_order", [function.identifier.Val()])
                    }
                }
            }
        }
        if (let Some(assignment) <- (node as AssignExpr)) {
            if (let Some(function) <- orderedSideEffect(assignment.leftValue, cache)) {
                if (let Some(expression) <- assignment.leftValue) {
                    engine.emit(expression, "G_EXP_04_side_effect_depend_on_order", [function.identifier.Val()])
                }
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
