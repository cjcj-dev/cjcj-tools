package cjlint

import cjcj::ast.*
import std.collection.*

func shadowFunctionKey(function: FuncDecl): Option<String> {
    if (let Some(ty) <- function.GetTy()) {
        if (let Some(signature) <- (ty as FuncTy)) {
            if (let Some(body) <- function.funcBody) {
                var key = function.identifier.GetRawText() + "/"
                if (let Some(generic) <- body.generic) { key += generic.typeParameters.size.toString() + "/" }
                for (parameter in signature.paramTys) { key += parameter.String() + "/" }
                return key
            }
        }
    }
    // Error recovery can leave a function without FuncTy. Keep its name in
    // the scope, and use the same key when leaving that scope.
    return Some(function.identifier.GetRawText())
}

func shadowMembers(node: Node): ArrayList<Node> {
    let result = ArrayList<Node>()
    if (let Some(body) <- (node as FuncBody)) {
        if (let Some(block) <- body.body) { for (statement in block.body) { result.add(statement) } }
    } else if (let Some(block) <- (node as Block)) {
        for (statement in block.body) { result.add(statement) }
    } else if (let Some(enumeration) <- (node as EnumDecl)) {
        for (member in enumeration.members) { result.add(member) }
    } else if (let Some(extension) <- (node as ExtendDecl)) {
        for (member in extension.members) { result.add(member) }
    } else if (let Some(file) <- (node as File)) {
        for (child in file.decls) { result.add(child) }
    } else if (let Some(body) <- (node as ClassBody)) {
        for (child in body.decls) { result.add(child) }
    } else if (let Some(body) <- (node as InterfaceBody)) {
        for (child in body.decls) { result.add(child) }
    } else if (let Some(body) <- (node as StructBody)) {
        for (child in body.decls) { result.add(child) }
    }
    return result
}

class ShadowCheck {
    let variables = HashMap<String, ArrayList<Decl>>()
    let functions = HashMap<String, ArrayList<Decl>>()
    let deferred = HashMap<Node, HashMap<String, ArrayList<Decl>>>()
    let engine: RuleEngine
    let reported = HashSet<Decl>()
    let functionBlocks = HashSet<Node>()
    let savedStatic = HashMap<Node, Bool>()
    var staticContext = false
    init(engine: RuleEngine) { this.engine = engine }
    func members(node: Node): ArrayList<Node> {
        if (functionBlocks.contains(node)) { return ArrayList<Node>() }
        return shadowMembers(node)
    }
    func report(current: Decl, previous: Decl): Unit {
        if (current == previous || reported.contains(current)) { return }
        reported.add(current)
        let name = current.identifier.GetRawText()
        engine.findings.add(Finding(engine.path, current.identifier.Begin(), current.identifier.End(),
            "G_DCL_01_avoid_shadow", [name, previous.identifier.Begin().line.toString(), name, current.identifier.Begin().line.toString()]))
    }
    func enter(node: Node): Unit {
        if (node.astKind == ASTKind.FILE) {
            variables.clear(); functions.clear(); deferred.clear(); reported.clear()
            functionBlocks.clear(); savedStatic.clear(); staticContext = false
        }
        if (let Some(body) <- (node as FuncBody)) {
            savedStatic[node] = staticContext
            if (let Some(function) <- body.funcDecl) { staticContext = function.TestAttr(Attribute.STATIC) }
            if (let Some(block) <- body.body) { functionBlocks.add(block) }
        }
        let isStatic = staticContext
        for (member in members(node)) {
            if (let Some(variable) <- (member as VarDecl)) {
                if (variable.astKind != ASTKind.VAR_DECL) { continue }
                let name = variable.identifier.GetRawText()
                for ((_, candidates) in functions) {
                    if (!candidates.isEmpty()) {
                        let previous = candidates[candidates.size - 1]
                        if (previous.identifier.GetRawText() == name &&
                            (!isStatic || previous.TestAttr(Attribute.STATIC) || previous.TestAttr(Attribute.GLOBAL))) {
                            report(variable, previous)
                        }
                    }
                }
                if (!variables.contains(name)) { variables[name] = ArrayList<Decl>() }
                if (!deferred.contains(node)) { deferred[node] = HashMap<String, ArrayList<Decl>>() }
                let pending = deferred[node]
                if (!pending.contains(name)) { pending[name] = ArrayList<Decl>() }
                let stack = variables[name]
                while (!stack.isEmpty()) {
                    let point = stack[stack.size - 1].identifier.Begin()
                    let current = variable.identifier.Begin()
                    if (point.line < current.line || (point.line == current.line && point.column <= current.column)) { break }
                    pending[name].add(stack.remove(at: stack.size - 1), at: 0)
                }
                if (!stack.isEmpty()) {
                    let previous = stack[stack.size - 1]
                    if (!isStatic || previous.TestAttr(Attribute.STATIC) || previous.TestAttr(Attribute.GLOBAL)) { report(variable, previous) }
                }
                stack.add(variable)
            } else if (let Some(function) <- (member as FuncDecl)) {
                if (function.astKind != ASTKind.FUNC_DECL) { continue }
                if (let Some(stack) <- variables.get(function.identifier.GetRawText())) {
                    if (!stack.isEmpty()) {
                        let previous = stack[stack.size - 1]
                        if (!function.TestAttr(Attribute.STATIC) || previous.TestAttr(Attribute.STATIC) ||
                            previous.TestAttr(Attribute.GLOBAL)) { report(function, previous) }
                    }
                }
                if (let Some(key) <- shadowFunctionKey(function)) {
                    if (!functions.contains(key)) { functions[key] = ArrayList<Decl>() }
                    let stack = functions[key]
                    if (!stack.isEmpty()) { report(function, stack[stack.size - 1]) }
                    stack.add(function)
                }
            }
        }
    }
    func leave(node: Node): Unit {
        if (node.astKind == ASTKind.FILE) { return }
        let names = HashSet<String>()
        for (member in members(node)) {
            if (let Some(variable) <- (member as VarDecl)) {
                if (variable.astKind != ASTKind.VAR_DECL) { continue }
                let name = variable.identifier.GetRawText()
                names.add(name)
                if (let Some(stack) <- variables.get(name)) {
                    if (!stack.isEmpty()) { stack.remove(at: stack.size - 1) }
                    if (stack.isEmpty()) { variables.remove(name) }
                }
            } else if (let Some(function) <- (member as FuncDecl)) {
                if (function.astKind != ASTKind.FUNC_DECL) { continue }
                if (let Some(key) <- shadowFunctionKey(function)) {
                    if (let Some(stack) <- functions.get(key)) {
                        if (!stack.isEmpty()) { stack.remove(at: stack.size - 1) }
                        if (stack.isEmpty()) { functions.remove(key) }
                    }
                }
            }
        }
        if (let Some(pending) <- deferred.get(node)) {
            for (name in names) {
                if (let Some(hidden) <- pending.get(name)) {
                    if (!variables.contains(name)) { variables[name] = ArrayList<Decl>() }
                    for (declaration in hidden) { variables[name].add(declaration) }
                }
            }
            deferred.remove(node)
        }
        if (let Some(previous) <- savedStatic.get(node)) { staticContext = previous; savedStatic.remove(node) }
    }
}

func checkGenericShadow(engine: RuleEngine, node: Node): Unit {
    var generic: Option<Generic> = None
    let members = ArrayList<Node>()
    if (let Some(function) <- (node as FuncDecl)) {
        if (function.astKind != ASTKind.FUNC_DECL) { return }
        if (let Some(body) <- function.funcBody) {
            generic = body.generic
            if (let Some(block) <- body.body) { for (statement in block.body) { members.add(statement) } }
        }
    } else if ([ASTKind.ENUM_DECL, ASTKind.EXTEND_DECL, ASTKind.STRUCT_DECL, ASTKind.INTERFACE_DECL,
        ASTKind.CLASS_DECL].contains(node.astKind)) {
        let declaration = (node as Decl).getOrThrow()
        generic = declaration.generic
        for (member in declaration.GetMemberDecls()) { members.add(member) }
    }
    if (let Some(parameters) <- generic) {
        let names = HashMap<String, Decl>()
        for (parameter in parameters.typeParameters) { names[parameter.identifier.GetRawText()] = parameter }
        let reporter = ShadowCheck(engine)
        for (member in members) {
            if (let Some(function) <- (member as FuncDecl)) {
                if (let Some(body) <- function.funcBody) {
                    if (let Some(nested) <- body.generic) {
                        for (parameter in nested.typeParameters) {
                            if (let Some(previous) <- names.get(parameter.identifier.GetRawText())) { reporter.report(parameter, previous) }
                        }
                    }
                }
            }
        }
    }
}

func checkShadows(engine: RuleEngine, root: Node): Unit {
    let check = ShadowCheck(engine)
    Walker(root, visitPre: { node: Node =>
        check.enter(node)
        checkGenericShadow(engine, node)
        return VisitAction.WALK_CHILDREN
    }, visitPost: { node: Node =>
        check.leave(node)
        return VisitAction.KEEP_DECISION
    }).Walk()
}
