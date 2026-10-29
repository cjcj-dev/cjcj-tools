package cjlint

import cjcj::ast.*
import std.collection.*

func allIrrefutable(patterns: ArrayList<Pattern>): Bool {
    for (pattern in patterns) { if (!irrefutableMatchPattern(pattern)) { return false } }
    return true
}

func irrefutableEnumPattern(pattern: EnumPattern): Bool {
    if (let Some(ty) <- pattern.GetTy()) {
        if (let Some(enumeration) <- (ty as EnumTy)) {
            if (let Some(declaration) <- enumeration.declPtr) {
                return declaration.constructors.size == 1 && allIrrefutable(pattern.patterns)
            }
        }
    }
    return false
}

func irrefutableMatchPattern(pattern: Pattern): Bool {
    if ((pattern as WildcardPattern).isSome() || (pattern as VarPattern).isSome()) { return true }
    if (let Some(tuple) <- (pattern as TuplePattern)) { return allIrrefutable(tuple.patterns) }
    if (let Some(enumeration) <- (pattern as EnumPattern)) { return irrefutableEnumPattern(enumeration) }
    if (let Some(variable) <- (pattern as VarOrEnumPattern)) {
        if (let Some(ty) <- variable.GetTy()) {
            if (!ty.IsEnum()) { return true }
            if (let Some(enumeration) <- (ty as EnumTy)) {
                if (let Some(declaration) <- enumeration.declPtr) {
                    var constructor = false
                    for (item in declaration.constructors) {
                        if (item.identifier.Val() == variable.identifier.Val()) { constructor = true; break }
                    }
                    if (!constructor) { return true }
                }
            }
            if (let Some(nested) <- variable.pattern) {
                if (let Some(enumeration) <- (nested as EnumPattern)) { return irrefutableEnumPattern(enumeration) }
            }
        }
    }
    return false
}

func checkMatchDimensions(engine: RuleEngine, expression: MatchExpr): Unit {
    let patterns = ArrayList<Pattern>()
    for (arm in expression.matchCases) {
        if (let Some(ty) <- arm.GetTy()) { if (ty.String() == "UnknownType") { continue } }
        patterns.add(all: arm.patterns)
    }
    var firstIrrefutable: Option<Pattern> = None
    var laterRefutable = false
    var hasTypePattern = false
    var hasValuePattern = false
    for (pattern in patterns) {
        if (irrefutableMatchPattern(pattern)) {
            if (firstIrrefutable.isNone()) { firstIrrefutable = pattern }
        } else if (firstIrrefutable.isSome()) { laterRefutable = true }
        if ((pattern as TypePattern).isSome()) { hasTypePattern = true }
        if ((pattern as ConstPattern).isSome() || (pattern as VarPattern).isSome() ||
            (pattern as VarOrEnumPattern).isSome() || (pattern as EnumPattern).isSome() ||
            (pattern as TuplePattern).isSome()) { hasValuePattern = true }
    }
    if (laterRefutable) {
        engine.emit(firstIrrefutable.getOrThrow(), "G_EXP_01_avoid_mixed_patterns_in_match_expr_01", [""])
    }
    if (hasTypePattern && hasValuePattern) {
        engine.emit(expression, "G_EXP_01_avoid_mixed_patterns_in_match_expr_02", [""])
    }
}

func checkMatchPatterns(engine: RuleEngine, root: Node): Unit {
    Walker(root, visitPre: { node: Node =>
        if (let Some(expression) <- (node as MatchExpr)) { checkMatchDimensions(engine, expression) }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
