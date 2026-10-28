package cjlint

import cjcj::chir.*
import std.collection.*
import std.sort.sort

class SharedLocation {
    let base: Value; let name: String; let key: String; let location: DebugLocation
    init(base: Value, name: String, path: String, location: DebugLocation) {
        this.base = base; this.name = name; this.key = "${base.nodeId}:" + path; this.location = location
    }
}

func flowSharedBase(value: Value): (Value, String, String, DebugLocation) {
    if (let Some(expression) <- flowValueExpression(value)) {
        if (let Some(load) <- (expression as Load)) { return flowSharedBase(load.GetLocation()) }
        if (let Some(cast) <- (expression as TypeCast)) { return flowSharedBase(cast.GetSourceValue()) }
        if (let Some(element) <- (expression as GetElementRef)) { return flowSharedPath(element.GetLocation(), element.GetPath()) }
        if (let Some(field) <- (expression as Field)) { return flowSharedPath(field.GetBase(), field.GetPath()) }
    }
    let name = if (let Some(debug) <- flowDebug(value)) { debug.GetSrcCodeIdentifier() } else { value.GetSrcCodeIdentifier() }
    var location = value.GetDebugLocation()
    if (!location.IsValid()) { if (let Some(debug) <- flowDebug(value)) { location = debug.GetDebugLocation() } }
    return (value, name, "", location)
}

func flowSharedPath(base: Value, path: ArrayList<UInt64>): (Value, String, String, DebugLocation) {
    let (root, initialName, initialPath, initialLocation) = flowSharedBase(base)
    var name = initialName; var identity = initialPath; var location = initialLocation
    if (let Some(ty) <- base.GetType()) {
        var current = flowBaseType(ty)
        for (index in path) {
            if (let Some(custom) <- (current as CustomType)) {
                let member = custom.GetCustomTypeDef().GetInstanceVar(Int64(index))
                name += "." + member.name; identity += ".${index}"
                if (initialName == "this" && initialPath.isEmpty()) { location = member.loc }
                current = flowBaseType(member.ty)
            } else { identity += ".${index}" }
        }
    }
    return (root, name, identity, location)
}

class SpawnMutexCheck {
    let findings: ArrayList<Finding>
    let targets = HashMap<String, SharedLocation>()
    let writes = HashSet<String>()
    let unlocked = HashMap<String, HashMap<String, DebugLocation>>()
    let locked = HashMap<String, HashMap<String, HashMap<String, DebugLocation>>>()
    let mutexes = HashMap<String, SharedLocation>()
    let checked = HashSet<Int64>()
    let aliases = HashMap<Int64, Value>()
    init(findings: ArrayList<Finding>) { this.findings = findings }
    func uncast(value: Value): Value {
        if (let Some(alias) <- aliases.get(value.nodeId)) { return uncast(alias) }
        if (let Some(expression) <- flowValueExpression(value)) {
            if (let Some(load) <- (expression as Load)) { return uncast(load.GetLocation()) }
            if (let Some(cast) <- (expression as TypeCast)) { return uncast(cast.GetSourceValue()) }
        }
        return value
    }
    func sharedBase(value: Value): (Value, String, String, DebugLocation) {
        if (let Some(alias) <- aliases.get(value.nodeId)) { return sharedBase(alias) }
        if (let Some(expression) <- flowValueExpression(value)) {
            if (let Some(load) <- (expression as Load)) { return sharedBase(load.GetLocation()) }
            if (let Some(cast) <- (expression as TypeCast)) { return sharedBase(cast.GetSourceValue()) }
            if (let Some(element) <- (expression as GetElementRef)) { return sharedPath(element.GetLocation(), element.GetPath()) }
            if (let Some(field) <- (expression as Field)) { return sharedPath(field.GetBase(), field.GetPath()) }
        }
        return flowSharedBase(value)
    }
    func sharedPath(value: Value, path: ArrayList<UInt64>): (Value, String, String, DebugLocation) {
        let object = uncast(value)
        if (!path.isEmpty()) {
            if (let Some(ty) <- object.GetType()) {
                if (let Some(custom) <- (flowBaseType(ty) as CustomType)) {
                    if (custom.GetCustomTypeDef().GetIdentifier().startsWith("$Cl")) {
                        // CreateAutoEnvImplObject stores each captured value in
                        // the corresponding actual environment allocation field.
                        for (user in object.GetUsers()) {
                            if (let Some(store) <- (user as StoreElementRef)) {
                                let storedPath = store.GetPath()
                                if (store.GetLocation() == object && storedPath.size == 1 && storedPath[0] == path[0]) {
                                    if (path.size == 1) { return sharedBase(store.GetValue()) }
                                    let rest = ArrayList<UInt64>()
                                    for (index in 1..path.size) { rest.add(path[index]) }
                                    return sharedPath(store.GetValue(), rest)
                                }
                            }
                        }
                    }
                }
            }
        }
        let (base, initialName, initialPath, initialLocation) = sharedBase(object)
        var name = initialName; var identity = initialPath; var location = initialLocation
        if (let Some(ty) <- object.GetType()) {
            var current = flowBaseType(ty)
            for (index in path) {
                if (let Some(custom) <- (current as CustomType)) {
                    let member = custom.GetCustomTypeDef().GetInstanceVar(Int64(index))
                    name += "." + member.name; identity += ".${index}"
                    if (initialName == "this" && initialPath.isEmpty()) { location = member.loc }
                    current = flowBaseType(member.ty)
                } else { identity += ".${index}" }
            }
        }
        return (base, name, identity, location)
    }
    func visitFunction(function: Function, args: ArrayList<Value>, mutex: Option<SharedLocation>, seen: HashSet<String>): Unit {
        let saved = ArrayList<(Int64, Option<Value>)>()
        let params = function.GetParams()
        for (index in 0..(if (params.size < args.size) { params.size } else { args.size })) {
            let id = params[index].nodeId
            if (id == args[index].nodeId) { continue }
            saved.add((id, aliases.get(id))); aliases[id] = uncast(args[index])
        }
        try {
            if (let Some(body) <- function.GetBody()) { if (let Some(entry) <- body.GetEntryBlock()) { visit(entry, mutex, seen) } }
        } finally {
            for ((id, previous) in saved) {
                if (let Some(value) <- previous) { aliases[id] = value } else { aliases.remove(id) }
            }
        }
    }
    func target(value: Value): Option<SharedLocation> {
        let (base, name, path, location) = sharedBase(value)
        if (path.isEmpty() && !base.IsGlobalVarWithInitializer() && !base.IsImportedVar()) { return None }
        var qualified = name
        if (base.TestAttr(Attribute.STATIC)) {
            if (let Some(global) <- (base as GlobalVar)) {
                if (let Some(owner) <- global.GetParentCustomTypeDef()) { qualified = owner.GetSrcCodeIdentifier() + "." + name }
            }
        }
        return SharedLocation(base, qualified, path, location)
    }
    func access(variable: SharedLocation, position: DebugLocation, mutex: Option<SharedLocation>, write: Bool): Unit {
        let key = variable.key; targets[key] = variable
        if (write) { writes.add(key) }
        let pos = if (position.GetBeginPos().line == 0) { variable.location } else { position }
        let posKey = pos.GetAbsPath() + ":${pos.GetBeginPos().line}:${pos.GetBeginPos().column}"
        if (let Some(lock) <- mutex) {
            mutexes[lock.key] = lock
            if (!locked.contains(key)) { locked[key] = HashMap<String, HashMap<String, DebugLocation>>() }
            if (!locked[key].contains(lock.key)) { locked[key][lock.key] = HashMap<String, DebugLocation>() }
            locked[key][lock.key][posKey] = pos
        } else {
            if (!unlocked.contains(key)) { unlocked[key] = HashMap<String, DebugLocation>() }
            unlocked[key][posKey] = pos
        }
    }
    func visit(block: Block, incoming: Option<SharedLocation>, seen: HashSet<String>): Unit {
        let state = "${block.nodeId}:" + (if (let Some(lock) <- incoming) { lock.key } else { "unlocked" })
        if (seen.contains(state)) { return }; seen.add(state)
        var mutex = incoming
        for (expression in block.GetExpressions()) {
            if (let Some(invoke) <- (expression as Invoke)) {
                let methodType = invoke.GetMethodType(); let params = methodType.GetParamTypes()
                if (params.size == 1 && flowTypeName(params[0]) == "Lock" && flowTypeName(methodType.GetReturnType()) == "Unit") {
                    if (invoke.GetMethodName() == "lock") {
                        let (base, name, path, location) = sharedBase(invoke.GetObject())
                        mutex = SharedLocation(base, name, path, location)
                    } else if (invoke.GetMethodName() == "unlock") { mutex = None }
                }
            }
            if (let Some(store) <- (expression as Store)) {
                if (let Some(variable) <- target(store.GetLocation())) { access(variable, store.GetDebugLocation(), mutex, true) }
            }
            if (let Some(store) <- (expression as StoreElementRef)) {
                let (base, name, path, location) = sharedPath(store.GetLocation(), store.GetPath())
                access(SharedLocation(base, name, path, location), store.GetDebugLocation(), mutex, true)
            }
            if (let Some(load) <- (expression as Load)) {
                let value = load.GetLocation()
                var intermediate = false
                if (let Some(result) <- load.GetResult()) {
                    let users = result.GetUsers(); intermediate = users.size == 1 && users[0] is GetElementRef
                }
                if (!intermediate && !value.TestAttr(Attribute.READONLY) && flowTypeName(value.GetType().getOrThrow()) != "ReentrantMutex") {
                    if (let Some(variable) <- target(value)) { access(variable, load.GetDebugLocation(), mutex, false) }
                }
            }
            if (let Some(lambdaExpr) <- (expression as Lambda)) { closure(lambdaExpr) }
            if (let Some((callee, _)) <- flowCall(expression)) {
                if (let Some(function) <- (callee as Function)) {
                    if (function.IsLambda()) {
                        visitFunction(function, flowCall(expression).getOrThrow()[1], mutex, seen)
                    }
                }
            }
            if (expression.IsTerminator()) {
                for (successor in expression.GetSuccessors()) { visit(successor, mutex, seen) }
            }
        }
    }
    func closure(lambdaExpr: Lambda): Unit {
        if (checked.contains(lambdaExpr.nodeId)) { return }; checked.add(lambdaExpr.nodeId)
        if (let Some(entry) <- lambdaExpr.GetEntryBlock()) { visit(entry, None, HashSet<String>()) }
    }
    // PerformCHIRCompilation has already run ClosureConversion: a spawned
    // lambda can be an AutoEnv class cast. Follow its actual generated virtual
    // method and lifted lambda body, as created in ClosureConversion.cj.
    func closureValue(value: Value): Unit {
        if (let Some(expression) <- flowValueExpression(value)) {
            if (let Some(cast) <- (expression as TypeCast)) { closureValue(cast.GetSourceValue()); return }
            if (let Some(lambdaExpr) <- (expression as Lambda)) { closure(lambdaExpr); return }
        }
        if (let Some(ty) <- value.GetType()) {
            if (let Some(custom) <- (flowBaseType(ty) as CustomType)) {
                for (method in custom.GetCustomTypeDef().GetMethods()) {
                    let name = method.GetSrcCodeIdentifier()
                    if (name != "$GenericVirtualFunc" && name != "$InstVirtualFunc") { continue }
                    if (let Some(function) <- (method as Function)) {
                        visitFunction(function, ArrayList<Value>([value]), None, HashSet<String>())
                    }
                }
            }
        }
    }
    func collect(expression: Expression): Unit {
        if (let Some((callee, args)) <- flowCall(expression)) {
            if (FlowFunctionSpec("init", "Future", ["Future", "NOT_CARE"], "ANY_TYPE", "std.core", 0).matches(callee) && args.size >= 2) {
                closureValue(args[1])
            }
        }
    }
    func run(pkg: Package): Unit {
        for (function in pkg.GetGlobalFuncsWithBody(includeSrcCodeImported: false)) {
            if (let Some(body) <- function.GetBody()) { walkFlow(body, { expression => collect(expression) }) }
        }
        for ((key, positions) in unlocked) {
            if (!writes.contains(key) || positions.isEmpty()) { continue }
            let lines = HashSet<UInt32>(); var first: Option<DebugLocation> = None
            for ((_, pos) in positions) {
                lines.add(pos.GetBeginPos().line)
                if (let Some(current) <- first) {
                    if (pos.GetBeginPos().line < current.GetBeginPos().line ||
                        (pos.GetBeginPos().line == current.GetBeginPos().line && pos.GetBeginPos().column < current.GetBeginPos().column)) { first = pos }
                } else { first = pos }
            }
            let sorted = lines.toArray(); sort(sorted); var text = ""
            for (line in sorted) { text += "${line}," }
            flowEmit(findings, first.getOrThrow(), "P_02_no_mutex", [targets[key].name, text])
        }
        for ((key, locks) in locked) {
            if (locks.size <= 1) { continue }
            var tips = ""; var complete = true
            for ((lockKey, positions) in locks) {
                let line = mutexes[lockKey].location.GetBeginPos().line
                if (line == 0) { complete = false; break }
                for ((_, pos) in positions) { tips += "'" + targets[key].name + "' used in line ${pos.GetBeginPos().line} is protected by mutex in line ${line}, " }
            }
            if (complete) { flowEmit(findings, targets[key].location, "P_02_diff_mutex", [tips]) }
        }
    }
}
