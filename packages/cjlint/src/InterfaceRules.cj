package cjlint

import cjcj::ast.*
import cjcj::sema.TypeManager
import cjcj::basic.Position
import std.collection.*

func standardDerivedMacro(engine: RuleEngine, point: Position): Bool {
    let line = engine.sources.GetContentBetween(point.fileID, Position(point.fileID, point.line, 1),
        Position(point.fileID, point.line + 1, 1)).trimAsciiStart()
    for (name in ["@Derive", "@DeriveExclude", "@DeriveInclude", "@DeriveOrder"]) {
        if (line.startsWith(name)) { return true }
    }
    return false
}

func checkExtensionInterfaces(engine: RuleEngine, extension: ExtendDecl): Unit {
    for (member in extension.members) {
        var emitted = false
        for (parentType in extension.GetSuperInterfaceTys()) {
            if (let Some(parent) <- parentType.decl) {
                if (parent.TestAttr(Attribute.IMPORTED)) { continue }
                for (required in parent.GetMemberDecls()) {
                    if (required.identifier == member.identifier && required.GetTy() == member.GetTy() &&
                        !standardDerivedMacro(engine, member.begin)) {
                        engine.emit(member, "G_ITF_02_prefer_implement_interfaces_at_type_definition", [member.identifier.Val()])
                        emitted = true; break
                    }
                }
            }
            if (emitted) { break }
        }
    }
}

func checkInterfaceParent(engine: RuleEngine, childName: String, child: InterfaceTy,
    declaration: InheritableDecl, visited: HashSet<Ty>): Unit {
    for (declared in declaration.GetSuperInterfaceTys()) {
        if (declared.name == childName) { continue }
        for (ancestor in child.GetSuperInterfaceTys()) {
            if (ancestor.name == declared.name) {
                engine.emit(declaration, "G_ITF_03_avoid_declaring_both_parent_interface_and_sub_interface",
                    [childName, declared.name])
            } else if (!visited.contains(ancestor)) {
                visited.add(ancestor)
                checkInterfaceParent(engine, childName, ancestor, declaration, visited)
            }
        }
    }
}

func checkRedundantInterfaces(engine: RuleEngine, root: Node): Unit {
    Walker(root, visitPre: { node: Node =>
        if (let Some(declaration) <- (node as InheritableDecl)) {
            for (parent in declaration.GetSuperInterfaceTys()) {
                checkInterfaceParent(engine, parent.name, parent, declaration, HashSet<Ty>())
            }
            return VisitAction.SKIP_CHILDREN
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

func checkInterfaceFieldAssignment(engine: RuleEngine, assignment: AssignExpr, fields: HashSet<Decl>,
    requirement: FuncDecl): Unit {
    var expression = assignment.leftValue
    while (let Some(current) <- expression) {
        let target = current.GetTarget()
        if ((current as RefExpr).isSome()) {
            if (let Some(declaration) <- target) {
                if (fields.contains(declaration)) {
                    engine.emit(requirement, "G_ITF_01_should_use_mut_modifier", [requirement.identifier.Val()])
                }
            }
            break
        }
        if (let Some(member) <- (current as MemberAccess)) {
            if (let Some(base) <- member.baseExpr) {
                if (let Some(ty) <- base.GetTy()) { if (ty.IsClassLike()) { break } }
                if (let Some(reference) <- (base as RefExpr)) {
                    if (let Some(declaration) <- target) {
                        if (reference.isThis && fields.contains(declaration)) {
                            engine.emit(requirement, "G_ITF_01_should_use_mut_modifier", [requirement.identifier.Val()])
                            break
                        }
                    }
                }
            }
            expression = member.baseExpr
        } else { break }
    }
}

func checkInterfaceImplementation(engine: RuleEngine, declaration: Decl, fields: HashSet<Decl>,
    requirements: ArrayList<FuncDecl>, manager: TypeManager): Unit {
    if (let Some(function) <- (declaration as FuncDecl)) {
        for (requirement in requirements) {
            if (!manager.PairIsOverrideOrImpl(function, requirement)) { continue }
            if (let Some(body) <- function.funcBody) {
                if (let Some(block) <- body.body) {
                    for (statement in block.body) {
                        if (let Some(assignment) <- (statement as AssignExpr)) {
                            checkInterfaceFieldAssignment(engine, assignment, fields, requirement)
                        }
                        if (let Some(increment) <- (statement as IncOrDecExpr)) {
                            if (let Some(desugared) <- increment.desugarExpr) {
                                if (let Some(assignment) <- (desugared as AssignExpr)) {
                                    checkInterfaceFieldAssignment(engine, assignment, fields, requirement)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

func checkMutableInterface(engine: RuleEngine, contract: InterfaceDecl, manager: TypeManager): Unit {
    let requirements = ArrayList<FuncDecl>()
    for (member in contract.GetMemberDecls()) {
        if (let Some(function) <- (member as FuncDecl)) {
            if (!function.TestAttr(Attribute.MUT)) { requirements.add(function) }
        }
    }
    for (implementation in contract.subDecls) {
        if (let Some(structure) <- (implementation as StructDecl)) {
            let fields = HashSet<Decl>()
            for (member in structure.GetMemberDecls()) {
                if ((member as VarDecl).isSome() && !member.TestAttr(Attribute.STATIC) && Ty.IsTyCorrect(member.GetTy())) {
                    if (let Some(ty) <- member.GetTy()) { if (!ty.IsArray()) { fields.add(member) } }
                }
            }
            for (member in structure.GetMemberDecls()) { checkInterfaceImplementation(engine, member, fields, requirements, manager) }
            for (extension in manager.GetDeclExtends(structure)) {
                for (member in extension.members) { checkInterfaceImplementation(engine, member, fields, requirements, manager) }
            }
        }
    }
}

func runInterfaceRules(engine: RuleEngine, root: Node, manager: TypeManager): Unit {
    if (engine.selected.contains("G.ITF.03")) { checkRedundantInterfaces(engine, root) }
    Walker(root, visitPre: { node: Node =>
        if (engine.selected.contains("G.ITF.02")) {
            if (let Some(extension) <- (node as ExtendDecl)) { checkExtensionInterfaces(engine, extension) }
        }
        if (engine.selected.contains("G.ITF.01")) {
            if (let Some(contract) <- (node as InterfaceDecl)) { checkMutableInterface(engine, contract, manager) }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
