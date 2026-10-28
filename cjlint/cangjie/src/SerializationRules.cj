package cjlint

import cjcj::ast.*
import std.collection.*

func serializationExtensions(root: Node): HashSet<String> {
    let names = HashSet<String>()
    Walker(root, visitPre: { node: Node =>
        if (let Some(extension) <- (node as ExtendDecl)) {
            for (parent in extension.inheritedTypes) {
                if (parent.ToString().contains("Serializable<")) {
                    if (let Some(extended) <- extension.extendedType) { names.add(extended.ToString()) }
                    return VisitAction.SKIP_CHILDREN
                }
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
    return names
}

func implementsSerializable(declaration: InheritableDecl, extensions: HashSet<String>, visited: HashSet<Decl>): Bool {
    if (extensions.contains(declaration.identifier.Val())) { return true }
    if (visited.contains(declaration)) { return false }
    visited.add(declaration)
    for (parent in declaration.inheritedTypes) {
        if (parent.ToString().contains("Serializable<")) { return true }
        if (let Some(ty) <- parent.GetTy()) {
            if (!ty.IsClassLike()) { continue }
            if (let Some(target) <- Ty.GetDeclOfTy(ty)) {
                if (let Some(inherited) <- (target as InheritableDecl)) {
                    if (implementsSerializable(inherited, extensions, visited)) { return true }
                }
            }
        }
    }
    return false
}

func serializedLiteral(value: Option<Expr>, visited: HashSet<Decl>): String {
    if (let Some(expression) <- value) {
        if (let Some(literal) <- (expression as LitConstExpr)) { return literal.stringValue }
        if (let Some(reference) <- (expression as RefExpr)) {
            if (let Some(target) <- reference.ref.target) {
                if (visited.contains(target)) { return "" }
                visited.add(target)
                if (let Some(variable) <- (target as VarDecl)) { return serializedLiteral(variable.initializer, visited) }
            }
        }
    }
    return ""
}

func emitSensitiveSerialization(engine: RuleEngine, node: Node, text: String, keywords: Array<String>, field: Bool): Unit {
    for (keyword in keywords) {
        if (text.contains(keyword)) {
            engine.emit(node, if (field) { "G_SER_01_serialize_sensitive_field" } else { "G_SER_01_serialize_sensitive_data" }, [text])
        }
    }
}

func serializationCall(engine: RuleEngine, call: CallExpr, keywords: Array<String>, fields: Bool): VisitAction {
    if (let Some(base) <- call.baseFunc) {
        if (let Some(member) <- (base as MemberAccess)) {
            if (member.field == "serialize") {
                if (let Some(receiver) <- member.baseExpr) {
                    emitSensitiveSerialization(engine, receiver, serializedLiteral(receiver, HashSet<Decl>()), keywords, false)
                }
                return VisitAction.SKIP_CHILDREN
            }
            if (!fields) { return VisitAction.WALK_CHILDREN }
            if (member.field != "add") { return VisitAction.SKIP_CHILDREN }
            if (let Some(receiver) <- member.baseExpr) {
                if (let Some(ty) <- receiver.GetTy()) {
                    if (ty.name == "DataModelStruct" && !call.args.isEmpty()) {
                        if (let Some(argument) <- call.args[0].expr) {
                            if (let Some(fieldCall) <- (argument as CallExpr)) {
                                if (let Some(fieldBase) <- fieldCall.baseFunc) {
                                    if (let Some(reference) <- (fieldBase as RefExpr)) {
                                        if (reference.ref.identifier != "field" || fieldCall.args.isEmpty()) { return VisitAction.SKIP_CHILDREN }
                                        if (let Some(key) <- fieldCall.args[0].expr) {
                                            emitSensitiveSerialization(engine, key, serializedLiteral(key, HashSet<Decl>()), keywords, true)
                                        }
                                        if (fieldCall.args.size > 1) {
                                            let value = fieldCall.args[1]
                                            emitSensitiveSerialization(engine, value, value.ToString(), keywords, true)
                                        }
                                        return VisitAction.WALK_CHILDREN
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return if (fields) { VisitAction.SKIP_CHILDREN } else { VisitAction.WALK_CHILDREN }
}

func serializationMethods(engine: RuleEngine, declaration: Node, keywords: Array<String>): Unit {
    Walker(declaration, visitPre: { node: Node =>
        if (let Some(function) <- (node as FuncDecl)) {
            if (function.identifier == "serialize") {
                if (let Some(body) <- function.funcBody) {
                    Walker(body, visitPre: { nested: Node =>
                        if (let Some(call) <- (nested as CallExpr)) { return serializationCall(engine, call, keywords, true) }
                        return VisitAction.WALK_CHILDREN
                    }).Walk()
                }
            }
            return VisitAction.SKIP_CHILDREN
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

func checkSensitiveSerialization(engine: RuleEngine, root: Node, extensions: HashSet<String>): Unit {
    let keywords = settingStrings(ruleSettings(engine, "G_SER_01"), "SensitiveKeyword")
    Walker(root, visitPre: { node: Node =>
        if ((node as ClassDecl).isSome() || (node as StructDecl).isSome()) {
            let declaration = (node as InheritableDecl).getOrThrow()
            if (implementsSerializable(declaration, extensions, HashSet<Decl>())) {
                serializationMethods(engine, declaration, keywords)
                return VisitAction.SKIP_CHILDREN
            }
        }
        if (let Some(extension) <- (node as ExtendDecl)) {
            if (let Some(extended) <- extension.extendedType) {
                if (extensions.contains(extended.ToString())) {
                    serializationMethods(engine, extension, keywords)
                    return VisitAction.SKIP_CHILDREN
                }
            }
        }
        if (let Some(call) <- (node as CallExpr)) { return serializationCall(engine, call, keywords, false) }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

func isDeserializeCall(expression: Option<Expr>): Bool {
    if (let Some(value) <- expression) {
        if (let Some(call) <- (value as CallExpr)) {
            if (let Some(base) <- call.baseFunc) {
                if (let Some(member) <- (base as MemberAccess)) { return member.ToString().contains("deserialize") }
            }
        }
    }
    return false
}

func checkDeserialization(engine: RuleEngine, declaration: InheritableDecl): Unit {
    let fields = HashSet<String>()
    let assigned = HashSet<String>()
    for (member in declaration.GetMemberDecls()) {
        if ((member as VarDecl).isSome()) { fields.add(member.identifier.Val()) }
    }
    Walker(declaration, visitPre: { node: Node =>
        if (let Some(function) <- (node as FuncDecl)) {
            if (function.identifier == declaration.identifier || function.identifier == "init" || function.identifier == "super") {
                if (let Some(body) <- function.funcBody) {
                    Walker(body, visitPre: { nested: Node =>
                        if (let Some(assignment) <- (nested as AssignExpr)) {
                            var left = assignment.leftValue
                            if (let Some(value) <- left) {
                                if (let Some(member) <- (value as MemberAccess)) { left = member.baseExpr }
                            }
                            if (let Some(value) <- left) {
                                if (let Some(reference) <- (value as RefExpr)) {
                                    let name = reference.ref.identifier.Val()
                                    if (fields.contains(name)) {
                                        if (isDeserializeCall(assignment.rightExpr)) {
                                            if (let Some(target) <- assignment.leftValue) {
                                                engine.emit(target, "G_SER_02_Deserialization_Bypass", [name])
                                            }
                                        } else { assigned.add(name) }
                                    }
                                }
                            }
                            return VisitAction.SKIP_CHILDREN
                        }
                        return VisitAction.WALK_CHILDREN
                    }).Walk()
                }
            }
            return VisitAction.SKIP_CHILDREN
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
    Walker(declaration, visitPre: { node: Node =>
        if (let Some(function) <- (node as FuncDecl)) {
            if (function.identifier == "deserialize") {
                if (let Some(body) <- function.funcBody) {
                    Walker(body, visitPre: { nested: Node =>
                        if (let Some(assignment) <- (nested as AssignExpr)) {
                            if (isDeserializeCall(assignment.rightExpr)) {
                                if (let Some(value) <- assignment.leftValue) {
                                    if (let Some(reference) <- (value as RefExpr)) {
                                        if (assigned.contains(reference.ToString())) {
                                            engine.emit(reference, "G_SER_02_Deserialization_Bypass", [reference.ToString()])
                                        }
                                    }
                                }
                            }
                            return VisitAction.SKIP_CHILDREN
                        }
                        return VisitAction.WALK_CHILDREN
                    }).Walk()
                }
            }
            return VisitAction.SKIP_CHILDREN
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

func runSerializationRules(engine: RuleEngine, root: Node): Unit {
    if (!engine.selected.contains("G.SER.01") && !engine.selected.contains("G.SER.02")) { return }
    let extensions = serializationExtensions(root)
    if (engine.selected.contains("G.SER.01")) { checkSensitiveSerialization(engine, root, extensions) }
    if (engine.selected.contains("G.SER.02")) {
        Walker(root, visitPre: { node: Node =>
            if ((node as ClassDecl).isSome() || (node as StructDecl).isSome()) {
                let declaration = (node as InheritableDecl).getOrThrow()
                if (implementsSerializable(declaration, extensions, HashSet<Decl>())) {
                    checkDeserialization(engine, declaration)
                    return VisitAction.SKIP_CHILDREN
                }
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
    }
}
