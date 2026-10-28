package cjlint

import cjcj::chir.*
import std.collection.*

func flowTypeName(typeValue: Type): String {
    let ty = flowBaseType(typeValue)
    if (let Some(custom) <- (ty as CustomType)) { return custom.GetCustomTypeDef().GetSrcCodeIdentifier() }
    return ty.ToString()
}

class FlowFunctionSpec {
    let name: String; let parent: String; let params: Array<String>; let result: String; let packageName: String; let destination: Int64
    init(name: String, parent: String, params: Array<String>, result: String, packageName: String, destination: Int64) {
        this.name=name; this.parent=parent; this.params=params; this.result=result; this.packageName=packageName; this.destination=destination
    }
    func matches(value: Value): Bool {
        if (let Some(function) <- (value as Function)) {
            if (function.GetSrcCodeIdentifier() != name || (packageName != "NOT_CARE" && packageName != function.GetPackageName())) { return false }
            if (parent != "NOT_CARE" && parent != "ANY_TYPE") {
                if (let Some(owner) <- function.GetParentCustomTypeDef()) { if (owner.GetSrcCodeIdentifier() != parent) { return false } }
            }
            let returned = function.GetReturnType().getOrThrow()
            if (result != "NOT_CARE" && result != "ANY_TYPE" && flowTypeName(returned) != result) { return false }
            if (result == "ANY_TYPE" && flowTypeName(returned).isEmpty()) { return false }
            let signature = (function.GetType().getOrThrow() as FuncType).getOrThrow()
            let arguments = signature.GetParamTypes()
            for (i in 0..(if (params.size < arguments.size) { params.size } else { arguments.size })) {
                if (params[i] == "NOT_CARE") { return true }
                if (params[i] != "ANY_TYPE" && params[i] != flowTypeName(arguments[i])) { return false }
            }
            return params.size == arguments.size
        }
        return false
    }
}

func flowArgumentName(value: Value): String {
    if (let Some(local) <- (value as LocalVar)) {
        if (let Some(debug) <- local.GetDebugExpr()) { return debug.GetSrcCodeIdentifier() }
        if (let Some(expression) <- local.GetExpr()) {
            if (let Some(load) <- (expression as Load)) { return flowArgumentName(load.GetLocation()) }
        }
        return local.GetIdentifier()
    }
    return value.GetSrcCodeIdentifier()
}

class ExternalFlowCheck {
    let findings: ArrayList<Finding>
    let sanitized = HashMap<String, HashSet<Int64>>()
    let globals = HashSet<String>()
    let returnDiagnostics = HashSet<String>()
    init(findings: ArrayList<Finding>) { this.findings=findings }
    func returns(block: Block): Bool {
        for (expression in block.GetExpressions()) {
            if (expression.GetExprKind() == ExprKind.EXIT) { return true }
            // This frontend lowers an early return to a store into the return
            // allocation followed by a jump to the shared Exit block.
            if (let Some(store) <- (expression as Store)) {
                if (let Some(local) <- (store.GetLocation() as LocalVar)) { if (local.IsRetValue()) { return true } }
            }
        }
        return false
    }
    func successors(block: Block, result: HashSet<Int64>): Unit {
        if (result.contains(block.nodeId)) { return }; result.add(block.nodeId)
        for (expression in block.GetExpressions()) {
            if (expression.IsTerminator()) { for (next in expression.GetSuccessors()) { successors(next, result) } }
        }
    }
    func decontaminate(value: Value, result: HashSet<Int64>, visited: HashSet<Int64>): Unit {
        for (user in value.GetUsers()) {
            if (visited.contains(user.nodeId)) { continue }; visited.add(user.nodeId)
            if (let Some(branch) <- (user as Branch)) {
                if (branch.GetCondition() == value) {
                    if (returns(branch.GetTrueBlock())) { successors(branch.GetFalseBlock(), result) }
                    if (returns(branch.GetFalseBlock())) { successors(branch.GetTrueBlock(), result) }
                }
            } else if (let Some(next) <- user.GetResult()) { decontaminate(next, result, visited) }
        }
    }
    func mark(value: Value, name: String, tainted: HashSet<String>): Unit {
        tainted.add(name)
        let alias = flowArgumentName(value); tainted.add(alias)
        let blocks = HashSet<Int64>(); decontaminate(value, blocks, HashSet<Int64>()); sanitized[name] = blocks; sanitized[alias] = blocks
    }
    func stored(store: Store, tainted: HashSet<String>): Unit {
        if (let Some(local) <- (store.GetLocation() as LocalVar)) {
            if (local.IsRetValue()) { returned(store); return }
        }
        mark(store.GetLocation(), store.GetLocation().GetSrcCodeIdentifier(), tainted)
    }
    func returned(store: Store): Unit {
        var location = store.GetDebugLocation()
        if (location.GetBeginPos().IsZero()) {
            if (let Some(block) <- store.GetParentBlock()) {
                if (let Some(terminator) <- block.GetTerminator()) { location = terminator.GetDebugLocation() }
            }
        }
        let key = "${location.GetFileID()}:${location.GetBeginPos().line}:${location.GetBeginPos().column}"
        if (returnDiagnostics.contains(key)) { return }; returnDiagnostics.add(key)
        flowEmit(findings, location, "G_CHK_01_illegal_return", [])
    }
    func argumentUser(user: Expression, value: Value): Unit {
        var name = ""; var member = false
        let arguments = ArrayList<Value>()
        if (let Some((callee, args)) <- flowCall(user)) {
            for (spec in flowPropagation) { if (spec.name == callee.GetSrcCodeIdentifier()) { return } }
            name = callee.GetSrcCodeIdentifier()
            if (let Some(function) <- (callee as Function)) {
                member = function.GetBody().isSome() && !function.TestAttr(Attribute.STATIC) &&
                    (function.GetParentCustomTypeDef().isSome() || function.GetFuncKind() == FuncKind.LAMBDA)
            } else if (let Some(local) <- (callee as LocalVar)) {
                if (let Some(expression) <- local.GetExpr()) { if (let Some(lambdaExpr) <- (expression as Lambda)) { name = lambdaExpr.GetSrcCodeIdentifier() } }
            }
            for (argument in args) { arguments.add(argument) }
        } else if (let Some(call) <- (user as Invoke)) {
            name = call.GetMethodName(); for (argument in call.GetArgs()) { arguments.add(argument) }
        } else if (let Some(call) <- (user as InvokeStatic)) {
            name = call.GetMethodName(); for (argument in call.GetArgs()) { arguments.add(argument) }
        } else if (let Some(call) <- (user as TryInvoke)) {
            name = call.GetMethodName(); for (argument in call.GetArgs()) { arguments.add(argument) }
        } else { return }
        let block = user.GetParentBlock().getOrThrow()
        if (let Some(blocks) <- sanitized.get(flowArgumentName(value))) { if (blocks.contains(block.nodeId)) { return } }
        for (i in 0..arguments.size) {
            if (arguments[i] == value) {
                let index = if (member) { i } else { i + 1 }
                flowEmit(findings, user.GetDebugLocation(), "G_CHK_01_illegal_func_arg",
                    [name, "the ${index}st argument is untrusted, we can't deliver it outter."])
            }
        }
    }
    func call(expression: Expression, tainted: HashSet<String>): Unit {
        if (let Some((callee, args)) <- flowCall(expression)) {
            for (spec in flowSources) {
                if (spec.matches(callee)) {
                    if (let Some(result) <- expression.GetResult()) {
                        mark(result, result.GetIdentifier(), tainted)
                        for (user in result.GetUsers()) {
                            if (let Some(store) <- (user as Store)) { stored(store, tainted) }
                            else { argumentUser(user, result) }
                        }
                    }
                    return
                }
            }
            for (spec in flowPropagation) {
                if (!spec.matches(callee)) { continue }
                var found = false
                for (argument in args) { if (tainted.contains(flowArgumentName(argument))) { found = true } }
                if (found) {
                    var destination: Option<Value> = None
                    if (spec.destination == -1) { if (let Some(value) <- expression.GetResult()) { destination = value } }
                    else if (spec.destination > 0 && spec.destination <= args.size) { destination = args[spec.destination - 1] }
                    if (let Some(value) <- destination) {
                        mark(value, flowArgumentName(value), tainted)
                        for (user in value.GetUsers()) { if (let Some(store) <- (user as Store)) { stored(store, tainted); break } }
                    }
                    return
                }
            }
        }
    }
    func derived(value: Value, result: LocalVar, tainted: HashSet<String>): Unit {
        let name = if (value.GetSrcCodeIdentifier().isEmpty()) { value.GetIdentifier() } else { value.GetSrcCodeIdentifier() }
        if (!tainted.contains(name)) { return }; tainted.add(result.GetIdentifier())
        for (user in result.GetUsers()) {
            if (let Some(store) <- (user as Store)) {
                if (let Some(local) <- (store.GetLocation() as LocalVar)) { if (local.IsRetValue()) { returned(store); continue } }
                if (store.GetLocation() == result) { tainted.remove(name) } else { stored(store, tainted) }
            } else { argumentUser(user, result) }
        }
    }
    func visitBlock(block: Block, incoming: HashSet<String>, visited: HashSet<Int64>): Unit {
        if (visited.contains(block.nodeId)) { return }; visited.add(block.nodeId)
        let tainted = HashSet<String>(); for (name in incoming) { tainted.add(name) }
        for (expression in block.GetExpressions()) {
            if (let Some(lambdaExpr) <- (expression as Lambda)) {
                if (let Some(entry) <- lambdaExpr.GetEntryBlock()) { visitBlock(entry, globals, HashSet<Int64>()) }; continue
            }
            if (expression.GetExprKind() == ExprKind.APPLY) { call(expression, tainted); continue }
            if (let Some(load) <- (expression as Load)) {
                if (let Some(result) <- load.GetResult()) { derived(load.GetLocation(), result, tainted) }; continue
            }
            if (let Some(store) <- (expression as Store)) {
                if (tainted.contains(flowArgumentName(store.GetValue()))) {
                    if (let Some(local) <- (store.GetLocation() as LocalVar)) { if (local.IsRetValue()) { returned(store) } }
                    tainted.add(flowArgumentName(store.GetLocation()))
                }; continue
            }
            if (let Some(cast) <- (expression as TypeCast)) {
                if (let Some(result) <- cast.GetResult()) { derived(cast.GetSourceValue(), result, tainted) }
                if (!expression.IsTerminator()) { continue }
            }
            if (let Some(tupleExpr) <- (expression as Tuple)) {
                var taint = false
                for (value in tupleExpr.GetElementValues()) { if (tainted.contains(flowArgumentName(value))) { taint=true } }
                if (taint) {
                    if (let Some(result) <- tupleExpr.GetResult()) {
                        let users=result.GetUsers()
                        if (users.size == 1) { if (let Some(store) <- (users[0] as Store)) { stored(store, tainted) } }
                    }
                }; continue
            }
            if (let Some(store) <- (expression as StoreElementRef)) {
                if (tainted.contains(flowArgumentName(store.GetValue()))) { tainted.add(flowArgumentName(store.GetLocation())) }; continue
            }
            if (let Some(field) <- (expression as Field)) {
                if (tainted.contains(flowArgumentName(field.GetBase()))) {
                    if (let Some(result) <- field.GetResult()) { tainted.add(flowArgumentName(result)) }
                }; continue
            }
            if (expression.IsTerminator()) {
                if (expression.GetExprKind() == ExprKind.TRY_APPLY) { call(expression, tainted) }
                for (next in expression.GetSuccessors()) { visitBlock(next, tainted, visited) }
            }
        }
    }
    func run(pkg: Package): Unit {
        for (variable in pkg.GetGlobalVarsWithInit()) {
            if (let Some(function) <- variable.GetInitFunc()) {
                if (let Some(entry) <- function.GetEntryBlock()) {
                    for (expression in entry.GetExpressions()) { if (expression.GetExprKind() == ExprKind.APPLY) { call(expression, globals) } }
                }
            }
        }
        for (function in pkg.GetGlobalFuncsWithBody(includeSrcCodeImported: false)) {
            if (!function.GetIdentifier().startsWith("@_CGV")) {
                if (let Some(entry) <- function.GetEntryBlock()) { visitBlock(entry, globals, HashSet<Int64>()) }
            }
        }
    }
}
