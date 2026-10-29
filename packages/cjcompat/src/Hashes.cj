package cjcompat

import std.collection.*
import std.sort.*
import cjcj::ast.*
import cjcj::parse.ASTHasher

// Match the old compatibility diff's normalized compiler AST hash: source
// locations, declaration signatures and annotations do not become body changes.
func BodyHash(d: Decl): UInt64 {
    if (let Some(param) <- (d as FuncParam)) {
        let value = VarDecl()
        if (let Some(expr) <- param.assignment) { value.initializer = (ASTCloner.Clone(expr) as Expr) }
        return ASTHasher.BodyHash(value, srcInfo: (false, false), hashAnnos: false)
    }
    if (let Some(f) <- (d as FuncDecl)) {
        let normalized = FuncDecl()
        let body = FuncBody()
        body.paramLists.add(FuncParamList())
        if (let Some(original) <- f.funcBody) {
            if (let Some(block) <- original.body) {
                body.body = (ASTCloner.Clone(block, {_: Node, cloned: Node =>
                    if (let Some(refExpr) <- (cloned as RefExpr)) {
                        if (let Some(target) <- refExpr.GetTarget()) {
                            target.rawMangleName = ""
                            if (target.GetTy().getOrThrow().HasGeneric()) { refExpr.ref.target = None }
                        }
                    }
                    if (let Some(call) <- (cloned as CallExpr)) { NormalizeCallNames(call) }
                }) as Block)
            }
        }
        normalized.funcBody = Some(body)
        return ASTHasher.BodyHash(normalized, srcInfo: (false, false), hashAnnos: false)
    }
    return ASTHasher.BodyHash(d, srcInfo: (false, false), hashAnnos: false)
}

func NormalizeCallNames(call: CallExpr): Unit {
    if (let Some(base) <- call.baseFunc) {
        if (let Some(target) <- base.GetTarget()) {
            let params = Params(target)
            let names = ArrayList<String>()
            for (param in params) { if (param.isNamedParam) { names.add(param.identifier.Val()) } }
            sort(names)
            var combined = ""
            for (name in names) { combined += name }
            for (i in 0..min(call.args.size, params.size)) {
                if (params[i].isNamedParam && call.args[i].name.Val().isEmpty()) { call.args[i].name = SrcIdentifier(combined) }
            }
        }
    }
}
