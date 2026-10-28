package cjlint

import cjcj::ast.*

func comparisonVariable(expression: Option<Expr>): Option<VarDecl> {
    if (let Some(value) <- expression) {
        if ((value as RefExpr).isSome() || (value as MemberAccess).isSome()) {
            if (let Some(target) <- value.GetTarget()) { return target as VarDecl }
        }
    }
    return None
}

func checkConstantComparisonOperand(engine: RuleEngine, left: Expr, right: VarDecl): Unit {
    if (let Some(variable) <- comparisonVariable(left)) {
        if ((variable.isConst && !right.isConst) || (!variable.isVar && right.isVar)) {
            engine.emit(left, "G_EXP_07_constants_on_the_right", [variable.identifier.Val()])
        }
    } else if (let Some(literal) <- (left as LitConstExpr)) {
        if (!right.isConst) { engine.emit(literal, "G_EXP_07_constants_on_the_right", [literal.rawString]) }
    }
}

func comparisonInterval(expression: BinaryExpr): Bool {
    if (expression.op != TokenKind.AND) { return false }
    if (let Some(leftValue) <- expression.leftExpr) {
        if (let Some(rightValue) <- expression.rightExpr) {
            if (let Some(left) <- (leftValue as BinaryExpr)) {
                if (let Some(right) <- (rightValue as BinaryExpr)) {
                    if (let Some(a) <- comparisonVariable(left.rightExpr)) {
                        if (let Some(b) <- comparisonVariable(right.leftExpr)) {
                            return a == b && (((left.op == TokenKind.LT || left.op == TokenKind.LE) &&
                                (right.op == TokenKind.LT || right.op == TokenKind.LE)) ||
                                ((left.op == TokenKind.GT || left.op == TokenKind.GE) &&
                                (right.op == TokenKind.GT || right.op == TokenKind.GE)))
                        }
                    }
                }
            }
        }
    }
    return false
}

func checkConstantComparisons(engine: RuleEngine, root: Node): Unit {
    Walker(root, visitPre: { node: Node =>
        if (let Some(binary) <- (node as BinaryExpr)) {
            if (let Some(left) <- binary.leftExpr) { if ((left as TupleLit).isSome()) { return VisitAction.SKIP_CHILDREN } }
            if (let Some(right) <- binary.rightExpr) { if ((right as TupleLit).isSome()) { return VisitAction.SKIP_CHILDREN } }
            if (binary.desugarExpr.isNone() && comparisonInterval(binary)) { return VisitAction.SKIP_CHILDREN }
            if (![TokenKind.EQUAL, TokenKind.NOTEQ, TokenKind.GE, TokenKind.GT, TokenKind.LE, TokenKind.LT].contains(binary.op)) {
                return VisitAction.WALK_CHILDREN
            }
            if (let Some(desugared) <- binary.desugarExpr) {
                if (let Some(call) <- (desugared as CallExpr)) {
                    if (call.args.size == 1) {
                        // Desugared operators use a member receiver and one
                        // explicit operand; the reference only accepts RefExpr.
                        if (let Some(argument) <- call.args[0].expr) {
                            if ((argument as RefExpr).isSome()) {
                                if (let Some(right) <- comparisonVariable(argument)) {
                                    if (let Some(base) <- call.baseFunc) {
                                        if (let Some(member) <- (base as MemberAccess)) {
                                            if (let Some(left) <- member.baseExpr) { checkConstantComparisonOperand(engine, left, right) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else if (let Some(left) <- binary.leftExpr) {
                if (let Some(right) <- binary.rightExpr) {
                    if (left.GetTy().isSome() && right.GetTy().isSome()) {
                        if (let Some(variable) <- comparisonVariable(right)) { checkConstantComparisonOperand(engine, left, variable) }
                    }
                }
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
