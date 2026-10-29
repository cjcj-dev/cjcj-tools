package cjlint

import cjcj::ast.*
import std.collection.*

class ShortCircuitCheck {
    let engine: RuleEngine
    let effects = HashSet<Decl>()
    init(engine: RuleEngine) { this.engine = engine }
    func functionEffect(function: FuncDecl, member: Bool, active: HashSet<Decl>): Bool {
        if (effects.contains(function)) { return true }
        if (active.contains(function)) { return false }
        active.add(function)
        let state = HashSet<String>()
        if (let Some(body) <- function.funcBody) {
            if (let Some(block) <- body.body) {
                Walker(block, visitPre: { node: Node =>
                    if ((node as AssignExpr).isSome() || (node as IncOrDecExpr).isSome()) { state.add("operation") }
                    if (let Some(reference) <- (node as RefExpr)) {
                        if (reference.isBaseFunc) { state.add("operation") }
                        if (let Some(target) <- reference.ref.target) {
                            if (!reference.isBaseFunc && (target.TestAttr(Attribute.GLOBAL) ||
                                (member && (target.TestAttr(Attribute.IN_CLASSLIKE) || target.TestAttr(Attribute.IN_STRUCT))))) {
                                state.add("external")
                            } else {
                                if (let Some(called) <- (target as FuncDecl)) {
                                    if (functionEffect(called, member, active)) { state.add("call") }
                                }
                                for (candidate in reference.ref.targets) {
                                    if (let Some(declaration) <- candidate) {
                                        if (let Some(called) <- (declaration as FuncDecl)) {
                                            if (functionEffect(called, member, active)) { state.add("call") }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    return VisitAction.WALK_CHILDREN
                }).Walk()
            }
        }
        active.remove(function)
        let effect = state.contains("call") || (state.contains("external") && state.contains("operation"))
        if (effect) { effects.add(function) }
        return effect
    }
    func emit(node: Node, name: String): Unit { engine.emit(node, "G_EXP_03_side_effect_information", [name]) }
    func operandName(assignment: AssignExpr): String {
        if (let Some(left) <- assignment.leftValue) { return engine.sources.GetContentBetween(left.begin, left.end).trimAscii() }
        if (let Some(desugared) <- assignment.desugarExpr) {
            if (let Some(other) <- (desugared as AssignExpr)) {
                if (let Some(left) <- other.leftValue) { return engine.sources.GetContentBetween(left.begin, left.end).trimAscii() }
            }
        }
        return ""
    }
    func operand(root: Expr): Unit {
        Walker(root, visitPre: { node: Node =>
            if (let Some(assignment) <- (node as AssignExpr)) {
                if (let Some(desugared) <- assignment.desugarExpr) {
                    if (let Some(call) <- (desugared as CallExpr)) {
                        if (let Some(function) <- call.resolvedFunction) {
                            if (effects.contains(function)) { emit(assignment, operandName(assignment)) }
                        }
                        return VisitAction.SKIP_CHILDREN
                    }
                }
                emit(assignment, operandName(assignment)); return VisitAction.SKIP_CHILDREN
            }
            if (let Some(increment) <- (node as IncOrDecExpr)) {
                if (increment.desugarExpr.isSome()) { return VisitAction.WALK_CHILDREN }
                if (let Some(expression) <- increment.expr) { emit(increment, expression.ToString()) }
                return VisitAction.SKIP_CHILDREN
            }
            if (let Some(reference) <- (node as RefExpr)) {
                if (reference.isBaseFunc) {
                    if (let Some(target) <- reference.ref.target) {
                        if (effects.contains(target)) { emit(reference, reference.ref.identifier.Val()) }
                    }
                }
            }
            if (let Some(member) <- (node as MemberAccess)) {
                var name = ""
                if (let Some(base) <- member.baseExpr) {
                    if (let Some(ty) <- base.GetTy()) { name = ty.name + "." + member.field.Val() }
                }
                let targets = ArrayList<Decl>()
                if (let Some(target) <- member.target) { targets.add(target) }
                else { for (candidate in member.targets) { if (let Some(target) <- candidate) { targets.add(target) } } }
                for (target in targets) {
                    if (effects.contains(target)) {
                        if (member.begin.IsZero()) {
                            if (let Some(original) <- member.callOrPattern) { emit(original, name) }
                        } else { emit(member, name) }
                    }
                }
            }
            if (let Some(binary) <- (node as BinaryExpr)) {
                if (let Some(desugared) <- binary.desugarExpr) { operand(desugared); return VisitAction.SKIP_CHILDREN }
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
    }
    func run(root: Node): Unit {
        Walker(root, visitPre: { node: Node =>
            if (let Some(function) <- (node as FuncDecl)) {
                functionEffect(function, function.TestAttr(Attribute.IN_CLASSLIKE) || function.TestAttr(Attribute.IN_STRUCT), HashSet<Decl>())
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
        Walker(root, visitPre: { node: Node =>
            if (let Some(binary) <- (node as BinaryExpr)) {
                if (binary.op == TokenKind.AND || binary.op == TokenKind.OR || binary.op == TokenKind.COALESCING) {
                    if (let Some(right) <- binary.rightExpr) { operand(right) }
                }
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
    }
}
