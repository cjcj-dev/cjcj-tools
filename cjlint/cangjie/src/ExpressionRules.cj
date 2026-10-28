package cjlint

import cjcj::ast.*

func expressionOperatorGroup(op: TokenKind): Int64 {
    match (op) {
        case TokenKind.ADD | TokenKind.SUB | TokenKind.MUL | TokenKind.DIV | TokenKind.MOD | TokenKind.EXP |
            TokenKind.LT | TokenKind.LE | TokenKind.GT | TokenKind.GE | TokenKind.EQUAL | TokenKind.NOTEQ => return 1
        case TokenKind.LSHIFT | TokenKind.RSHIFT | TokenKind.BITAND | TokenKind.BITOR | TokenKind.BITXOR => return 2
        case _ => return 0
    }
}

func parenthesesDiagnostic(engine: RuleEngine, node: Node, index: Int64, argument!: String = ""): Unit {
    engine.emit(node, "G_EXP_05_use_parentheses_to_express_operations_order_0" + index.toString(), [argument])
}

func checkBinaryParentheses(engine: RuleEngine, operand: Expr, op: TokenKind): Unit {
    if (let Some(paren) <- (operand as ParenExpr)) {
        if (let Some(inner) <- paren.expr) {
            if (let Some(binary) <- (inner as BinaryExpr)) {
                if (binary.op == op) { parenthesesDiagnostic(engine, paren, 2) }
            }
        }
        return
    }
    if (let Some(binary) <- (operand as BinaryExpr)) {
        let outerGroup = expressionOperatorGroup(op)
        let innerGroup = expressionOperatorGroup(binary.op)
        if (outerGroup > 0 && innerGroup > 0 && outerGroup != innerGroup) {
            parenthesesDiagnostic(engine, binary, 4)
        }
    }
}

func checkExpressionParentheses(engine: RuleEngine, file: File): Unit {
    Walker(file, visitPre: { node: Node =>
        if (let Some(paren) <- (node as ParenExpr)) {
            if (let Some(inner) <- paren.expr) {
                if (let Some(unary) <- (inner as UnaryExpr)) {
                    let symbol = match (unary.op) { case TokenKind.NOT => "!"; case TokenKind.SUB => "-"; case _ => "" }
                    parenthesesDiagnostic(engine, paren, 1, argument: symbol)
                }
                if ((inner as ParenExpr).isSome()) { parenthesesDiagnostic(engine, paren, 3) }
            }
        } else if (let Some(binary) <- (node as BinaryExpr)) {
            if (let Some(operand) <- binary.leftExpr) { checkBinaryParentheses(engine, operand, binary.op) }
            if (let Some(operand) <- binary.rightExpr) { checkBinaryParentheses(engine, operand, binary.op) }
        } else if (let Some(tuple) <- (node as TupleLit)) {
            for (child in tuple.children) { if ((child as ParenExpr).isSome()) { parenthesesDiagnostic(engine, child, 3) } }
        } else if (let Some(array) <- (node as ArrayLit)) {
            for (child in array.children) { if ((child as ParenExpr).isSome()) { parenthesesDiagnostic(engine, child, 3) } }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
