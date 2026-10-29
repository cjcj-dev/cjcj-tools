package cjlint

import cjcj::ast.*
import cjcj::basic.Position
import std.collection.*

func enclosingScope(scope: String, level: Int64): String {
    var result = scope
    for (_ in 0..level) {
        if (let Some(index) <- result.lastIndexOf("0")) { result = result[..index] } else { break }
    }
    return result
}

class MinimumScopeCheck {
    let references = HashMap<Decl, HashSet<String>>()
    let spawnGlobals = HashSet<Decl>()
    var callScope = ""
    var callPosition = Position(0, 0, 0)
    var spawnLevel: Int64 = 0
    func collect<T>(input: Option<T>, level!: Int64 = 0): Unit where T <: Node {
        if (let Some(root) <- input) {
            Walker(root, visitPre: { node: Node =>
                if (node.astKind == ASTKind.CALL_EXPR && callScope.isEmpty()) {
                    callScope = node.scopeName; callPosition = node.begin
                }
                if (let Some(reference) <- (node as RefExpr)) {
                    if (let Some(target) <- reference.ref.target) {
                        if (let Some(variable) <- (target as VarDecl)) {
                            if (variable.astKind != ASTKind.VAR_DECL ||
                                (variable.TestAttr(Attribute.GLOBAL) && variable.TestAttr(Attribute.PUBLIC)) ||
                                (variable.TestAttr(Attribute.IS_CHECK_VISITED) && !variable.TestAttr(Attribute.INITIALIZATION_CHECKED)) ||
                                variable.TestAttr(Attribute.IN_CLASSLIKE) || variable.TestAttr(Attribute.IN_STRUCT) ||
                                variable.TestAttr(Attribute.IN_ENUM)) { return VisitAction.SKIP_CHILDREN }
                            if (spawnLevel > 0 && variable.TestAttr(Attribute.GLOBAL) && variable.isVar) {
                                spawnGlobals.add(variable); return VisitAction.SKIP_CHILDREN
                            }
                            let scope = if (callScope.isEmpty()) { enclosingScope(reference.scopeName, level) } else { callScope }
                            if (!references.contains(variable)) { references[variable] = HashSet<String>() }
                            references[variable].add(scope)
                        }
                    }
                    return VisitAction.SKIP_CHILDREN
                }
                if (node.astKind == ASTKind.INTERPOLATION_EXPR) { return VisitAction.SKIP_CHILDREN }
                if (let Some(conditional) <- (node as IfExpr)) {
                    collect(conditional.condExpr, level: 1); collect(conditional.thenBody)
                    if (conditional.hasElse) { collect(conditional.elseBody) }
                    return VisitAction.SKIP_CHILDREN
                }
                if (let Some(loop) <- (node as WhileExpr)) {
                    collect(loop.condExpr, level: 1); collect(loop.body)
                    return VisitAction.SKIP_CHILDREN
                }
                if (let Some(loop) <- (node as DoWhileExpr)) {
                    collect(loop.condExpr, level: 1); collect(loop.body)
                    return VisitAction.SKIP_CHILDREN
                }
                if (let Some(variable) <- (node as VarDecl)) {
                    if (variable.identifier == ".mtx") {
                        if (let Some(ty) <- variable.GetTy()) {
                            if (ty.name == "ReentrantMutex") { collect(variable.initializer, level: 2); return VisitAction.SKIP_CHILDREN }
                        }
                    }
                }
                if (let Some(spawnExpr) <- (node as SpawnExpr)) {
                    spawnLevel++
                    collect(spawnExpr.futureObj, level: 2); collect(spawnExpr.arg, level: 2); collect(spawnExpr.task, level: 2)
                    return VisitAction.SKIP_CHILDREN
                }
                return VisitAction.WALK_CHILDREN
            }, visitPost: { node: Node =>
                if (node.astKind == ASTKind.SPAWN_EXPR) { spawnLevel-- }
                if (node.astKind == ASTKind.CALL_EXPR && node.begin == callPosition) {
                    callScope = ""; callPosition = Position(0, 0, 0)
                }
                return VisitAction.KEEP_DECISION
            }).Walk()
        }
    }
    func diagnose(engine: RuleEngine): Unit {
        for ((variable, scopes) in references) {
            if (spawnGlobals.contains(variable) || scopes.contains(variable.scopeName)) { continue }
            var common: Option<String> = None
            for (scope in scopes) {
                if (let Some(prefix) <- common) {
                    var index: Int64 = 0
                    while (index < prefix.size && index < scope.size && prefix[index] == scope[index]) { index++ }
                    common = prefix[..index]
                } else { common = scope }
            }
            var prefix = common ?? ""
            if (prefix.endsWith("0")) { prefix = prefix[..prefix.size - 1] }
            if (variable.scopeName.size < prefix.size) {
                engine.emit(variable, "G_VAR_02_min_scope", [variable.identifier.Val()])
            }
        }
    }
}

func checkMinimumScope(engine: RuleEngine, root: Node): Unit {
    let check = MinimumScopeCheck()
    check.collect(Some(root))
    check.diagnose(engine)
}
