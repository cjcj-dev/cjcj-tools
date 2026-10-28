package cjlint

import cjcj::chir.*
import cjcj::ast.{Node, Walker, VisitAction, ASTKind, PropDecl}
import cjcj::ast.Attribute as AstAttribute
import cjcj::basic.Position as FlowPosition
import cjcj::chir.Position as ChirPosition
import std.collection.*
import std.fs.File as InputFile

class FlowSourceInfo {
    let unsafeRanges = ArrayList<(FlowPosition, FlowPosition)>()
    let properties = ArrayList<(String, PropDecl)>()
    func collect(root: Node, path: String): Unit {
        Walker(root, visitPre: { node: Node =>
            if (let Some(property) <- (node as PropDecl)) { properties.add((path, property)) }
            if (node.astKind == ASTKind.BLOCK && node.TestAttr(AstAttribute.UNSAFE)) {
                unsafeRanges.add((node.begin, node.end)); return VisitAction.SKIP_CHILDREN
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
    }
    func propertyLocation(setter: Function): DebugLocation {
        // This frontend leaves CHIR propLocation unset. Bind the actual mangled
        // setter to its retained typed AST property; no synthetic AST or range.
        for ((path, property) in properties) {
            for (accessor in property.setters) {
                if (accessor.mangledName == setter.GetIdentifierWithoutPrefix()) {
                    return DebugLocation(path, UInt32(property.begin.fileID),
                        ChirPosition(UInt32(property.begin.line), UInt32(property.begin.column)),
                        ChirPosition(UInt32(property.end.line), UInt32(property.end.column)))
                }
            }
        }
        let location = setter.GetPropLocation()
        return if (location.IsValid()) { location } else { setter.GetDebugLocation() }
    }
    func inUnsafe(location: DebugLocation): Bool {
        let pos = location.GetBeginPos()
        for ((begin, end) in unsafeRanges) {
            if (begin.fileID != UInt64(location.GetFileID())) { continue }
            if ((Int64(pos.line) > begin.line || (Int64(pos.line) == begin.line && Int64(pos.column) > begin.column)) &&
                (Int64(pos.line) < end.line || (Int64(pos.line) == end.line && Int64(pos.column) < end.column))) { return true }
        }
        return false
    }
    func derivedMacro(location: DebugLocation): Bool {
        let line = Int64(location.GetBeginPos().line)
        if (line <= 0 || location.GetFileID() == 0) { return false }
        let lines = String.fromUtf8(InputFile.readFrom(location.GetAbsPath())).split("\n")
        if (line > lines.size) { return false }
        let text = lines[line - 1].trimAscii()
        for (name in ["@Derive", "@DeriveExclude", "@DeriveInclude", "@DeriveOrder"]) {
            if (text.startsWith(name)) { return true }
        }
        return false
    }
}

func flowRootVariable(value: Value): Value {
    if (let Some(local) <- (value as LocalVar)) {
        if (let Some(expression) <- local.GetExpr()) {
            if (let Some(load) <- (expression as Load)) { return flowRootVariable(load.GetLocation()) }
            if (let Some(element) <- (expression as GetElementRef)) { return flowRootVariable(element.GetLocation()) }
        }
    }
    return value
}

func flowNestedStore(value: Value, visited: HashSet<Int64>): Bool {
    if (visited.contains(value.nodeId)) { return false }; visited.add(value.nodeId)
    for (user in value.GetUsers()) {
        if (user is Store) { return true }
        if (user is Load || user is GetElementRef) {
            if (let Some(result) <- user.GetResult()) { if (flowNestedStore(result, visited)) { return true } }
        }
    }
    return false
}

class ImmutableCheck {
    let findings: ArrayList<Finding>
    let source: FlowSourceInfo
    let changed = HashSet<Int64>()
    let definitions = HashMap<Int64, CustomTypeDef>()
    let members = HashMap<Int64, HashMap<Int64, Int64>>()
    let genericSetterUsed = HashSet<Int64>()
    let properties = ArrayList<(CustomTypeDef, Function)>()
    init(findings: ArrayList<Finding>, source: FlowSourceInfo) { this.findings = findings; this.source = source }
    func countStores(value: Value): Int64 {
        var count: Int64 = 0
        for (user in value.GetUsers()) {
            if (user is Store) { count++ }
            else if (user is GetElementRef) {
                if (let Some(result) <- user.GetResult()) { if (flowNestedStore(result, HashSet<Int64>())) { count++ } }
            }
        }
        return count
    }
    func collect(definition: CustomTypeDef): Unit {
        if (definition.TestAttr(Attribute.PUBLIC)) { return }
        let instantiated = definition.TestAttr(Attribute.GENERIC_INSTANTIATED)
        for (method in definition.GetMethods()) {
            if (let Some(setter) <- (method as Function)) {
                if (setter.GetFuncKind() != FuncKind.SETTER) { continue }
                let users = setter.GetUsers()
                if (users.isEmpty()) {
                    if (!instantiated) { properties.add((definition, setter)) }
                } else {
                    if (instantiated) {
                        if (let Some(generic) <- definition.GetGenericDecl()) { genericSetterUsed.add(generic.nodeId) }
                    }
                    for (user in users) {
                        if (user.GetNumOfOperands() > 1) { changed.add(user.GetOperand(1).nodeId) }
                    }
                }
            }
        }
        if (instantiated) { return }
        let counts = HashMap<Int64, Int64>()
        let all = definition.GetAllInstanceVars()
        for (index in 0..all.size) {
            // ClosureConversion capture slots are generated members without
            // source declarations; only source members can receive this advice.
            if (!all[index].loc.IsValid() || all[index].loc.GetAbsPath().isEmpty() || all[index].TestAttr(Attribute.READONLY)) { continue }
            if (let Some(classDef) <- (definition as ClassDef)) {
                var direct = false
                for (member in classDef.GetDirectInstanceVars()) { if (member.name == all[index].name) { direct = true } }
                if (!direct) { continue }
            }
            counts[index] = 0
        }
        definitions[definition.nodeId] = definition; members[definition.nodeId] = counts
    }
    func storeMember(base: Value, path: ArrayList<UInt64>): Unit {
        if (path.isEmpty()) { return }
        if (let Some(ty) <- base.GetType()) {
            if (let Some(custom) <- (flowBaseType(ty) as CustomType)) {
                var definition = custom.GetCustomTypeDef()
                for (index in 0..path.size - 1) {
                    let member = definition.GetInstanceVar(Int64(path[index]))
                    if (let Some(nested) <- (flowBaseType(member.ty) as CustomType)) { definition = nested.GetCustomTypeDef() }
                    else { return }
                }
                if (definition.TestAttr(Attribute.GENERIC_INSTANTIATED)) { definition = definition.GetGenericDecl() ?? definition }
                if (let Some(counts) <- members.get(definition.nodeId)) {
                    let index = Int64(path[path.size - 1])
                    if (counts.contains(index)) { counts[index] = counts[index] + 1 }
                }
            }
        }
    }
    func body(root: BlockGroup): Unit {
        let locals = HashMap<Int64, (LocalVar, Debug, Int64)>()
        // Collect first, so a derived write cannot precede its Debug node in
        // the block visitation order and escape the assignment count.
        walkFlow(root, { expression =>
            if (let Some(debug) <- (expression as Debug)) {
                if (let Some(result) <- debug.GetResult()) {
                    if (let Some(local) <- (debug.GetValue() as LocalVar)) {
                        if (debug.GetDebugLocation().IsValid() && !debug.GetDebugLocation().GetAbsPath().isEmpty() && !result.TestAttr(Attribute.READONLY) && !local.TestAttr(Attribute.READONLY) &&
                            !source.inUnsafe(debug.GetDebugLocation()) && !changed.contains(local.nodeId)) {
                            locals[local.nodeId] = (local, debug, countStores(local))
                        }
                    }
                }
            }
        })
        let increase = { location: Value =>
            let base = flowRootVariable(location)
            if (let Some(entry) <- locals.get(base.nodeId)) { locals[base.nodeId] = (entry[0], entry[1], entry[2] + 1) }
        }
        walkFlow(root, { expression =>
            if (let Some(store) <- (expression as Store)) {
                if (let Some(local) <- (store.GetLocation() as LocalVar)) {
                    if (let Some(address) <- local.GetExpr()) {
                        if (let Some(element) <- (address as GetElementRef)) { storeMember(element.GetLocation(), element.GetPath()) }
                        if (address is Load || address is GetElementRef) { increase(store.GetLocation()) }
                    }
                }
            }
            if (let Some(store) <- (expression as StoreElementRef)) {
                storeMember(store.GetLocation(), store.GetPath()); increase(store.GetLocation())
            }
        })
        for ((_, entry) in locals) {
            if (entry[2] <= 1 && !source.derivedMacro(entry[1].GetDebugLocation())) {
                flowEmit(findings, entry[1].GetDebugLocation(), "G_VAR_01_prefer_immutable_var", [entry[1].GetSrcCodeIdentifier()])
            }
        }
    }
    func run(pkg: Package): Unit {
        for (definition in pkg.GetClasses()) { collect(definition) }
        for (definition in pkg.GetStructs()) { collect(definition) }
        for (definition in pkg.GetEnums()) { collect(definition) }
        for (definition in pkg.GetExtends()) { collect(definition) }
        for ((definition, setter) in properties) {
            if (genericSetterUsed.contains(definition.nodeId)) { continue }
            var name = setter.GetSrcCodeIdentifier()
            if (name.startsWith("$")) { name = name[1..]; if (name.endsWith("set")) { name = name[..name.size - 3] } }
            flowEmit(findings, source.propertyLocation(setter), "G_VAR_01_prefer_immutable_prop", [name])
        }
        let genericChanged = HashSet<String>()
        for (variable in pkg.GetGlobalVarsWithInit(includeSrcCodeImported: false)) {
            if (let Some(parent) <- variable.GetParentCustomTypeDef()) {
                if (parent.TestAttr(Attribute.GENERIC_INSTANTIATED) && countStores(variable) > 1) {
                    if (let Some(generic) <- parent.GetGenericDecl()) { genericChanged.add("${generic.nodeId}:" + variable.GetSrcCodeIdentifier()) }
                }
            }
        }
        for (variable in pkg.GetGlobalVarsWithInit(includeSrcCodeImported: false)) {
            // Compiler-generated package initialization guards have no source declaration.
            if (!variable.GetDebugLocation().IsValid() || variable.GetDebugLocation().GetAbsPath().isEmpty()) { continue }
            if (variable.TestAttr(Attribute.READONLY) || variable.TestAttr(Attribute.PUBLIC) || changed.contains(variable.nodeId)) { continue }
            if (let Some(parent) <- variable.GetParentCustomTypeDef()) {
                if (parent.TestAttr(Attribute.PUBLIC) || parent.TestAttr(Attribute.GENERIC_INSTANTIATED) ||
                    genericChanged.contains("${parent.nodeId}:" + variable.GetSrcCodeIdentifier())) { continue }
            }
            if (countStores(variable) == 1) {
                flowEmit(findings, variable.GetDebugLocation(), "G_VAR_01_prefer_immutable_var", [variable.GetSrcCodeIdentifier()])
            }
        }
        for (function in pkg.GetGlobalFuncsWithBody(includeSrcCodeImported: false)) {
            if (!flowGeneric(function)) { if (let Some(root) <- function.GetBody()) { body(root) } }
        }
        for ((id, counts) in members) {
            for ((index, count) in counts) {
                let member = definitions[id].GetInstanceVar(index)
                if (count <= 1 && !source.derivedMacro(member.loc)) {
                    flowEmit(findings, member.loc, "G_VAR_01_prefer_immutable_member", [member.name])
                }
            }
        }
    }
}
