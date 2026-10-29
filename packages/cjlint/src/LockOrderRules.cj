package cjlint

import cjcj::ast.*
import std.collection.*

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
                    if (let Some(reference) <- (mutex as RefExpr)) {
                        var line: Int64 = 0
                        if (let Some(target) <- reference.ref.target) { line = target.identifier.Begin().line }
                        sequence.locks.add(reference.ref.identifier.Val() + "/" + line.toString())
                    }
                }
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
        if (sequence.locks.size > 1) { sequences.add(sequence) }
    }
    func lambda(engine: RuleEngine, expression: LambdaExpr): Unit {
        if (let Some(body) <- expression.funcBody) {
            if (let Some(block) <- body.body) {
                let name = "lambda_" + engine.path + "_" + expression.begin.line.toString()
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
            let name = function.identifier.Val() + "_" + packageName + "_" + outer
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
