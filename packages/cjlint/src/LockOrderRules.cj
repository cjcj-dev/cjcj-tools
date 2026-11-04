package cjlint

import cjcj::ast.*
import std.collection.*

// Resolved declaration identity also distinguishes equal spellings in separate
// scopes/files. A member lock additionally belongs to a particular receiver.
func lockOrderIdentity(expression: Expr): Option<String> {
    if (let Some(paren) <- (expression as ParenExpr)) {
        if (let Some(inner) <- paren.expr) { return lockOrderIdentity(inner) }
    }
    if (let Some(reference) <- (expression as RefExpr)) {
        if (reference.isThis || reference.isSuper) {
            if (let Some(owner) <- Ty.GetDeclPtrOfTy(reference.GetTy())) { return Some("this/" + owner.objectId.toString()) }
        }
        if (let Some(target) <- reference.ref.target) { return Some(target.objectId.toString()) }
    } else if (let Some(member) <- (expression as MemberAccess)) {
        if (let Some(target) <- member.GetTarget()) {
            if (let Some(base) <- member.baseExpr) {
                if (let Some(receiver) <- lockOrderIdentity(base)) {
                    return Some(receiver + "." + target.objectId.toString())
                }
            }
        }
    }
    // An unresolved or computed receiver has no reliable static lock identity.
    return None
}

class LockSequence {
    let engine: RuleEngine
    let node: SynchronizedExpr
    let function: String
    let locks = ArrayList<String>()
    init(engine: RuleEngine, node: SynchronizedExpr, function: String) {
        this.engine = engine; this.node = node; this.function = function
    }
}

class LockOrderCheck {
    let sequences = ArrayList<LockSequence>()
    func synchronizedBlock(engine: RuleEngine, node: SynchronizedExpr, function: String): Unit {
        for (existing in sequences) {
            if (existing.function == function && existing.engine.path == engine.path &&
                existing.node.begin == node.begin && existing.node.end == node.end) { return }
        }
        let sequence = LockSequence(engine, node, function)
        Walker(node, visitPre: { nested: Node =>
            if (let Some(syncExpr) <- (nested as SynchronizedExpr)) {
                if (let Some(mutex) <- syncExpr.mutex) {
                    if (let Some(identity) <- lockOrderIdentity(mutex)) { sequence.locks.add(identity) }
                }
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
        if (sequence.locks.size > 1) { sequences.add(sequence) }
    }
    func lambda(engine: RuleEngine, expression: LambdaExpr): Unit {
        if (let Some(body) <- expression.funcBody) {
            if (let Some(block) <- body.body) {
                let name = "lambda_" + expression.objectId.toString()
                Walker(block, visitPre: { node: Node =>
                    if (let Some(syncExpr) <- (node as SynchronizedExpr)) {
                        synchronizedBlock(engine, syncExpr, name); return VisitAction.SKIP_CHILDREN
                    }
                    return VisitAction.WALK_CHILDREN
                }).Walk()
            }
        }
    }
    func functionBody(engine: RuleEngine, body: FuncBody): Unit {
        if (let Some(function) <- body.funcDecl) {
            var outer = function.identifier.Val()
            var packageName = function.fullPackageName
            if (let Some(parent) <- body.parentClassLike) { outer = parent.identifier.Val(); packageName = parent.fullPackageName }
            else if (let Some(parent) <- body.parentStruct) { outer = parent.identifier.Val(); packageName = parent.fullPackageName }
            else if (let Some(parent) <- body.parentEnum) { outer = parent.identifier.Val(); packageName = parent.fullPackageName }
            if (outer.isEmpty() || packageName.isEmpty()) { return }
            let name = function.objectId.toString()
            Walker(body, visitPre: { node: Node =>
                if (let Some(expression) <- (node as LambdaExpr)) { lambda(engine, expression); return VisitAction.SKIP_CHILDREN }
                if (let Some(syncExpr) <- (node as SynchronizedExpr)) {
                    synchronizedBlock(engine, syncExpr, name); return VisitAction.SKIP_CHILDREN
                }
                return VisitAction.WALK_CHILDREN
            }).Walk()
        }
    }
    func collect(engine: RuleEngine, root: Node): Unit {
        Walker(root, visitPre: { node: Node =>
            if (let Some(body) <- (node as FuncBody)) { functionBody(engine, body); return VisitAction.SKIP_CHILDREN }
            if (let Some(expression) <- (node as LambdaExpr)) { lambda(engine, expression); return VisitAction.SKIP_CHILDREN }
            return VisitAction.WALK_CHILDREN
        }).Walk()
    }
    func finish(): Unit {
        let emitted = HashSet<String>()
        for (i in 0..sequences.size) {
            let first = sequences[i]
            for (j in i + 1..sequences.size) {
                let second = sequences[j]
                if (first.function == second.function) { continue }
                let left = ArrayList<String>(); let right = ArrayList<String>()
                for (a in first.locks) { for (b in second.locks) { if (a == b) { left.add(a) } } }
                for (b in second.locks) { for (a in first.locks) { if (a == b) { right.add(b) } } }
                if (left.size < 2 || left == right) { continue }
                let later = if (first.node.begin.line > second.node.begin.line) { first } else { second }
                let earlier = if (first.node.begin.line > second.node.begin.line) { second } else { first }
                let key = "${later.engine.path}:${later.node.begin.line}:${later.node.begin.column}:${earlier.engine.path}:${earlier.node.begin.line}"
                if (emitted.contains(key)) { continue }; emitted.add(key)
                later.engine.emit(later.node, "P_01_dead_lock", [earlier.node.begin.line.toString(), earlier.engine.path])
            }
        }
    }
}
