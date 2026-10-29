package cjlint

import cjcj::ast.*
import std.collection.*

func lockVariable(node: Option<Expr>): Option<VarDecl> {
    if (let Some(expression) <- node) {
        if ((expression as RefExpr).isSome() || (expression as MemberAccess).isSome()) {
            if (let Some(target) <- expression.GetTarget()) { return target as VarDecl }
        }
    }
    return None
}

func referenceLockVariable(variable: VarDecl): Bool {
    if (let Some(ty) <- variable.typeNode) {
        if (let Some(reference) <- (ty as RefType)) { return reference.ref.identifier == "ReentrantMutex" }
    }
    if (let Some(initializer) <- variable.initializer) {
        if (let Some(call) <- (initializer as CallExpr)) {
            if (let Some(base) <- call.baseFunc) {
                if (let Some(reference) <- (base as RefExpr)) { return reference.ref.identifier == "ReentrantMutex" }
            }
            return false
        }
    }
    return true
}

class TryLockRecord {
    let member: MemberAccess
    let variable: VarDecl
    var released = false
    init(member: MemberAccess, variable: VarDecl) { this.member = member; this.variable = variable }
}

func checkTryLocks(engine: RuleEngine, root: Node): Unit {
    let variables = HashSet<Decl>()
    let checked = HashSet<String>()
    Walker(root, visitPre: { node: Node =>
        if (let Some(variable) <- (node as VarDecl)) {
            if (referenceLockVariable(variable)) { variables.add(variable) }
        }
        if (let Some(attempt) <- (node as TryExpr)) {
            let key = "${attempt.begin.fileID}:${attempt.begin.line}"
            if (checked.contains(key)) { return VisitAction.SKIP_CHILDREN }
            checked.add(key)
            let acquired = HashMap<Decl, TryLockRecord>()
            if (let Some(block) <- attempt.tryBlock) {
                Walker(block, visitPre: { nested: Node =>
                    if (let Some(variable) <- (nested as VarDecl)) {
                        if (referenceLockVariable(variable)) { variables.add(variable) }
                    }
                    if (let Some(member) <- (nested as MemberAccess)) {
                        if (member.field == "lock") {
                            if (let Some(variable) <- lockVariable(member.baseExpr)) {
                                if (variables.contains(variable) && !acquired.contains(variable)) {
                                    acquired[variable] = TryLockRecord(member, variable)
                                }
                            }
                        }
                    }
                    return VisitAction.WALK_CHILDREN
                }).Walk()
            }
            if (let Some(block) <- attempt.finallyBlock) {
                Walker(block, visitPre: { nested: Node =>
                    if (let Some(variable) <- (nested as VarDecl)) {
                        if (referenceLockVariable(variable)) { variables.add(variable) }
                    }
                    if (let Some(member) <- (nested as MemberAccess)) {
                        if (member.field == "unlock") {
                            if (let Some(variable) <- lockVariable(member.baseExpr)) {
                                if (let Some(record) <- acquired.get(variable)) { record.released = true }
                            }
                        }
                    }
                    return VisitAction.WALK_CHILDREN
                }).Walk()
            }
            for ((_, record) in acquired) {
                if (record.released) { continue }
                var prefix = ""
                if (let Some(base) <- record.member.baseExpr) {
                    if (let Some(member) <- (base as MemberAccess)) {
                        if (let Some(receiver) <- member.baseExpr) {
                            if (let Some(reference) <- (receiver as RefExpr)) { prefix = reference.ref.identifier.Val() + "." }
                        }
                    }
                }
                let name = record.variable.identifier.Val()
                engine.emit(record.member, "G_CON_02_lock", [prefix + name, name])
            }
            return VisitAction.SKIP_CHILDREN
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

class ThreadSafetyCheck {
    let checked = HashSet<Node>()
    let safe = HashSet<Node>()
    func assignmentSafe(assignment: AssignExpr): Bool {
        if (let Some(left) <- assignment.leftValue) {
            if (let Some(reference) <- (left as RefExpr)) {
                if (let Some(target) <- reference.ref.target) {
                    return !target.TestAttr(Attribute.STATIC) && !target.TestAttr(Attribute.GLOBAL)
                }
                return false
            }
        }
        return true
    }
    func mutexState(call: CallExpr): Int64 {
        if (let Some(base) <- call.baseFunc) {
            if (let Some(member) <- (base as MemberAccess)) {
                if (let Some(receiver) <- member.baseExpr) {
                    if (let Some(reference) <- (receiver as RefExpr)) {
                        if (let Some(target) <- reference.ref.target) {
                            if (let Some(ty) <- target.GetTy()) {
                                if (ty.name == "ReentrantMutex") { return if (member.field == "lock") { 1 } else { -1 } }
                            }
                        }
                    }
                }
            }
        }
        return 0
    }
    func functionSafe(target: Option<Decl>): Bool {
        if (let Some(declaration) <- target) {
            if (let Some(function) <- (declaration as FuncDecl)) {
                if (let Some(body) <- function.funcBody) {
                    if (let Some(block) <- body.body) { return blockSafe(block) }
                }
            }
        }
        return true
    }
    func callSafe(call: CallExpr): Bool {
        if (let Some(base) <- call.baseFunc) {
            if (let Some(reference) <- (base as RefExpr)) {
                if (!functionSafe(reference.ref.target)) { return false }
                for (target in reference.ref.targets) { if (!functionSafe(target)) { return false } }
            }
        }
        return true
    }
    func blockSafe(block: Block): Bool {
        var locked = false
        for (node in block.body) {
            if (let Some(assignment) <- (node as AssignExpr)) {
                if (!locked && !assignmentSafe(assignment)) { return false }
            } else if (let Some(increment) <- (node as IncOrDecExpr)) {
                if (let Some(desugared) <- increment.desugarExpr) {
                    if (let Some(assignment) <- (desugared as AssignExpr)) {
                        if (!locked && !assignmentSafe(assignment)) { return false }
                    }
                }
            } else if (let Some(call) <- (node as CallExpr)) {
                if (safe.contains(call) || checked.contains(call)) { continue }
                checked.add(call)
                let state = mutexState(call)
                if (state == 1) { locked = true } else if (state == -1) { locked = false }
                if (!callSafe(call) && !locked) { return false }
                safe.add(call)
            }
        }
        return true
    }
}

func checkThreadSafeOverrides(engine: RuleEngine, root: Node): Unit {
    let check = ThreadSafetyCheck()
    let unsafeMethods = ArrayList<(String, FuncDecl)>()
    let safeNames = HashSet<String>()
    Walker(root, visitPre: { node: Node =>
        if (let Some(function) <- (node as FuncDecl)) {
            if (hasModifier(function, TokenKind.OVERRIDE) || hasModifier(function, TokenKind.REDEF)) {
                if (let Some(body) <- function.funcBody) {
                    if (let Some(block) <- body.body) {
                        if (!check.blockSafe(block)) {
                            if (let Some(owner) <- function.outerDecl) {
                                if (let Some(child) <- (owner as ClassDecl)) {
                                    if (let Some(parent) <- child.GetSuperClassDecl()) { unsafeMethods.add((parent.identifier.Val(), function)) }
                                }
                            }
                        }
                    }
                }
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
    Walker(root, visitPre: { node: Node =>
        if (let Some(parent) <- (node as ClassDecl)) {
            for ((name, _) in unsafeMethods) {
                if (name != parent.identifier.Val()) { continue }
                for (member in parent.GetMemberDecls()) {
                    if (let Some(function) <- (member as FuncDecl)) {
                        if (check.functionSafe(function)) { safeNames.add(name + "/" + function.identifier.Val()) }
                    }
                }
                break
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
    for ((name, function) in unsafeMethods) {
        if (safeNames.contains(name + "/" + function.identifier.Val())) {
            engine.emit(function, "G_CON_03_override_func_thread_safe", [function.identifier.Val()])
        }
    }
}
