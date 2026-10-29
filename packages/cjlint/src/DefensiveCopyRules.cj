package cjlint

import cjcj::ast.*

func checkOverridableSecurityValue(engine: RuleEngine, node: Node): Unit {
    if (let Some(member) <- (node as MemberAccess)) {
        if (let Some(target) <- member.GetTarget()) {
            if (let Some(function) <- (target as FuncDecl)) {
                if (!function.TestAttr(Attribute.OPEN)) { return }
                if (let Some(owner) <- function.outerDecl) {
                    if (!owner.TestAttr(Attribute.OPEN)) { return }
                    if (let Some(base) <- member.baseExpr) {
                        if (let Some(reference) <- (base as RefExpr)) {
                            if (let Some(parameter) <- reference.ref.target) {
                                if (parameter.astKind == ASTKind.FUNC_PARAM) {
                                    engine.findings.add(Finding(engine.path, member.field.Begin(), member.field.End(),
                                        "P_03_func_could_be_overridden", [owner.identifier.GetRawText(), function.identifier.GetRawText()]))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

func configuredSecurityCall(call: CallExpr, settings: JsonValue): Bool {
    if (let Some(base) <- call.baseFunc) {
        if (!(base as RefExpr).isSome() && !(base as MemberAccess).isSome()) { return false }
        if (let Some(target) <- base.GetTarget()) {
            if (target.astKind != ASTKind.FUNC_DECL) { return false }
            for (item in settings.field("SecurityCheckFunctionInfo").items) {
                if (target.identifier.GetRawText() == item.field("funcName").text() &&
                    target.fullPackageName == item.field("fullPackageName").text()) { return true }
            }
        }
    }
    return false
}

func checkDefensiveCopies(engine: RuleEngine, root: Node): Unit {
    let settings = ruleSettings(engine, "P_03")
    Walker(root, visitPre: { node: Node =>
        if (let Some(call) <- (node as CallExpr)) {
            if (configuredSecurityCall(call, settings)) {
                for (argument in call.args) {
                    if (let Some(expression) <- argument.expr) {
                        Walker(expression, visitPre: { nested: Node =>
                            if (let Some(reference) <- (nested as RefExpr)) {
                                if (let Some(target) <- reference.ref.target) {
                                    if (target.astKind == ASTKind.VAR_DECL) {
                                        let variable = (target as VarDecl).getOrThrow()
                                        if (let Some(value) <- variable.initializer) {
                                            if (let Some(initializer) <- (value as CallExpr)) {
                                                if (let Some(base) <- initializer.baseFunc) { checkOverridableSecurityValue(engine, base) }
                                            }
                                        }
                                    }
                                }
                            }
                            checkOverridableSecurityValue(engine, nested)
                            return VisitAction.WALK_CHILDREN
                        }).Walk()
                    }
                }
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
