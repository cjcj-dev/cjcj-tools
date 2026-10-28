package cjcompat

import std.collection.*
import cjcj::ast.*

func HasDefault(p: FuncParam): Bool { p.assignment.isSome() || p.TestAttr(Attribute.HAS_INITIAL) }
func IsNamedParam(d: Decl): Bool {
    if (let Some(p) <- (d as FuncParam)) { return p.isNamedParam }
    return false
}
func ConstOrFrozenInit(d: Decl): Bool {
    for (m in Members(d)) {
        if (m.TestAttr(Attribute.CONSTRUCTOR) && (m.IsConst() || Frozen(m))) { return true }
    }
    return false
}



func HasImplementation(d: Decl): Bool {
    if (let Some(f) <- (d as FuncDecl)) {
        if (let Some(body) <- f.funcBody) { return body.body.isSome() }
    }
    if (let Some(p) <- (d as PropDecl)) {
        for (g in p.getters) { if (HasImplementation(g)) { return true } }
        for (s in p.setters) { if (HasImplementation(s)) { return true } }
    }
    return false
}

func SameCallable(a: Decl, b: Decl): Bool {
    if (a.astKind != b.astKind || a.identifier != b.identifier ||
        a.TestAttr(Attribute.STATIC) != b.TestAttr(Attribute.STATIC)) { return false }
    if (a.astKind == ASTKind.PROP_DECL) { return SameType(a.GetTy(), b.GetTy()) }
    if (a.astKind != ASTKind.FUNC_DECL) { return false }
    let left = Params(a); let right = Params(b)
    if (left.size != right.size) { return false }
    for (i in 0..left.size) {
        if (!SameType(left[i].GetTy(), right[i].GetTy()) || left[i].isNamedParam != right[i].isNamedParam) { return false }
        if (left[i].isNamedParam && left[i].identifier != right[i].identifier) { return false }
    }
    return true
}

func ExtendedClass(d: Decl): Bool {
    if (let Some(e) <- (d as ExtendDecl)) {
        if (let Some(t) <- e.extendedType) { return t.GetTy().getOrThrow().IsClass() }
    }
    return false
}

func ExportedExtend(d: Decl): Bool {
    if (let Some(e) <- (d as ExtendDecl)) {
        let ty = e.extendedType.getOrThrow().GetTy()
        if (let Some(target) <- Ty.GetDeclPtrOfTy(ty)) {
            if (target.TestAttr(Attribute.PUBLIC)) { return true }
            if (let Some(file) <- target.curFile) {
                if (let Some(own) <- e.curFile) {
                    if (let Some(pkg) <- file.curPackage) {
                        if (let Some(ownPkg) <- own.curPackage) {
                            if (refEq(pkg, ownPkg)) { return false }
                        }
                    }
                }
            }
        } else if (!ty.getOrThrow().IsPrimitive()) { return false }
        for (base in e.inheritedTypes) {
            if (let Some(parent) <- Ty.GetDeclPtrOfTy(base.GetTy())) {
                if (parent.TestAttr(Attribute.PRIVATE)) { return false }
            }
        }
        return true
    }
    return false
}
