package cjlint

import cjcj::ast.*
import std.collection.*

class ScopedCallable {
    let declaration: FuncDecl
    let signature: FuncTy
    let scope: Option<Block>
    init(declaration: FuncDecl, signature: FuncTy, scope: Option<Block>) {
        this.declaration = declaration; this.signature = signature; this.scope = scope
    }
}

func sameCallableScope(left: Option<Block>, right: Option<Block>): Bool {
    if (let Some(a) <- left) {
        if (let Some(b) <- right) { return refEq(a, b) }
        return false
    }
    return right.isNone()
}

func overloadParameterRelationship(left: FuncTy, right: FuncTy): Bool {
    if (left.paramTys.size != right.paramTys.size) { return false }
    let extensions = HashMap<Ty, ArrayList<Type>>()
    for (index in 0..left.paramTys.size) {
        if (!inheritsResolvedType(left.paramTys[index], right.paramTys[index], extensions, HashSet<Ty>()) &&
            !inheritsResolvedType(right.paramTys[index], left.paramTys[index], extensions, HashSet<Ty>())) { return false }
    }
    return true
}

func differentCallableParameters(left: FuncTy, right: FuncTy): Bool {
    if (left.paramTys.size != right.paramTys.size) { return true }
    for (index in 0..left.paramTys.size) {
        if (left.paramTys[index].String() != right.paramTys[index].String()) { return true }
    }
    return false
}

func recordOverload(engine: RuleEngine, declaration: FuncDecl, scope: Option<Block>,
    seen: ArrayList<ScopedCallable>): Unit {
    if (hasModifier(declaration, TokenKind.COMMON) || hasModifier(declaration, TokenKind.SPECIFIC)) { return }
    if (let Some(ty) <- declaration.GetTy()) {
        if (let Some(signature) <- (ty as FuncTy)) {
            for (previous in seen) {
                if (previous.declaration.identifier.GetRawText() != declaration.identifier.GetRawText()) { continue }
                let sameScope = sameCallableScope(previous.scope, scope)
                if (!sameScope && differentCallableParameters(previous.signature, signature)) {
                    engine.emitIdentifier(declaration, "G_FUN_03_overload_in_different_scopes")
                    break
                }
                if (sameScope && overloadParameterRelationship(previous.signature, signature)) {
                    engine.emitIdentifier(declaration, "G_FUN_03_params_in_overload_funcs")
                    break
                }
            }
            seen.add(ScopedCallable(declaration, signature, scope))
        }
    }
}

func checkFunctionOverloads(engine: RuleEngine, root: File): Unit {
    let seen = ArrayList<ScopedCallable>()
    let scopes = ArrayList<Block>()
    for (declaration in root.decls) {
        if (let Some(function) <- (declaration as FuncDecl)) {
            if (hasModifier(function, TokenKind.COMMON) || hasModifier(function, TokenKind.SPECIFIC)) { break }
            recordOverload(engine, function, None, seen)
        }
    }
    Walker(root, visitPre: { node: Node =>
        if (let Some(function) <- (node as FuncDecl)) {
            if (!scopes.isEmpty()) { recordOverload(engine, function, scopes[scopes.size - 1], seen) }
        }
        if (let Some(block) <- (node as Block)) { scopes.add(block) }
        return VisitAction.WALK_CHILDREN
    }, visitPost: { node: Node =>
        if (let Some(block) <- (node as Block)) {
            var index = seen.size - 1
            while (index >= 0) {
                if (sameCallableScope(seen[index].scope, block)) { seen.remove(at: index) }
                index--
            }
            scopes.remove(at: scopes.size - 1)
        }
        return VisitAction.KEEP_DECISION
    }).Walk()
}
