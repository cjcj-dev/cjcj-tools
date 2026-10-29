package cjcompat

import std.collection.*
import cjcj::ast.*

func VarMode(v: VarDecl): String { if (v.isConst) { "CONST" } else if (v.isVar) { "VAR" } else { "LET" } }
func SameValue(a: VarDecl, b: VarDecl): Bool {
    if (a.initializer.isNone() || b.initializer.isNone()) { return true }
    let leftExpr = a.initializer.getOrThrow(); let rightExpr = b.initializer.getOrThrow()
    if (let Some(x) <- (leftExpr as LitConstExpr)) {
        if (let Some(y) <- (rightExpr as LitConstExpr)) { return x.stringValue == y.stringValue }
    } else if (let Some(x) <- (leftExpr as RefExpr)) {
        if (let Some(y) <- (rightExpr as RefExpr)) { return x.ref.identifier == y.ref.identifier }
    } else if (let Some(x) <- (leftExpr as CallExpr)) {
        if (let Some(y) <- (rightExpr as CallExpr)) {
            if (let Some(left) <- x.baseFunc) {
                if (let Some(right) <- y.baseFunc) {
                    if (left.astKind == ASTKind.REF_EXPR && right.astKind == ASTKind.REF_EXPR) {
                        return (left as RefExpr).getOrThrow().ref.identifier == (right as RefExpr).getOrThrow().ref.identifier
                    }
                }
            }
        }
    }
    return true
}


func OrderRelevant(d: Decl, owner: Decl, kind: String): Bool {
    if (kind == "VAR") { return IsInstanceVar(d) &&
        (owner.astKind == ASTKind.STRUCT_DECL || owner.astKind == ASTKind.CLASS_DECL) }
    if (kind == "ENUM") { return d.TestAttr(Attribute.ENUM_CONSTRUCTOR) }
    if (kind == "CALLABLE") { return d.astKind == ASTKind.FUNC_DECL || d.astKind == ASTKind.PROP_DECL }
    if (kind == "FUNC" && d.astKind != ASTKind.FUNC_DECL || kind == "PROP" && d.astKind != ASTKind.PROP_DECL) { return false }
    if (d.TestAnyAttr(Attribute.CONSTRUCTOR, Attribute.STATIC)) { return false }
    return owner.astKind == ASTKind.INTERFACE_DECL || owner.astKind == ASTKind.CLASS_DECL && d.TestAnyAttr(Attribute.OPEN, Attribute.ABSTRACT)
}

func SameNamelessDecls(old: ArrayList<Decl>, now: ArrayList<Decl>, owner: Option<Decl>): Bool {
    if (owner.isNone() || old.size != now.size) { return false }
    let parent = owner.getOrThrow()
    if (!(parent.astKind == ASTKind.CLASS_DECL || parent.astKind == ASTKind.STRUCT_DECL)) { return false }
    for (i in 0..old.size) {
        let a = old[i]; let b = now[i]
        if (a.astKind != b.astKind) { return false }
        if (a.TestAttr(Attribute.PUBLIC) && b.TestAttr(Attribute.PUBLIC) ||
            parent.astKind == ASTKind.CLASS_DECL && a.TestAttr(Attribute.PROTECTED) && b.TestAttr(Attribute.PROTECTED)) {
            if (Identity(a) != Identity(b)) { return false }
        } else {
            if (!SameType(a.GetTy(), b.GetTy())) { return false }
            if (let Some(x) <- (a as VarDecl)) {
                if (let Some(y) <- (b as VarDecl)) {
                    if (x.TestAttr(Attribute.INITIALIZED) && y.TestAttr(Attribute.INITIALIZED) && !SameValue(x, y)) { return false }
                }
            }
        }
    }
    return true
}
