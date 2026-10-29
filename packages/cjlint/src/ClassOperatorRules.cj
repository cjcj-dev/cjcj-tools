package cjlint

import cjcj::ast.*
import std.collection.*

func explicitAccess(declaration: Decl): Int64 {
    if (hasModifier(declaration, TokenKind.PRIVATE)) { return 1 }
    if (hasModifier(declaration, TokenKind.PROTECTED)) { return 3 }
    if (hasModifier(declaration, TokenKind.PUBLIC)) { return 4 }
    return 0
}

func accessSignature(function: FuncDecl): String {
    var result = function.identifier.Val() + "("
    if (let Some(body) <- function.funcBody) {
        if (!body.paramLists.isEmpty()) {
            for (parameter in body.paramLists[0].params) {
                if (let Some(ty) <- parameter.typeNode) { result += ty.ToString() }
                result += ","
            }
        }
    }
    return result + ")"
}

func exposesParentCall(function: FuncDecl, inherited: HashMap<String, Int64>,
    parentName: String, childName: String, access: Int64): Bool {
    if (let Some(body) <- function.funcBody) {
        if (let Some(block) <- body.body) {
            if (block.body.size != 1) { return false }
            if (let Some(call) <- (block.body[0] as CallExpr)) {
                if (let Some(base) <- call.baseFunc) {
                    if (let Some(member) <- (base as MemberAccess)) {
                        if (let Some(target) <- member.GetTarget()) {
                            if (let Some(called) <- (target as FuncDecl)) {
                                if (let Some(owner) <- called.outerDecl) {
                                    if ((owner as ClassDecl).isSome() &&
                                        (owner.identifier == parentName || owner.identifier == childName)) {
                                        if (let Some(previous) <- inherited.get(accessSignature(called))) {
                                            return previous < access
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return false
}

func checkChildAccess(engine: RuleEngine, parent: ClassDecl, inherited: HashMap<String, Int64>,
    parentName: String, visited: HashSet<Decl>): Unit {
    for (declaration in parent.subDecls) {
        if (visited.contains(declaration)) { continue }
        visited.add(declaration)
        if (let Some(child) <- (declaration as ClassDecl)) {
            if (child.GetMemberDecls().isEmpty()) { continue }
            for (member in child.GetMemberDecls()) {
                if (visited.contains(member)) { continue }
                visited.add(member)
                if (let Some(function) <- (member as FuncDecl)) {
                    let access = explicitAccess(function)
                    if (access == 0) { continue }
                    if (let Some(previous) <- inherited.get(accessSignature(function))) {
                        if (previous < access) {
                            engine.emitIdentifier(function, "G_CLS_01_increase_the_accessibility_of_the_function_01")
                        }
                    } else if (exposesParentCall(function, inherited, parentName, child.identifier.Val(), access)) {
                        engine.emitIdentifier(function, "G_CLS_01_increase_the_accessibility_of_the_function_02")
                    }
                }
            }
            checkChildAccess(engine, child, inherited, parent.identifier.Val(), visited)
        }
    }
}

func checkClassAccess(engine: RuleEngine, parent: ClassDecl): Unit {
    if (parent.subDecls.isEmpty()) { return }
    let inherited = HashMap<String, Int64>()
    for (member in parent.GetMemberDecls()) {
        if (let Some(function) <- (member as FuncDecl)) {
            let access = explicitAccess(function)
            if (hasModifier(function, TokenKind.OPEN) && access != 0) {
                inherited[accessSignature(function)] = access
            }
        }
    }
    checkChildAccess(engine, parent, inherited, parent.identifier.Val(), HashSet<Decl>())
}

func checkOperatorConvention(engine: RuleEngine, function: FuncDecl): Unit {
    if (!function.TestAttr(Attribute.OPERATOR)) { return }
    let correspondingOperations = HashSet<TokenKind>()
    if ([TokenKind.ADD, TokenKind.SUB, TokenKind.MUT, TokenKind.DIV, TokenKind.LT, TokenKind.GT,
        TokenKind.LE, TokenKind.GE, TokenKind.NOTEQ, TokenKind.EQUAL].contains(function.op)) {
        Walker(function, visitPre: { node: Node =>
            if (let Some(binary) <- (node as BinaryExpr)) {
                if (binary.op == function.op) { correspondingOperations.add(binary.op) }
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
    }
    if (correspondingOperations.isEmpty()) {
        engine.emit(function, "G_OPR_01_avoid_operator_overloading_that_violates_conventions_02", [function.identifier.Val()])
    }
}

func runClassOperatorRules(engine: RuleEngine, root: Node): Unit {
    Walker(root, visitPre: { node: Node =>
        if (engine.selected.contains("G.CLS.01")) {
            if (let Some(parent) <- (node as ClassDecl)) { checkClassAccess(engine, parent) }
        }
        if (engine.selected.contains("G.OPR.01")) {
            if (let Some(extension) <- (node as ExtendDecl)) {
                if (let Some(ty) <- extension.GetTy()) {
                    if (ty.IsPrimitive()) {
                        for (member in extension.members) {
                            if ((member as FuncDecl).isSome() && member.TestAttr(Attribute.OPERATOR)) {
                                engine.emit(member, "G_OPR_01_avoid_operator_overloading_that_violates_conventions_01", [member.identifier.Val()])
                            }
                        }
                    }
                }
            }
            if (let Some(function) <- (node as FuncDecl)) { checkOperatorConvention(engine, function) }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
