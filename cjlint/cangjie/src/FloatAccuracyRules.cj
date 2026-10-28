package cjlint

import cjcj::ast.*
import std.convert.Parsable

// Preserve the reference rule's decimal digit budget. This is its configured
// representation heuristic, not a claim that every binary float is exact.
func referenceFloatRange(text: String, single: Bool): Bool {
    let digits: Int64 = if (single) { 6 } else { 15 }
    if (text.contains(".")) {
        if (text.size - 1 > digits + 1) { return false }
    } else if (text.size > digits) { return false }
    try {
        let value = if (single) { Float64(Float32.parse(text)) } else { Float64.parse(text) }
        let limit: Float64 = if (single) { 3.4028234663852886e38 } else { 1.7976931348623157e308 }
        return value >= -limit && value <= limit
    } catch (_: Exception) { return false }
}

func referenceAccurateFloat(text: String, kind: TypeKind): Bool {
    if (kind == TypeKind.TYPE_FLOAT64) { return referenceFloatRange(text, false) }
    if (kind == TypeKind.TYPE_FLOAT32) { return referenceFloatRange(text, true) }
    if (kind == TypeKind.TYPE_FLOAT16) {
        if (!referenceFloatRange(text, true)) { return false }
        try {
            let value = Float32.parse(text)
            let magnitude = if (value < 0.0f32) { -value } else { value }
            // The reference's half conversion flushes subnormals to zero.
            if (magnitude != 0.0f32 && magnitude < 0.00006103515625f32) { return false }
            return Float32(Float16(value)) == value
        } catch (_: Exception) { return false }
    }
    return true
}

func checkFloatAccuracy(engine: RuleEngine, root: Node): Unit {
    Walker(root, visitPre: { node: Node =>
        if (let Some(literal) <- (node as LitConstExpr)) {
            if (let Some(ty) <- literal.GetTy()) {
                if (!referenceAccurateFloat(literal.stringValue, ty.kind)) {
                    engine.emit(literal, "G_EXP_02_not_accurate_float_operation_01", [literal.stringValue])
                }
            }
        }
        if (let Some(binary) <- (node as BinaryExpr)) {
            if (binary.op == TokenKind.EQUAL || binary.op == TokenKind.NOTEQ) {
                if (let Some(left) <- binary.leftExpr) {
                    if (let Some(right) <- binary.rightExpr) {
                        if (let Some(leftType) <- left.GetTy()) {
                            if (let Some(rightType) <- right.GetTy()) {
                                if (leftType.IsFloating() && rightType.IsFloating()) {
                                    engine.emit(binary, "G_EXP_02_not_accurate_float_operation_02",
                                        [if (binary.op == TokenKind.EQUAL) { "==" } else { "!=" }])
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
