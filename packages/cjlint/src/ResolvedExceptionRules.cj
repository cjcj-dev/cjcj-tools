package cjlint

import cjcj::ast.*

func catchesNoneValue(attempt: TryExpr): Bool {
    for (pattern in attempt.catchPatterns) {
        if ((pattern as WildcardPattern).isSome()) { return true }
        if (let Some(exception) <- (pattern as ExceptTypePattern)) {
            for (node in exception.types) {
                if (let Some(reference) <- (node as RefType)) {
                    if (reference.ref.identifier.Val() == "NoneValueException") { return true }
                }
            }
        }
    }
    return false
}

func checkOptionThrows(engine: RuleEngine, root: Node, protectedByCatch: Bool): Unit {
    Walker(root, visitPre: { node: Node =>
        if (let Some(attempt) <- (node as TryExpr)) {
            if (catchesNoneValue(attempt)) {
                if (let Some(block) <- attempt.tryBlock) { checkOptionThrows(engine, block, true) }
                for (block in attempt.catchBlocks) { checkOptionThrows(engine, block, protectedByCatch) }
                if (let Some(block) <- attempt.finallyBlock) { checkOptionThrows(engine, block, protectedByCatch) }
                return VisitAction.SKIP_CHILDREN
            }
        }
        if (!protectedByCatch) {
            if (let Some(member) <- (node as MemberAccess)) {
                if (member.field == "getOrThrow") {
                    if (let Some(base) <- member.baseExpr) {
                        if (let Some(ty) <- base.GetTy()) {
                            if (ty.name == "Option") {
                                engine.findings.add(Finding(engine.path, base.end, base.end + 1,
                                    "G_ERR_03_avoid_option_getorthrow", []))
                            }
                        }
                    }
                }
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

func emitMutexVisibility(engine: RuleEngine, variable: VarDecl, index: Int64, value: String): Unit {
    engine.findings.add(Finding(engine.path, variable.identifier.Begin(), variable.identifier.End(),
        "G_CON_01_synchronized_object_modifier_information_" + index.toString(), [value]))
}

func checkMutexVisibility(engine: RuleEngine, root: Node): Unit {
    Walker(root, visitPre: { node: Node =>
        if (let Some(variable) <- (node as VarDecl)) {
            if (let Some(ty) <- variable.GetTy()) {
                if (ty.name != "ReentrantMutex") { return VisitAction.SKIP_CHILDREN }
            } else { return VisitAction.SKIP_CHILDREN }
            let defaultPackage = variable.fullPackageName == "default"
            if (variable.TestAttr(Attribute.GLOBAL)) {
                if (defaultPackage) { emitMutexVisibility(engine, variable, 2, variable.identifier.Val()) }
                else if (hasModifier(variable, TokenKind.PUBLIC)) { emitMutexVisibility(engine, variable, 0, "public") }
            }
            if (let Some(parent) <- variable.outerDecl) {
                if ((parent as ClassDecl).isSome() || (parent as StructDecl).isSome()) {
                    if (defaultPackage) {
                        if (!hasModifier(variable, TokenKind.PRIVATE)) { emitMutexVisibility(engine, variable, 1, "private") }
                    } else if (hasModifier(parent, TokenKind.PUBLIC)) {
                        if (parent.TestAttr(Attribute.PUBLIC) && variable.TestAttr(Attribute.PUBLIC)) {
                            emitMutexVisibility(engine, variable, 1, "private")
                        }
                        if ((parent.TestAttr(Attribute.OPEN) || parent.TestAttr(Attribute.ABSTRACT)) &&
                            (variable.TestAttr(Attribute.PUBLIC) || variable.TestAttr(Attribute.PROTECTED))) {
                            emitMutexVisibility(engine, variable, 1, "private")
                        }
                    }
                }
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
