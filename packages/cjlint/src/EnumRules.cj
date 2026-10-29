package cjlint

import cjcj::ast.*
import std.collection.*

func checkEnumDeclarationNames(engine: RuleEngine, root: File): Unit {
    // The reference retains the first constructor with each name and compares
    // only the file's top-level declarations/package, not arbitrary references.
    let constructors = HashMap<String, Decl>()
    Walker(root, visitPre: { node: Node =>
        if (let Some(declaration) <- (node as EnumDecl)) {
            for (constructor in declaration.constructors) {
                let name = constructor.identifier.Val()
                if (!constructors.contains(name)) { constructors[name] = constructor }
            }
            return VisitAction.SKIP_CHILDREN
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
    for (declaration in root.decls) {
        if (hasModifier(declaration, TokenKind.COMMON) || hasModifier(declaration, TokenKind.SPECIFIC)) { continue }
        if ((declaration as ClassDecl).isSome() || (declaration as InterfaceDecl).isSome() ||
            (declaration as FuncDecl).isSome() || (declaration as VarDecl).isSome() ||
            (declaration as EnumDecl).isSome() || (declaration as StructDecl).isSome() ||
            (declaration as MacroDecl).isSome() || (declaration as TypeAliasDecl).isSome()) {
            if (let Some(constructor) <- constructors.get(declaration.identifier.Val())) {
                engine.emitIdentifier(declaration, "G_ENU_01_0_duplicate_name_information")
                engine.emitIdentifier(constructor, "G_ENU_01_1_duplicate_name_information")
            }
        }
    }
    if (let Some(specification) <- root.packageSpec) {
        if (let Some(constructor) <- constructors.get(specification.packageName.Val())) {
            engine.findings.add(Finding(engine.path, specification.packageName.Begin(), specification.packageName.End(),
                "G_ENU_01_0_duplicate_name_information", [specification.packageName.Val()]))
            engine.emitIdentifier(constructor, "G_ENU_01_1_duplicate_name_information")
        }
    }
}

// Compare actual frontend type identity and declared inheritance. The optional
// extension map is used by G.ENU.02; G.FUN.03 checks declared inheritance only.
func inheritsResolvedType(base: Ty, derived: Ty, extensions: HashMap<Ty, ArrayList<Type>>,
    visited: HashSet<Ty>): Bool {
    if (!derived.IsClassLike()) { return false }
    if (base == derived) { return true }
    if (visited.contains(derived)) { return false }
    visited.add(derived)
    if (let Some(declaration) <- Ty.GetDeclOfTy(derived)) {
        if (let Some(classLike) <- (declaration as ClassLikeDecl)) {
            for (parent in classLike.inheritedTypes) {
                if (let Some(parentType) <- parent.GetTy()) {
                    if (parentType == base || inheritsResolvedType(base, parentType, extensions, visited)) { return true }
                }
            }
        }
    }
    if (let Some(parents) <- extensions.get(derived)) {
        for (parent in parents) {
            if (let Some(parentType) <- parent.GetTy()) {
                if (parentType == base || inheritsResolvedType(base, parentType, extensions, visited)) { return true }
            }
        }
    }
    return false
}

class EnumCallable {
    let declaration: FuncDecl
    let arguments: ArrayList<Ty>
    init(declaration: FuncDecl, arguments: ArrayList<Ty>) {
        this.declaration = declaration; this.arguments = arguments
    }
}

func enumArgumentOverlap(left: Ty, right: Ty, extensions: HashMap<Ty, ArrayList<Type>>): Bool {
    if (!left.IsClassLike()) {
        return left.kind == right.kind || left.kind == TypeKind.TYPE_GENERICS || right.kind == TypeKind.TYPE_GENERICS
    }
    return inheritsResolvedType(left, right, extensions, HashSet<Ty>()) ||
        inheritsResolvedType(right, left, extensions, HashSet<Ty>())
}

func checkEnumCallable(engine: RuleEngine, declaration: FuncDecl, seen: ArrayList<EnumCallable>,
    extensions: HashMap<Ty, ArrayList<Type>>): Unit {
    if (let Some(body) <- declaration.funcBody) {
        if (body.paramLists.isEmpty()) { return }
        let arguments = ArrayList<Ty>()
        for (parameter in body.paramLists[0].params) {
            if (let Some(ty) <- parameter.GetTy()) { arguments.add(ty) } else { return }
        }
        for (previous in seen) {
            if (previous.declaration.identifier.Val() != declaration.identifier.Val() ||
                previous.arguments.size != arguments.size) { continue }
            var overlap = true
            for (index in 0..arguments.size) {
                if (!enumArgumentOverlap(previous.arguments[index], arguments[index], extensions)) { overlap = false; break }
            }
            if (overlap && (declaration.TestAttr(Attribute.ENUM_CONSTRUCTOR) ||
                previous.declaration.TestAttr(Attribute.ENUM_CONSTRUCTOR))) {
                engine.emitIdentifier(declaration, "G_ENU_02_enum_constructor_overload_information")
                return
            }
        }
        seen.add(EnumCallable(declaration, arguments))
    }
}

func checkEnumOverloads(engine: RuleEngine, root: File): Unit {
    let extensions = HashMap<Ty, ArrayList<Type>>()
    Walker(root, visitPre: { node: Node =>
        if (let Some(extension) <- (node as ExtendDecl)) {
            if (let Some(extended) <- extension.extendedType) {
                if (let Some(ty) <- extended.GetTy()) {
                    if (ty.IsClassLike()) {
                        let parents = extensions.get(ty) ?? ArrayList<Type>()
                        parents.add(all: extension.inheritedTypes)
                        extensions[ty] = parents
                    }
                }
            }
            return VisitAction.SKIP_CHILDREN
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
    let seen = ArrayList<EnumCallable>()
    Walker(root, visitPre: { node: Node =>
        if (let Some(enumeration) <- (node as EnumDecl)) {
            for (constructor in enumeration.constructors) {
                if (let Some(function) <- (constructor as FuncDecl)) { checkEnumCallable(engine, function, seen, extensions) }
            }
            return VisitAction.SKIP_CHILDREN
        }
        if (let Some(function) <- (node as FuncDecl)) {
            if (function.scopeLevel == 0 && function.outerDecl.isNone()) { checkEnumCallable(engine, function, seen, extensions) }
            return VisitAction.SKIP_CHILDREN
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
