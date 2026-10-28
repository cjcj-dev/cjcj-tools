package cjcompat

import std.collection.*
import cjcj::ast.*

func BoundName(t: Type): String {
    if (let Some(r) <- (t as RefType)) { return r.ref.identifier.Val() }
    return TypeName(t.GetTy())
}

func GenericParams(d: Decl): ArrayList<GenericParamDecl> {
    if (let Some(g) <- d.GetGeneric()) { return g.typeParameters }
    return ArrayList<GenericParamDecl>()
}
func Constraints(d: Decl): HashMap<String, ArrayList<Type>> {
    let result = HashMap<String, ArrayList<Type>>()
    if (let Some(g) <- d.GetGeneric()) {
        for (c in g.genericConstraints) {
            if (let Some(t) <- c.refType) { result[TypeName(t.GetTy())] = c.upperBounds }
        }
    }
    return result
}

