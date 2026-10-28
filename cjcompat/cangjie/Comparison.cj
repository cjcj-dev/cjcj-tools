package cjcompat

import std.collection.*
import cjcj::ast.*
import cjcj::ast.AnnotationKind as AstAnnotationKind
import cjcj::mangle.BaseMangler
import cjcj::sema.TypeManager

func NormalizedType(value: Ty, args: Array<Ty>): String {
    let text = Ty.ToString(value)
    if (!text.contains("TypeAlias-") && !text.contains("Generics-")) { return text }
    if (let Some(alias) <- (value as TypeAliasTy)) {
        if (let Some(d) <- alias.declPtr) {
            if (let Some(t) <- d.typeNode) {
                if (let Some(ty) <- t.GetTy()) { return NormalizedType(ty, value.typeArgs.toArray()) }
            }
        }
        return text
    }
    if (let Some(f) <- (value as FuncTy)) {
        var result = "("; var first = true
        for (p in f.paramTys) {
            if (!first) { result += ", " }; first = false
            result += NormalizedType(p, args)
        }
        result += ") -> " + NormalizedType(f.retTy, args)
        return if (f.isC) { "CFunc<" + result + ">" } else { result }
    }
    if (value.HasGeneric() && value.typeArgs.size == args.size) {
        let manager = TypeManager()
        var instantiated: Option<Ty> = None
        if (let Some(d) <- Ty.GetDeclOfTy(Some(value))) {
            if (let Some(c) <- (d as ClassDecl)) { instantiated = Some(manager.GetClassTy(c, args)) }
            else if (let Some(c) <- (d as InterfaceDecl)) { instantiated = Some(manager.GetInterfaceTy(c, args)) }
            else if (let Some(c) <- (d as StructDecl)) { instantiated = Some(manager.GetStructTy(c, args)) }
            else if (let Some(c) <- (d as EnumDecl)) { instantiated = Some(manager.GetEnumTy(c, typeArgs: args)) }
            else { instantiated = d.GetTy() }
        }
        if (let Some(ty) <- instantiated) { if (!ty.HasGeneric()) { return NormalizedType(ty, Array<Ty>()) } }
    }
    return text
}
func TypeName(ty: Option<Ty>): String {
    if (let Some(value) <- ty) { return NormalizedType(value, Array<Ty>()) }
    throw Exception("CJO declaration has no semantic type")
}
func SameType(a: Option<Ty>, b: Option<Ty>): Bool {
    if (let Some(left) <- a) {
        if (let Some(right) <- b) {
            if (left.HasGeneric() && right.HasGeneric()) { return true }
        }
    }
    return TypeName(a) == TypeName(b)
}
func ClassLike(ty: Option<Ty>): Bool {
    if (let Some(value) <- ty) { return value.IsClass() || value.IsInterface() }
    return false
}
func Prefix(d: Decl): String {
    match (d.astKind) {
        case ASTKind.FUNC_DECL => "FUNC"
        case ASTKind.VAR_DECL => "VAR"
        case ASTKind.STRUCT_DECL => "STRUCT"
        case ASTKind.ENUM_DECL => "ENUM"
        case ASTKind.CLASS_DECL => "CLASS"
        case ASTKind.INTERFACE_DECL => "INTERFACE"
        case ASTKind.EXTEND_DECL => "EXTEND"
        case ASTKind.PROP_DECL => "PROP"
        case ASTKind.TYPE_ALIAS_DECL => "TYPE_ALIAS"
        case _ => "DECL"
    }
}
func IsVar(d: Decl): Bool { d.astKind == ASTKind.VAR_DECL }
func IsInstanceVar(d: Decl): Bool { IsVar(d) && !d.TestAttr(Attribute.STATIC) }
func Visible(d: Decl): Bool { d.TestAnyAttr(Attribute.PUBLIC, Attribute.PROTECTED) }
func Frozen(d: Decl): Bool {
    if (let Some(f) <- (d as FuncDecl)) { return f.isFrozen || f.HasAnno(AstAnnotationKind.FROZEN) }
    return d.HasAnno(AstAnnotationKind.FROZEN)
}
func Params(d: Decl): ArrayList<FuncParam> {
    if (let Some(f) <- (d as FuncDecl)) {
        if (let Some(b) <- f.funcBody) {
            if (!b.paramLists.isEmpty()) { return b.paramLists[0].params }
        }
    }
    return ArrayList<FuncParam>()
}
func ReturnType(d: Decl): Option<Ty> {
    if (let Some(ty) <- d.GetTy()) {
        if (let Some(f) <- (ty as FuncTy)) { return Some(f.retTy) }
    }
    throw Exception("CJO function has no function type: " + d.identifier.Val())
}
func Identity(d: Decl): String {
    if (let Some(ext) <- (d as ExtendDecl)) { return "extend:" + TypeName(ext.extendedType.getOrThrow().GetTy()) }
    if (!d.mangledName.isEmpty()) { return d.mangledName }
    if (!d.rawMangleName.isEmpty()) { return d.rawMangleName }
    return BaseMangler().Mangle(d)
}
func Members(d: Decl): ArrayList<Decl> {
    let result = ArrayList<Decl>(d.GetMemberDecls())
    if (let Some(e) <- (d as EnumDecl)) { result.add(all: e.constructors) }
    return result
}
func TopDecls(p: Package): ArrayList<Decl> {
    let result = ArrayList<Decl>()
    for (file in p.files) { result.add(all: file.decls); result.add(all: file.exportedInternalDecls) }
    return result
}

class Finding {
    let id: String
    let oldNode: Option<Node>
    let newNode: Option<Node>
    init(id: String, oldNode: Option<Node>, newNode: Option<Node>) {
        this.id = id; this.oldNode = oldNode; this.newNode = newNode
    }
}

class Comparison {
    let before: Library
    let after: Library
    let options: Options
    let catalog = RuleCatalog()
    let findings = ArrayList<Finding>()
    let usedFindings = HashSet<String>()
    let visibleOld = HashSet<Decl>()
    let visibleNew = HashSet<Decl>()
    init(before: Library, after: Library, options: Options) {
        this.before = before; this.after = after; this.options = options
        if (AccessName(before.root.accessible) == "public" || AccessName(before.root.accessible) == "internal") {
            CollectVisible(TopDecls(before.root), visibleOld)
        }
        if (AccessName(after.root.accessible) == "public" || AccessName(after.root.accessible) == "internal") {
            CollectVisible(TopDecls(after.root), visibleNew)
        }
    }
    public func CollectVisible(decls: ArrayList<Decl>, visible: HashSet<Decl>): Unit {
        for (d in decls) {
            if (d.TestAttr(Attribute.PUBLIC) || ExportedExtend(d)) { InsertVisible(d, visible) }
        }
    }
    public func InsertVisible(d: Decl, visible: HashSet<Decl>): Unit {
        if (!visible.add(d)) { return }
        if (let Some(p) <- (d as InheritableDecl)) {
            for (base in p.inheritedTypes) {
                if (let Some(parent) <- Ty.GetInheritableDeclPtrOfTy(base.GetTy())) { InsertVisible(parent, visible) }
            }
        }
        for (member in Members(d)) {
            let protectedMember = member.TestAttr(Attribute.PROTECTED) &&
                (d.astKind == ASTKind.CLASS_DECL || ExtendedClass(d)) &&
                (member.astKind == ASTKind.FUNC_DECL || member.astKind == ASTKind.PROP_DECL)
            if (member.TestAttr(Attribute.PUBLIC) || protectedMember || member.TestAttr(Attribute.ENUM_CONSTRUCTOR)) {
                InsertVisible(member, visible)
            }
            if (let Some(v) <- (member as VarDecl)) { CollectValueReferences(v, visible) }
        }
        if (d.IsConst() || Frozen(d)) {
            for (dep in d.dependencies) {
                if (let Some(value) <- dep) { InsertVisible(value, visible) }
            }
            let _ = Walker(d, visitPre: Some({node: Node =>
                if (let Some(target) <- node.GetTarget()) {
                    if (!target.TestAttr(Attribute.PUBLIC)) { InsertVisible(target, visible) }
                    if (let Some(parent) <- target.outerDecl) {
                        if (target.TestAttr(Attribute.CONSTRUCTOR) || parent.TestAttr(Attribute.GLOBAL) && !parent.TestAttr(Attribute.PUBLIC)) {
                            InsertVisible(parent, visible)
                        }
                    }
                }
                return VisitAction.WALK_CHILDREN
            })).Walk()
            if (let Some(v) <- (d as VarDecl)) { CollectValueReferences(v, visible) }
        }
    }
    public func CollectValueReferences(v: VarDecl, visible: HashSet<Decl>): Unit {
        if (let Some(value) <- v.initializer) {
            let _ = Walker(value, visitPre: Some({node: Node =>
                if (let Some(target) <- node.GetTarget()) {
                    if (!target.TestAttr(Attribute.PUBLIC)) { InsertVisible(target, visible) }
                    if (target.TestAttr(Attribute.CONSTRUCTOR)) {
                        if (let Some(parent) <- target.outerDecl) { InsertVisible(parent, visible) }
                    }
                }
                return VisitAction.WALK_CHILDREN
            })).Walk()
        } else if (let Some(decl) <- Ty.GetDeclPtrOfTy(v.GetTy())) {
            if (decl.astKind == ASTKind.STRUCT_DECL || decl.astKind == ASTKind.ENUM_DECL) { InsertVisible(decl, visible) }
        }
    }
    public func Emit(id: String, bad: Bool, oldNode!: Option<Node> = None, newNode!: Option<Node> = None): Unit {
        if (!bad) { return }
        let rule = catalog[id]
        if (!(options.api && rule.api || options.abi && rule.abi)) { return }
        let key = id + ":" + if (let Some(d) <- oldNode) { d.objectId.toString() } else { "" } + ":" +
            if (let Some(d) <- newNode) { d.objectId.toString() } else { "" }
        if (usedFindings.add(key)) { findings.add(Finding(id, oldNode, newNode)) }
    }
    public func Check(id: String, bad: Bool, a: Decl, b: Decl): Unit {
        Emit(id, bad, oldNode: Some(a), newNode: Some(b))
    }
    // Compare nominal type identities across the two independently loaded graphs.
    // Subtyping walks the compiler-materialized inheritance edges; it never uses
    // object identity across before/after contexts.
    public func IsSubtype(child: Option<Ty>, parent: Option<Ty>): Bool {
        if (SameType(child, parent)) { return true }
        let target = TypeName(parent)
        let supers = before.types.GetAllSuperTys(child.getOrThrow())
        for (ty in supers.values) { if (TypeName(Some(ty)) == target) { return true } }
        if (supers.values.isEmpty()) {
            for (ty in after.types.GetAllSuperTys(child.getOrThrow()).values) {
                if (TypeName(Some(ty)) == target) { return true }
            }
        }
        return false
    }
    public func Run(): Unit {
        if (options.debug) { PrintDiff() }
        let packageChanged = before.root.fullPackageName != after.root.fullPackageName ||
            AccessName(before.root.accessible) != AccessName(after.root.accessible)
        Emit("PACKAGE_DECL_CHANGED", packageChanged)
        if (packageChanged) { return }
        CompareDecls(TopDecls(before.root), TopDecls(after.root), None)
        this.CompareImports()
    }
    public func CompareDecls(old: ArrayList<Decl>, now: ArrayList<Decl>, owner: Option<Decl>): Unit {
        let matched = HashSet<Decl>()
        let sameLayout = SameNamelessDecls(old, now, owner)
        for (a in old) {
            var found: Option<Decl> = None
            for (b in now) {
                if (!matched.contains(b) && a.astKind == b.astKind && Identity(a) == Identity(b)) { found = Some(b); break }
            }
            // Function signature changes need parameter diagnostics rather than
            // hiding behind a mangled-name deletion; prefer the closest overload.
            if (found.isNone()) {
                var distance: Int64 = Int64.Max
                for (b in now) {
                    if (matched.contains(b) || a.astKind != b.astKind || a.identifier != b.identifier) { continue }
                    if (a.astKind == ASTKind.EXTEND_DECL && Identity(a) != Identity(b)) { continue }
                    let ap = Params(a); let bp = Params(b)
                    var score = if (ap.size > bp.size) { ap.size - bp.size } else { bp.size - ap.size }
                    for (i in 0..min(ap.size, bp.size)) {
                        if (!SameType(ap[i].GetTy(), bp[i].GetTy())) { score++ }
                    }
                    if (score < distance) { found = Some(b); distance = score }
                }
            }
            if (found.isNone() && a.TestAttr(Attribute.PRIVATE) && visibleOld.contains(a)) {
                for (b in now) {
                    if (!matched.contains(b) && a.astKind == b.astKind && a.identifier == b.identifier) {
                        Emit(Prefix(a) + "_LOCATION_CHANGED", true, oldNode: Some(a), newNode: Some(b))
                        found = Some(b); break
                    }
                }
            }
            if (let Some(b) <- found) {
                let prefix = Prefix(a)
                if (owner.isNone() && a.TestAttr(Attribute.PRIVATE) && visibleOld.contains(a) && visibleNew.contains(b) &&
                    Identity(a) != Identity(b) && (prefix == "VAR" || prefix == "FUNC" || prefix == "STRUCT" ||
                    prefix == "ENUM" || prefix == "CLASS" || prefix == "INTERFACE")) {
                    Emit(prefix + "_LOCATION_CHANGED", true, oldNode: Some(a), newNode: Some(b))
                }
                matched.add(b)
                CompareDecl(a, b, owner)
            } else if (!(sameLayout && IsVar(a) && !Visible(a))) { Deleted(a, owner) }
        }
        for (b in now) {
            if (!matched.contains(b) && !(sameLayout && IsVar(b) && !Visible(b))) { Added(b, owner, old, now) }
        }
        if (let Some(parent) <- owner) { this.CompareOrder(old, now, parent) }
    }
    public func Deleted(a: Decl, owner: Option<Decl>): Unit {
        if (let Some(p) <- owner) {
            let prefix = Prefix(p)
            if (a.TestAttr(Attribute.ENUM_CONSTRUCTOR)) { Emit("ENUM_CONSTRUCTOR_DELETED", true, oldNode: Some(a)); return }
            if (IsVar(a)) {
                if (prefix == "STRUCT") {
                    let rule = if (a.TestAttr(Attribute.STATIC)) { "STRUCT_STATIC_VAR_DEL" }
                        else if (Visible(a)) { "STRUCT_INSTANCE_VAR_DEL" } else { "STRUCT_INST_NO_PUBLIC_VAR_DEL" }
                    Emit(rule, !a.TestAttr(Attribute.STATIC) || visibleOld.contains(a), oldNode: Some(a))
                } else if (prefix == "CLASS") {
                    let rule = if (a.TestAttr(Attribute.STATIC)) { "CLASS_STATIC_MEMBER_VAR_DELETED" }
                        else if (Visible(a)) { "CLASS_PUBLIC_MEMBER_VAR_DELETED" } else { "CLASS_MEMBER_VAR_DELETED_ABI" }
                    Emit(rule, Visible(a) || !a.TestAttr(Attribute.STATIC), oldNode: Some(a))
                }
            } else if (visibleOld.contains(a)) {
                var rule = prefix + "_MEMBER_FUNC_DELETED"
                if (a.astKind == ASTKind.PROP_DECL) {
                    rule = if (prefix == "CLASS") { "CLASS_INSTANCE_MEMBER_PROPS_DELETED" } else { prefix + "_MEMBER_PROP_DELETED" }
                } else if (a.TestAttr(Attribute.CONSTRUCTOR)) {
                    rule = if (prefix == "CLASS") { "CLASS_CONSTRUCTOR_DELETED" } else { "STRUCT_INIT_FUNC_DELETED" }
                } else if (prefix == "CLASS") { rule = "CLASS_INSTANCE_MEMBER_FUNCS_DELETED" }
                else if (prefix == "EXTEND") {
                    rule = if (a.IsConst() && a.TestAttr(Attribute.PRIVATE)) { "EXTEND_PRIVATE_MEMBER_FUNC_CHANGED" }
                        else if (ExtendedClass(p)) { "EXTEND_MEMBER_FUNC_DELETED1" } else { "EXTEND_MEMBER_FUNC_DELETED2" }
                }
                Emit(rule, true, oldNode: Some(a))
            }
            if ((prefix == "CLASS" || prefix == "STRUCT") && a.TestAttr(Attribute.CONSTRUCTOR) && !Visible(a)) {
                var hasMember = false; var allPrivate = true
                for (param in Params(a)) {
                    if (param.isMemberParam) { hasMember = true; allPrivate = allPrivate && param.TestAttr(Attribute.PRIVATE) }
                }
                Emit(if (allPrivate) { "PRIMARY_CONSTRUCTOR_NON_PUBLIC_DELETED2" } else { "PRIMARY_CONSTRUCTOR_NON_PUBLIC_DELETED" },
                    hasMember, oldNode: Some(a))
            }
        } else if (visibleOld.contains(a)) {
            let rule = if (a.astKind == ASTKind.TYPE_ALIAS_DECL) { "DEL_TYPE_ALIAS" } else { Prefix(a) + "_DELETED" }
            Emit(rule, true, oldNode: Some(a))
        }
    }
    public func Added(b: Decl, owner: Option<Decl>, old: ArrayList<Decl>, now: ArrayList<Decl>): Unit {
        if (let Some(p) <- owner) {
            let prefix = Prefix(p)
            if (b.TestAttr(Attribute.ENUM_CONSTRUCTOR)) {
                let e = (p as EnumDecl).getOrThrow()
                var nonExhaustive = e.hasEllipsis
                for (decl in TopDecls(after.root)) {
                    if (Identity(decl) == Identity(e)) { nonExhaustive = nonExhaustive && (decl as EnumDecl).getOrThrow().hasEllipsis }
                }
                var allWithoutValues = true
                var oldCount: Int64 = 0; var newCount: Int64 = 0
                for (d in old) { if (d.TestAttr(Attribute.ENUM_CONSTRUCTOR)) { oldCount++; allWithoutValues = allWithoutValues && d.astKind != ASTKind.FUNC_DECL } }
                for (d in now) { if (d.TestAttr(Attribute.ENUM_CONSTRUCTOR)) { newCount++ } }
                Emit("ENUM_CONSTRUCTOR_ADDED_EXHAUSTIVE", !nonExhaustive, newNode: Some(b))
                Emit("ENUM_CONSTRUCTOR_ADDED_NON_EXHAUSTIVE", oldCount <= 256 && newCount > 256 ||
                    nonExhaustive && (allWithoutValues && b.astKind == ASTKind.FUNC_DECL || !AtEnd(b, old, now)), newNode: Some(b))
            } else if (IsInstanceVar(b)) {
                if (prefix == "STRUCT") { Emit("STRUCT_MEMBER_VAR_ADDED_ABI", true, newNode: Some(b)) }
                if (prefix == "CLASS") {
                    Emit("CLASS_MEMBER_VAR_ADDED_ABI", p.TestAttr(Attribute.OPEN) && !p.TestAttr(Attribute.SEALED) || !AtEnd(b, old, now), newNode: Some(b))
                }
            } else if (b.astKind == ASTKind.FUNC_DECL || b.astKind == ASTKind.PROP_DECL) {
                this.AddedCallable(b, p, old, now)
            }
        }
    }
    public func AtEnd(b: Decl, old: ArrayList<Decl>, now: ArrayList<Decl>): Bool {
        var reached = false
        for (d in now) {
            if (b.TestAttr(Attribute.ENUM_CONSTRUCTOR) && !d.TestAttr(Attribute.ENUM_CONSTRUCTOR) || IsVar(b) && !IsInstanceVar(d)) { continue }
            if (d == b) { reached = true; continue }
            if (reached) {
                for (a in old) {
                    if (IsVar(b) && !IsInstanceVar(a)) { continue }
                    if (Identity(a) == Identity(d)) { return false }
                }
            }
        }
        return true
    }
    public func AfterOwner(owner: Decl): Decl {
        for (decl in TopDecls(after.root)) {
            if (decl.astKind == owner.astKind && (Identity(decl) == Identity(owner) || decl.identifier == owner.identifier)) { return decl }
        }
        throw Exception("CJO owner correspondence missing: " + owner.identifier.Val())
    }
    public func CompareDecl(a: Decl, b: Decl, owner: Option<Decl>): Unit {
        if (!visibleOld.contains(a) && owner.isNone() && !a.TestAttr(Attribute.FOREIGN)) { return }
        if (visibleOld.contains(a)) {
            this.CompareModifiers(a, b, owner)
            this.CompareAnnotations(a, b, owner)
            this.CompareGenerics(a, b)
            if (a.astKind == ASTKind.FUNC_DECL) { this.CompareFunction(a, b, owner) }
            if (a.astKind == ASTKind.PROP_DECL) { this.CompareProperty(a, b, owner.getOrThrow()) }
        } else if (IsVar(a) && a.TestAttr(Attribute.PROTECTED)) {
            // The native class-field annotation rule includes protected fields
            // without adding them to the module-visible declaration closure.
            if (let Some(p) <- owner) {
                if (p.astKind == ASTKind.CLASS_DECL && visibleOld.contains(p) && visibleNew.contains(AfterOwner(p))) {
                    this.CompareAnnotations(a, b, owner)
                }
            }
        }
        if (owner.isNone() && a.astKind == ASTKind.FUNC_DECL && a.TestAttr(Attribute.FOREIGN)) {
            Check("FUNC_CALLINGCONV_ANNO", a.TestAttr(Attribute.C) != b.TestAttr(Attribute.C) ||
                a.TestAttr(Attribute.STD_CALL) != b.TestAttr(Attribute.STD_CALL), a, b)
        }
        if (IsVar(a)) { this.CompareVariable(a, b, owner) }
        if (let Some(x) <- (a as InheritableDecl)) {
            this.CompareInheritance(x, (b as InheritableDecl).getOrThrow())
            CompareDecls(Members(a), Members(b), Some(a))
        }
        if (a.astKind == ASTKind.TYPE_ALIAS_DECL) {
            let x = (a as TypeAliasDecl).getOrThrow(); let y = (b as TypeAliasDecl).getOrThrow()
            Check("MOD_TYPE_ALIAS", !SameType(x.typeNode.getOrThrow().GetTy(), y.typeNode.getOrThrow().GetTy()), a, b)
        }
    }
    public func PrintDiff(): Unit {
        let old = TopDecls(before.root); let now = TopDecls(after.root)
        for (category in ["Deleted", "Added", "Potentially Modified"]) {
            println("\n" + category + " decls: ")
            var count: Int64 = 0
            let nodes = if (category == "Added") { now } else { old }
            let peers = if (category == "Added") { old } else { now }
            for (d in nodes) {
                var exists = false
                for (p in peers) { exists = exists || d.astKind == p.astKind && Identity(d) == Identity(p) }
                if (exists == (category == "Potentially Modified")) { println("  " + d.identifier.Val()); count++ }
            }
            if (count == 0) { println("  --none-- ") }
        }
    }

    public func CompareFunction(a: Decl, b: Decl, owner: Option<Decl>): Unit {
        let ap = Params(a); let bp = Params(b)
        let ctor = a.TestAttr(Attribute.CONSTRUCTOR)
        var appendedDefault = ctor && bp.size == ap.size + 1
        if (appendedDefault) {
            for (i in 0..ap.size) {
                if (!SameType(ap[i].GetTy(), bp[i].GetTy()) || ap[i].identifier != bp[i].identifier) { appendedDefault = false }
            }
            appendedDefault = appendedDefault && bp[bp.size - 1].isNamedParam && HasDefault(bp[bp.size - 1])
        }
        Check("FUNC_PARAM_ADDED_ABI", appendedDefault, a, b)
        if (!appendedDefault) { Check("FUNC_NUM_PARAMS", ap.size != bp.size, a, b) }
        let constBody = a.IsConst() && b.IsConst() || Frozen(a) && Frozen(b)
        if (ap.size == bp.size) {
            var sameNamedSet = true
            var sameUnnamedSet = true
            var movedNamed = false
            var movedUnnamed = false
            for (i in 0..ap.size) {
                if (ap[i].isNamedParam != bp[i].isNamedParam) { sameNamedSet = false; sameUnnamedSet = false; break }
                var found = false
                for (q in bp) {
                    if (q.identifier == ap[i].identifier && q.isNamedParam == ap[i].isNamedParam && SameType(q.GetTy(), ap[i].GetTy())) { found = true }
                }
                if (ap[i].isNamedParam) {
                    sameNamedSet = sameNamedSet && found
                    movedNamed = movedNamed || ap[i].identifier != bp[i].identifier
                } else {
                    sameUnnamedSet = sameUnnamedSet && found
                    movedUnnamed = movedUnnamed || ap[i].identifier != bp[i].identifier
                }
            }
            let reordered = movedNamed && sameNamedSet || movedUnnamed && sameUnnamedSet
            Check("FUNC_CHANGE_ORDER_OF_NAMED_PARAMETER", movedNamed && sameNamedSet, a, b)
            Check("FUNC_CHANGE_ORDER_OF_UNNAMED_PARAMETER", movedUnnamed && sameUnnamedSet, a, b)
            if (!reordered) {
                for (i in 0..ap.size) {
                    let x = ap[i]; let y = bp[i]
                    Check("FUNC_PARAMETER_NAMED_TO_UNNAMED", x.isNamedParam && !y.isNamedParam, x, y)
                    Check("FUNC_PARAMETER_UNNAMED_TO_NAMED", !x.isNamedParam && y.isNamedParam, x, y)
                    Check("FUNC_CHANGE_NAME_OF_NAMED_PARAMETER", x.isNamedParam && x.identifier != y.identifier, x, y)
                    Check("FUNC_DROP_DEFAUT_VALUE_OF_NAMED_PARAMETER", x.isNamedParam && HasDefault(x) && !HasDefault(y), x, y)
                    let sameTy = SameType(x.GetTy(), y.GetTy())
                    if (x.identifier == y.identifier && sameTy) {
                        Check("FUNC_PARAMETER_VALUE_CHANGE_OF_CONST_OR_FROZEN", constBody && HasDefault(x) && HasDefault(y) && BodyHash(x) != BodyHash(y), x, y)
                        if (let Some(p) <- owner) {
                            Check("FUNC_MEMBER_PARAMETER_VALUE_ADD_OF_CONST_OR_FROZEN", x.isMemberParam && y.isMemberParam &&
                                !HasDefault(x) && HasDefault(y) && ConstOrFrozenInit(p), x, y)
                        }
                    }
                    if (!sameTy && x.isMemberParam && y.isMemberParam) {
                        Check("FUNC_CHANGE_TYPE_OF_MEMBER_PARAMETER", x.identifier == y.identifier, x, y)
                    } else if (!sameTy && x.isNamedParam == y.isNamedParam) {
                        let openMember = if (let Some(p) <- owner) {
                            p.astKind == ASTKind.CLASS_DECL && a.TestAttr(Attribute.OPEN) && !a.TestAttr(Attribute.STATIC) && !ctor
                        } else { false }
                        if (openMember) { Check("FUNC_CHANGE_TYPE_OF_PARAMETER_OPEN", true, x, y) }
                        else if (IsSubtype(x.GetTy(), y.GetTy())) { Check("FUNC_CHANGE_TYPE_OF_PARAMETER", true, x, y) }
                        else { Check("FUNC_CHANGE_TYPE_OF_PARAMETER_NOT_PARENT_TYPE", true, x, y) }
                    }
                }
            }
        }
        if (!ctor && !a.TestAttr(Attribute.ENUM_CONSTRUCTOR)) {
            let t1 = ReturnType(a); let t2 = ReturnType(b)
            if (!SameType(t1, t2)) {
                if (let Some(p) <- owner) {
                    if (p.astKind == ASTKind.INTERFACE_DECL) { Check("INTERFACE_MEMBER_FUNC_RETURN_TYPE", true, a, b) }
                    else if (p.astKind == ASTKind.CLASS_DECL && a.TestAttr(Attribute.OPEN) && !a.TestAttr(Attribute.STATIC)) {
                        Check("FUNC_RETURN_TYPE_OPEN", true, a, b)
                    } else { CheckReturn(a, b, t1, t2) }
                } else { CheckReturn(a, b, t1, t2) }
            }
        }
        Check("CONST_OR_FROZEN_BODY_CHANGE", constBody && BodyHash(a) != BodyHash(b), a, b)
    }
    public func CheckReturn(a: Decl, b: Decl, old: Option<Ty>, now: Option<Ty>): Unit {
        let subtype = IsSubtype(now, old)
        Check("FUNC_RETURN_TYPE_SUBTYPE", !subtype, a, b)
        Check("FUNC_RETURN_TYPE_CLASS_LIKE", subtype && !(ClassLike(old) && ClassLike(now)), a, b)
    }
    public func CompareProperty(a: Decl, b: Decl, owner: Decl): Unit {
        let prefix = Prefix(owner)
        let rule = if (prefix == "CLASS") { "CLASS_INSTANCE_MEMBER_PROP_RETURN_TYPE_CHANGED" }
            else { prefix + "_MEMBER_PROP_RETURN_TYPE_CHANGED" }
        Check(rule, !SameType(a.GetTy(), b.GetTy()), a, b)
        let x = (a as PropDecl).getOrThrow(); let y = (b as PropDecl).getOrThrow()
        if (Frozen(a) && Frozen(b)) {
            if (!x.getters.isEmpty() && !y.getters.isEmpty()) {
                Check("CONST_OR_FROZEN_BODY_CHANGE", BodyHash(x.getters[0]) != BodyHash(y.getters[0]), x.getters[0], y.getters[0])
            }
            if (!x.setters.isEmpty() && !y.setters.isEmpty()) {
                Check("CONST_OR_FROZEN_BODY_CHANGE", BodyHash(x.setters[0]) != BodyHash(y.setters[0]), x.setters[0], y.setters[0])
            }
        }
    }
    public func Overrides(d: Decl, owner: Decl): Bool {
        if (d.TestAttr(Attribute.OVERRIDE)) { return true }
        if (let Some(p) <- (owner as InheritableDecl)) {
            for (base in p.inheritedTypes) {
                if (let Some(inherited) <- Ty.GetInheritableDeclPtrOfTy(base.GetTy())) {
                    for (member in Members(inherited)) {
                        if (SameCallable(member, d) && !member.TestAttr(Attribute.ABSTRACT)) { return true }
                    }
                    if (Overrides(d, inherited)) { return true }
                }
            }
        }
        return false
    }
    public func AddedCallable(b: Decl, owner: Decl, old: ArrayList<Decl>, now: ArrayList<Decl>): Unit {
        let prefix = Prefix(owner)
        let isProperty = b.astKind == ASTKind.PROP_DECL
        let kind = if (isProperty) { "PROP" } else { "FUNC" }
        let isStatic = b.TestAttr(Attribute.STATIC)
        if (prefix == "CLASS" && b.TestAttr(Attribute.CONSTRUCTOR)) {
            var hasMember = false
            for (p in Params(b)) { hasMember = hasMember || p.isMemberParam }
            Emit("PRIMARY_CONSTRUCTOR_ADDED", hasMember, newNode: Some(b))
            return
        }
        if (prefix == "INTERFACE") {
            let hasBody = b.TestAttr(Attribute.DEFAULT)
            let atEnd = AtCallableEnd(b, old, now, false)
            let base = "INTERFACE_MEMBER_" + kind
            if (!atEnd && !hasBody) {
                Emit(base + "_WITHOUT_DEFAULT_IMP_ADDED", true, newNode: Some(b))
            } else {
                Emit("INTERFACE_" + if (isStatic) { "STATIC" } else { "INSTANCE" } + "_MEMBER_" + kind + "_ADDED",
                    Overrides(b, owner), newNode: Some(b))
                Emit(base + "_ADDED", !atEnd && !HasUnimplemented(b, owner), newNode: Some(b))
                Emit(base + "_WITHOUT_DEFAULT_IMP_ADDED2", !hasBody || HasUnimplemented(b, owner), newNode: Some(b))
            }
            return
        }
        if (prefix == "CLASS" && !isStatic) {
            Emit("CLASS_INSTANCE_MEMBER_" + kind + "_ADDED", HasUnimplemented(b, AfterOwner(owner)), newNode: Some(b))
            Emit("CLASS_INSTANCE_MEMBER_" + kind + "_ADDED2", Overrides(b, AfterOwner(owner)), newNode: Some(b))
            Emit("CLASS_OPEN_INSTANCE_MEMBER_" + if (isProperty) { "PROPS" } else { "FUNCS" } + "_ADDED",
                b.TestAnyAttr(Attribute.OPEN, Attribute.ABSTRACT) && !AtCallableEnd(b, old, now, true), newNode: Some(b))
        } else {
            Emit(prefix + "_" + if (isStatic) { "STATIC" } else { "INSTANCE" } + "_MEMBER_" + kind + "_ADDED",
                Overrides(b, if (prefix == "CLASS") { AfterOwner(owner) } else { owner }), newNode: Some(b))
        }
    }
    public func AtCallableEnd(b: Decl, old: ArrayList<Decl>, now: ArrayList<Decl>, openOnly: Bool): Bool {
        var reached = false
        for (d in now) {
            if (d == b) { reached = true; continue }
            if (!reached || !(d.astKind == ASTKind.FUNC_DECL || d.astKind == ASTKind.PROP_DECL)) { continue }
            if (openOnly && !d.TestAnyAttr(Attribute.OPEN, Attribute.ABSTRACT)) { continue }
            for (a in old) { if (Identity(a) == Identity(d)) { return false } }
        }
        return true
    }
    public func HasUnimplemented(d: Decl, owner: Decl): Bool {
        if (let Some(p) <- (owner as InheritableDecl)) {
            for (base in p.inheritedTypes) {
                if (let Some(parent) <- Ty.GetInheritableDeclPtrOfTy(base.GetTy())) {
                    for (member in Members(parent)) {
                        if (SameCallable(member, d) && member.TestAttr(Attribute.ABSTRACT)) { return true }
                    }
                    if (HasUnimplemented(d, parent)) { return true }
                }
            }
        }
        return false
    }


    public func CompareVariable(a: Decl, b: Decl, owner: Option<Decl>): Unit {
        let x = (a as VarDecl).getOrThrow(); let y = (b as VarDecl).getOrThrow()
        let mode1 = VarMode(x); let mode2 = VarMode(y)
        if (let Some(p) <- owner) {
            let prefix = Prefix(p)
            let isStatic = a.TestAttr(Attribute.STATIC)
            if (prefix != "CLASS" && prefix != "STRUCT") { return }
            if (isStatic) {
                let base = prefix + "_STATIC_VAR_"
                Check(if (prefix == "STRUCT") { "STRUCT_STATIC_VAR_PUBLIC_DEL" } else { "CLASS_STATIC_VAR_ACCESS_MODIFIER_MODIFIED" },
                    a.TestAttr(Attribute.PUBLIC) && !b.TestAttr(Attribute.PUBLIC), a, b)
                Check(if (prefix == "STRUCT") { "STRUCT_VAR_MODIFIER_STATIC_DELETED" } else { "CLASS_STATIC_VAR_DELETED_STATIC" },
                    !b.TestAttr(Attribute.STATIC), a, b)
                if (!visibleOld.contains(a) || !visibleNew.contains(b)) { return }
                Check(if (prefix == "STRUCT") { "STRUCT_STATIC_VAR_INIT_MODIFIED" } else { "CLASS_STATIC_CONST_VAR_INIT_MODIFIED" },
                    x.isConst && y.isConst && !SameValue(x, y), a, b)
                if (prefix == "STRUCT" && mode1 != mode2 && mode1 != "LET" || prefix == "STRUCT" && mode1 == "LET" && mode2 == "CONST") {
                    let rule = "STRUCT_STATIC_MEMBER_" + mode1 + "_TO_" + mode2
                    Check(rule, true, a, b)
                } else if (prefix == "CLASS") {
                    Check(base + "NON_ACCESS_MODIFIER_MODIFIED", mode1 != "LET" && mode1 != mode2, a, b)
                    Check(base + "NON_ACCESS_MODIFIER_MODIFIED_LET_CONST", mode1 == "LET" && mode2 == "CONST", a, b)
                }
                if (!SameType(a.GetTy(), b.GetTy())) {
                    let subtype = IsSubtype(b.GetTy(), a.GetTy())
                    Check(base + "TYPE_MODIFIED", !subtype, a, b)
                    Check(base + "TYPE_MODIFIED_CLASS_LIKE", subtype && !(ClassLike(a.GetTy()) && ClassLike(b.GetTy())), a, b)
                }
            } else {
                let publicVar = Visible(a)
                Check(prefix + "_MEMBER_VAR_NON_ACCESS_MODIFIER_MODIFIED", publicVar &&
                    !(mode1 == "LET" && (mode2 == "LET" || mode2 == "VAR") || mode1 == "VAR" && mode2 == "VAR" || mode1 == "CONST" && mode2 == "CONST"), a, b)
                Check(if (prefix == "STRUCT") { "STRUCT_INSTANCE_VAR_ACCESS_MODIFIED" } else { "CLASS_MEMBER_VAR_ACCESS_MODIFIER_MODIFIED" },
                    publicVar && !Visible(b) || a.TestAttr(Attribute.PUBLIC) && b.TestAttr(Attribute.PROTECTED), a, b)
                let typeRule = if (prefix == "STRUCT") {
                    if (publicVar && Visible(b)) { "STRUCT_MEMBER_VAR_TYPE_MODIFIED" } else { "STRUCT_NONPUBLIC_MEMBER_VAR_TYPE_MODIFIED" }
                } else {
                    if (publicVar && Visible(b)) { "CLASS_PUBLIC_PROTECTED_MEMBER_VAR_TYPE_MODIFIED" } else { "CLASS_PRIVATE_INTERNAL_MEMBER_VAR_TYPE_MODIFIED" }
                }
                Check(typeRule, !SameType(a.GetTy(), b.GetTy()), a, b)
                Check("STRUCT_CLASS_MEMBER_VAR_INIT_MODIFIED", !SameValue(x, y) && ConstOrFrozenInit(p) &&
                    ConstOrFrozenInit(AfterOwner(p)) && !IsNamedParam(x) && !x.isMemberParam, a, b)
            }
        } else {
            if (!visibleOld.contains(a)) { return }
            Check("VAR_ACCESS_MODIFIER_MODIFIED", !visibleNew.contains(b), a, b)
            Check("VAR_NON_ACCESS_MODIFIER_MODIFIED", mode1 != "LET" && mode1 != mode2, a, b)
            Check("VAR_NON_ACCESS_MODIFIER_MODIFIED_LET_CONST", mode1 == "LET" && mode2 == "CONST", a, b)
            Check("VAR_GLOBAL_INIT", x.isConst && y.isConst && !SameValue(x, y), a, b)
            if (!SameType(a.GetTy(), b.GetTy())) {
                let subtype = IsSubtype(b.GetTy(), a.GetTy())
                Check("VAR_GLOBAL_TYPE_MOD", !subtype, a, b)
                Check("VAR_GLOBAL_TYPE_MOD_CLASS_LIKE", subtype && !(ClassLike(a.GetTy()) && ClassLike(b.GetTy())), a, b)
            }
        }
    }
    public func CompareOrder(old: ArrayList<Decl>, now: ArrayList<Decl>, owner: Decl): Unit {
        for (kind in ["VAR", "FUNC", "PROP", "ENUM", "CALLABLE"]) {
            let isInterface = owner.astKind == ASTKind.INTERFACE_DECL
            if (kind == "CALLABLE" && !isInterface || isInterface && (kind == "FUNC" || kind == "PROP")) { continue }
            let left = ArrayList<Decl>(); let right = ArrayList<Decl>()
            for (d in old) {
                if (!OrderRelevant(d, owner, kind)) { continue }
                var exists = !isInterface
                for (peer in now) { exists = exists || Identity(peer) == Identity(d) }
                if (exists) { left.add(d) }
            }
            for (d in now) {
                if (!OrderRelevant(d, owner, kind)) { continue }
                var exists = !isInterface
                for (peer in old) { exists = exists || Identity(peer) == Identity(d) }
                if (exists) { right.add(d) }
            }
            if (left.size != right.size) { continue }
            for (i in 0..left.size) {
                if (Identity(left[i]) == Identity(right[i])) { continue }
                var stillExists = false
                for (d in right) { if (Identity(d) == Identity(left[i])) { stillExists = true } }
                if (!stillExists) { continue }
                var rule = ""
                if (kind == "VAR") { rule = Prefix(owner) + "_MEMBER_VAR_ORDER_MODIFIED" }
                if (kind == "ENUM") { rule = "ENUM_MEMBER_VAR_ORDER_MODIFIED" }
                if (kind == "FUNC" || kind == "PROP" || kind == "CALLABLE") {
                    if (owner.astKind == ASTKind.CLASS_DECL) {
                        rule = "CLASS_OPEN_INSTANCE_MEMBER_" + if (kind == "FUNC") { "FUNCS" } else { "PROPS" } + "_ORDER_CHANGED"
                    } else if (owner.astKind == ASTKind.INTERFACE_DECL) {
                        rule = "INTERFACE_INSTANCE_MEMBER_FUNCS_ORDER_CHANGED"
                    }
                }
                if (!rule.isEmpty()) { Check(rule, true, left[i], right[i]) }
            }
        }
    }


    public func CompareGenerics(a: Decl, b: Decl): Unit {
        let prefix = Prefix(a)
        if (!(prefix == "FUNC" || prefix == "STRUCT" || prefix == "ENUM" || prefix == "CLASS" || prefix == "INTERFACE" || prefix == "EXTEND")) { return }
        let x = GenericParams(a); let y = GenericParams(b)
        Check(prefix + "_GENERIC_PARAM_ADDED", x.size < y.size, a, b)
        Check(prefix + "_GENERIC_PARAM_DELETED", x.size > y.size, a, b)
        if (x.size == y.size) {
            var reordered = false; var sameSet = true
            for (i in 0..x.size) {
                reordered = reordered || x[i].identifier != y[i].identifier
                var exists = false
                for (p in y) { exists = exists || p.identifier == x[i].identifier }
                sameSet = sameSet && exists
            }
            Check(prefix + "_GENERIC_PARAM_CHANGED", reordered && sameSet, a, b)
        }
        let old = Constraints(a); let now = Constraints(b)
        var oldCount: Int64 = 0; var newCount: Int64 = 0
        for ((_, bounds) in old) { oldCount += bounds.size }
        for ((_, bounds) in now) { newCount += bounds.size }
        let leftCount = if (old.size == now.size) { oldCount } else { old.size }
        let rightCount = if (old.size == now.size) { newCount } else { now.size }
        Check(prefix + "_GENERIC_CONSTRAINT_ADDED", leftCount < rightCount, a, b)
        Check(prefix + "_GENERIC_CONSTRAINT_DELETED", leftCount > rightCount, a, b)
        if (old.size != now.size) { return }
        if (let Some(g) <- a.GetGeneric()) {
            for (constraint in g.genericConstraints) {
                let name = TypeName(constraint.refType.getOrThrow().GetTy())
                if (let Some(newBounds) <- now.get(name)) {
                    let bounds = constraint.upperBounds
                    // The native checker returns compatible when matched clauses
                    // differ in bound count; the count rules above own that change.
                    if (newBounds.size != bounds.size) { return }
                    var same = true
                    for (t in bounds) {
                        var found = false
                        for (u in newBounds) { found = found || BoundName(t) == BoundName(u) }
                        same = same && found
                    }
                    if (same) { continue }
                    // Multi-bound set changes use the general CHANGED rule. Only
                    // a single changed bound is classified by the subtype relation.
                    let relaxed = bounds.size != 1 || IsSubtype(bounds[0].GetTy(), newBounds[0].GetTy())
                    Check(prefix + if (relaxed) { "_GENERIC_CONSTRAINT_CHANGED" } else { "_GENERIC_CONSTRAINT_CHANGED_NOT_PARENT_TYPE" }, true, a, b)
                    return
                }
            }
        }
    }
    public func CompareInheritance(a: InheritableDecl, b: InheritableDecl): Unit {
        let prefix = Prefix(a)
        let old = HashMap<String, Type>(); let now = HashMap<String, Type>()
        let oldClass = HashSet<String>(); let newClass = HashSet<String>()
        for (t in a.inheritedTypes) {
            if (t.GetTy().getOrThrow().IsClass()) { oldClass.add(TypeName(t.GetTy())) }
            else { old[TypeName(t.GetTy())] = t }
        }
        for (t in b.inheritedTypes) {
            if (t.GetTy().getOrThrow().IsClass()) { newClass.add(TypeName(t.GetTy())) }
            else { now[TypeName(t.GetTy())] = t }
        }
        if (prefix != "EXTEND" || ExportedExtend(a)) {
            Check("INTERFACE_" + prefix + "_IMPL_DELETED", old.size > now.size, a, b)
            if (old.size <= now.size) {
                for ((name, _) in old) { Check("INTERFACE_" + prefix + "_IMPL_CHANGED", !now.contains(name), a, b) }
            }
        }
        if (prefix == "CLASS") {
            Check("SUPERCLASS_CLASS_INHERIT_DELETED", oldClass.size > newClass.size, a, b)
            Check("SUPERCLASS_CLASS_INHERIT_ADDED", oldClass.size < newClass.size, a, b)
            if (oldClass.size <= newClass.size) {
                for (name in oldClass) { Check("SUPERCLASS_CLASS_INHERIT_CHANGED", !newClass.contains(name), a, b) }
            }
        }
        if (prefix == "CLASS" || prefix == "INTERFACE") {
            for ((name, ty) in now) {
                if (old.contains(name)) { continue }
                if (let Some(d) <- Ty.GetInheritableDeclPtrOfTy(ty.GetTy())) {
                    Check("INTERFACE_" + prefix + "_IMPL_ADDED", HasAbstractInterface(d), a, b)
                }
            }
        }
    }
    public func HasAbstractInterface(d: Decl): Bool {
        let members = ArrayList<Decl>()
        for (ty in after.types.GetAllSuperTys(d.GetTy().getOrThrow()).values) {
            if (let Some(parent) <- Ty.GetInheritableDeclPtrOfTy(Some(ty))) { members.add(all: Members(parent)) }
        }
        members.add(all: Members(d))
        for (member in members) {
            if (!member.TestAttr(Attribute.ABSTRACT)) { continue }
            var implemented = false
            for (other in members) { implemented = implemented || !other.TestAttr(Attribute.ABSTRACT) && SameCallable(member, other) }
            if (!implemented) { return true }
        }
        return false
    }
    public func ImportKey(i: ImportSpec): String {
        var name = ""
        for (part in i.content.prefixPaths) { name += part + "/" }
        return name + i.content.identifier.Val()
    }
    public func SameImportPackage(a: ImportSpec, b: ImportSpec): Bool {
        if (!a.content.isDecl || !b.content.isDecl || a.content.prefixPaths.size != b.content.prefixPaths.size) { return false }
        for (i in 0..a.content.prefixPaths.size) { if (a.content.prefixPaths[i] != b.content.prefixPaths[i]) { return false } }
        return true
    }
    public func CompareImports(): Unit {
        let old = HashMap<String, ImportSpec>(); let now = HashMap<String, ImportSpec>()
        for (f in before.root.files) { for (i in f.imports) { old[ImportKey(i)] = i } }
        for (f in after.root.files) { for (i in f.imports) { now[ImportKey(i)] = i } }
        let checked = HashSet<String>()
        for ((name, i) in old) {
            if (now.contains(name)) {
                let j = now[name]
                Emit("ADD_IMPORT_STATEMENT", !i.TestAttr(Attribute.PUBLIC) && j.TestAttr(Attribute.PUBLIC), newNode: Some(j))
                continue
            }
            var paired = false
            for ((key, j) in now) {
                if (!old.contains(key) && !checked.contains(ImportKey(j)) && SameImportPackage(i, j)) {
                    checked.add(ImportKey(j)); paired = true
                    if (i.TestAttr(Attribute.PUBLIC)) {
                        Emit("DEL_IMPORT_STATEMENT", true, oldNode: Some(i))
                        Emit("ADD_IMPORT_STATEMENT", true, newNode: Some(j))
                    }
                    break
                }
            }
            Emit(if (i.TestAttr(Attribute.PUBLIC)) { "DEL_IMPORT_STATEMENT" } else { "DEL_NONPUBLIC_IMPORT_STATEMENT" },
                !paired, oldNode: Some(i))
        }
        for ((name, j) in now) {
            Emit("ADD_IMPORT_STATEMENT", !old.contains(name) && !checked.contains(ImportKey(j)), newNode: Some(j))
        }
    }


    public func CompareModifiers(a: Decl, b: Decl, owner: Option<Decl>): Unit {
        let unsafeAdded = AddedAttr(a, b, Attribute.UNSAFE)
        let staticAdded = AddedAttr(a, b, Attribute.STATIC)
        let staticRemoved = RemovedAttr(a, b, Attribute.STATIC)
        let mutAdded = AddedAttr(a, b, Attribute.MUT)
        let mutRemoved = RemovedAttr(a, b, Attribute.MUT)
        let constAdded = !a.IsConst() && b.IsConst()
        let constRemoved = a.IsConst() && !b.IsConst()
        if (let Some(p) <- owner) {
            if (a.astKind != ASTKind.FUNC_DECL && a.astKind != ASTKind.PROP_DECL) { return }
            let prefix = Prefix(p)
            let isProperty = a.astKind == ASTKind.PROP_DECL
            let kind = if (isProperty) { "PROP" } else { "FUNC" }
            let ctor = a.TestAttr(Attribute.CONSTRUCTOR)
            if (prefix == "STRUCT" || prefix == "ENUM") {
                let base = prefix + if (ctor) { "_INIT_FUNC" } else { "_MEMBER_" + kind }
                Check(base + "_MODIFIER_CHANGED", ReducedAccess(a, b) || staticAdded || staticRemoved ||
                    (!isProperty && (unsafeAdded || mutAdded || constRemoved)), a, b)
                if (prefix == "STRUCT" && !isProperty) { Check(base + "_MODIFIER_CHANGED2", mutRemoved, a, b) }
            } else if (prefix == "CLASS") {
                let base = if (ctor) { "CLASS_CONSTRUCTOR" } else { "CLASS_INSTANCE_MEMBER_" + kind }
                Check(base + "_VISIBILITY_CHANGED", ReducedAccess(a, b), a, b)
                if (!isProperty) {
                    Check("CLASS_INSTANCE_MEMBER_FUNC_UNSAFE_ATTR_ADDED", !ctor && unsafeAdded, a, b)
                    Check("CLASS_INSTANCE_MEMBER_FUNC_CONST_ATTR_ADDED", !ctor && !a.TestAttr(Attribute.STATIC) && constAdded, a, b)
                    Check(base + "_CONST_ATTR_DELETED", constRemoved, a, b)
                    Check("CLASS_INSTANCE_MEMBER_FUNC_OPEN_ATTR_ADDED", AddedAttr(a, b, Attribute.OPEN), a, b)
                    Check("CLASS_INSTANCE_MEMBER_FUNC_OPEN_ATTR_DELETED", RemovedAttr(a, b, Attribute.OPEN), a, b)
                } else { Check("CLASS_MEMBER_PROP_MUT_ATTR_DELETED", mutRemoved, a, b) }
                Check("CLASS_INSTANCE_MEMBER_" + kind + "_STATIC_ATTR_ADDED", staticAdded, a, b)
                Check("CLASS_INSTANCE_MEMBER_" + kind + "_STATIC_ATTR_DELETED", staticRemoved, a, b)
            } else if (prefix == "INTERFACE") {
                Check("INTERFACE_MEMBER_FUNC_PROP_MODIFIER_STATIC_ADDED", staticAdded, a, b)
                Check("INTERFACE_MEMBER_FUNC_PROP_MODIFIER_STATIC_DELETED", staticRemoved, a, b)
                Check("INTERFACE_MEMBER_FUNC_PROP_MODIFIER_MUT_DELETED", mutRemoved, a, b)
                Check("INTERFACE_MEMBER_" + kind + "_MODIFIER_MUT_ADDED", mutAdded, a, b)
                if (!isProperty) {
                    Check("INTERFACE_MEMBER_FUNC_MODIFIER_CONST_ADDED", constAdded, a, b)
                    Check("INTERFACE_MEMBER_FUNC_MODIFIER_CONST_DELETED", constRemoved, a, b)
                    Check("INTERFACE_MEMBER_FUNC_MODIFIER_UNSAFE_ADDED", unsafeAdded, a, b)
                }
            } else if (prefix == "EXTEND") {
                let base = "EXTEND_MEMBER_" + kind
                Check(base + "_VISIBILITY_CHANGED", ReducedAccess(a, b), a, b)
                Check(base + "_MODIFIER_PUBLIC_DELETED", RemovedAttr(a, b, Attribute.PUBLIC), a, b)
                Check(base + "_MODIFIER_STATIC_ADDED", staticAdded, a, b)
                Check(base + "_MODIFIER_STATIC_DELETED", staticRemoved, a, b)
                if (isProperty) {
                    Check(base + "_MUT_ADDED", mutAdded, a, b)
                    Check(base + "_MUT_DELETED", mutRemoved, a, b)
                } else {
                    Check(base + "_MODIFIER_CONST_ADDED", constAdded, a, b)
                    Check(base + "_MODIFIER_CONST_DELETED", constRemoved, a, b)
                    Check(base + "_MODIFIER_MUT_ADDED", mutAdded, a, b)
                    Check(base + "_MODIFIER_MUT_DELETED", mutRemoved, a, b)
                    Check(base + "_MODIFIER_UNSAFE_ADDED", unsafeAdded, a, b)
                }
            }
            return
        }
        let prefix = Prefix(a)
        if (prefix == "FUNC") {
            Check("FUNC_ACCESS_MODIFIER_MODIFIED", !visibleNew.contains(b), a, b)
            Check("FUNC_NON_ACCESS_MODIFIER_UNSAFE_ADDED", unsafeAdded, a, b)
            Check("FUNC_NON_ACCESS_MODIFIER_CONST_REMOVED", constRemoved, a, b)
        } else if (prefix == "STRUCT" || prefix == "ENUM" || prefix == "CLASS" || prefix == "INTERFACE") {
            Check(prefix + "_ACCESS_MODIFIER_MODIFIED", !visibleNew.contains(b), a, b)
        }
        if (prefix == "CLASS") {
            Check("CLASS_MODIFIER_PUBLIC_DELETED", RemovedAttr(a, b, Attribute.PUBLIC) && !a.TestAttr(Attribute.SEALED), a, b)
            Check("CLASS_MODIFIER_SEALED_DELETED", RemovedAttr(a, b, Attribute.SEALED) && !b.TestAttr(Attribute.PUBLIC), a, b)
            Check("CLASS_NON_ACCESS_MODIFIER_ABSTRACT_ADDED", AddedAttr(a, b, Attribute.ABSTRACT), a, b)
            Check("CLASS_NON_ACCESS_MODIFIER_ABSTRACT_DELETED", RemovedAttr(a, b, Attribute.ABSTRACT), a, b)
            Check("CLASS_NON_ACCESS_MODIFIER_SEALED_ADDED", AddedAttr(a, b, Attribute.SEALED) &&
                !a.TestAttr(Attribute.OPEN) && b.TestAttr(Attribute.OPEN), a, b)
            Check("CLASS_NON_ACCESS_MODIFIER_OPEN_REMOVED", RemovedAttr(a, b, Attribute.OPEN) && !a.TestAttr(Attribute.SEALED), a, b)
        }
        if (prefix == "INTERFACE") {
            Check("INTERFACE_MODIFIER_PUBLIC_DELETED", RemovedAttr(a, b, Attribute.PUBLIC) && !a.TestAttr(Attribute.SEALED), a, b)
            Check("INTERFACE_MODIFIER_SEALED_ADDED", AddedAttr(a, b, Attribute.SEALED), a, b)
            Check("INTERFACE_MODIFIER_SEALED_DELETED", RemovedAttr(a, b, Attribute.SEALED) && !b.TestAttr(Attribute.PUBLIC), a, b)
        }
    }
    public func CompareAnnotations(a: Decl, b: Decl, owner: Option<Decl>): Unit {
        let (had, wasStrict) = Deprecation(a); let (has, strict) = Deprecation(b)
        let added = !had && has && strict
        let changed = had && has && !wasStrict && strict
        let lostFrozen = Frozen(a) && !Frozen(b)
        if (let Some(p) <- owner) {
            let prefix = Prefix(p)
            let isProperty = a.astKind == ASTKind.PROP_DECL
            let ctor = a.TestAttr(Attribute.CONSTRUCTOR)
            if (IsVar(a)) {
                let base = if (prefix == "STRUCT") { "STRUCT_VAR" } else { "CLASS_MEMBER_VAR" }
                Check(base + "_DEPRE_ANNO_ADD", added, a, b)
                Check(base + "_DEPRE_ANNO_MOD", changed, a, b)
            } else if (a.astKind == ASTKind.FUNC_DECL || isProperty) {
                let kind = if (isProperty) { "PROP" } else { "FUNC" }
                if (prefix == "STRUCT" || prefix == "ENUM") {
                    let base = prefix + if (ctor) { "_INIT_FUNC" } else { "_MEMBER_" + kind }
                    Check(base + "_ANNO_CHANGED", added || changed, a, b)
                    Check(base + "_ANNO_CHANGED2", lostFrozen, a, b)
                } else if (prefix == "CLASS") {
                    let base = if (ctor) { "CLASS_CONSTRUCTOR" } else { "CLASS_INSTANCE_MEMBER_" + kind }
                    Check(base + "_FROZEN_ANNO_DELETED", lostFrozen, a, b)
                    Check(base + "_DEPRE_ANNO_ADDED", added, a, b)
                    Check(base + "_DEPRE_ANNO_CHANGED", changed, a, b)
                } else {
                    let base = prefix + "_MEMBER_" + kind
                    Check(base + "_DEPRECATED_CHANGED", added || changed, a, b)
                    Check(base + "_FROZEN_DELETED", lostFrozen, a, b)
                }
            }
        } else {
            let prefix = Prefix(a)
            if (prefix == "VAR" || prefix == "FUNC" || prefix == "STRUCT" || prefix == "ENUM" || prefix == "CLASS" || prefix == "INTERFACE") {
                Check(prefix + "_DEPRE_ANNO_ADD", added, a, b)
                Check(prefix + "_DEPRE_ANNO_MOD", changed, a, b)
            }
            if (prefix == "FUNC" || prefix == "STRUCT") {
                Check(prefix + "_C_ANNO_ADD", AddedAttr(a, b, Attribute.C) && (prefix == "STRUCT" || !b.TestAttr(Attribute.UNSAFE)), a, b)
                Check(prefix + "_C_ANNO_DEL", RemovedAttr(a, b, Attribute.C), a, b)
            }
            if (prefix == "FUNC") {
                Check("FUNC_FROZEN_ANNO", lostFrozen, a, b)
                Check("FUNC_CALLINGCONV_ANNO", a.TestAttr(Attribute.C) != b.TestAttr(Attribute.C) ||
                    a.TestAttr(Attribute.STD_CALL) != b.TestAttr(Attribute.STD_CALL), a, b)
            }
        }
    }

    public func PrintNode(node: Node, side: String): Unit {
        var label = ""
        let sources = if (side == "BEFORE") { before.sources } else { after.sources }
        var file = sources.GetSource(node.begin.fileID).path
        if (let Some(d) <- (node as Decl)) {
            label = if (d.TestAttr(Attribute.ENUM_CONSTRUCTOR)) { "enum_constructor_decl" }
                else { ASTKindName(d.astKind) }
            label += " " + d.identifier.GetRawText() + ": "
            if (file.isEmpty()) { if (let Some(f) <- d.curFile) { file = f.filePath } }
        }
        println("  " + label + "[" + side + "] " + file + ":" + node.begin.line.toString() + ":" +
            node.begin.column.toString() + "-" + node.end.line.toString() + ":" + node.end.column.toString())
    }
    public func Print(): Unit {
        if (findings.isEmpty()) { println("Compatible!"); return }
        println("Incompatible!\n")
        for (finding in findings) {
            let rule = catalog[finding.id]
            let mode = if (rule.api && options.api && rule.abi && options.abi) { "API/ABI" }
                else if (rule.api && options.api) { "API" } else { "ABI" }
            println("[" + mode + "] " + rule.description)
            if (let Some(a) <- finding.oldNode) { PrintNode(a, "BEFORE") }
            if (let Some(b) <- finding.newNode) { PrintNode(b, "AFTER") }
        }
    }
}

func AccessName(access: AccessLevel): String {
    match (access) {
        case AccessLevel.PUBLIC => "public"
        case AccessLevel.PROTECTED => "protected"
        case AccessLevel.INTERNAL => "internal"
        case _ => "private"
    }
}
