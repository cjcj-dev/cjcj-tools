package cjlint

import cjcj::ast.*
import std.collection.*

func upperCamelType(name: String): Bool {
    if (name.isEmpty() || name[0] < b'A' || name[0] > b'Z') { return false }
    for (byte in name.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9'))) { return false }
    }
    return true
}

func isExceptionClass(declaration: ClassDecl, visited: HashSet<Decl>): Bool {
    for (base in declaration.inheritedTypes) {
        let name = base.ToString()
        if (name == "Exception" || name == "Error" || name == "Throwable") { return true }
        if (let Some(ty) <- base.GetTy()) {
            if (let Some(classTy) <- (ty as ClassTy)) {
                if (let Some(parent) <- classTy.decl) {
                    if (visited.contains(parent)) { continue }
                    visited.add(parent)
                    if (isExceptionClass(parent, visited)) { return true }
                }
            }
        }
    }
    return false
}

func diagnoseTypeName(engine: RuleEngine, declaration: Decl): Unit {
    if (!upperCamelType(declaration.identifier.Val())) {
        engine.emit(declaration, "G_NAM_03_identifier_naming_information", [declaration.identifier.Val()])
    }
}

func checkQuotedTypeNames(engine: RuleEngine, quotation: QuoteExpr): Unit {
    for (expression in quotation.exprs) {
        if (let Some(part) <- (expression as TokenPart)) {
            let tokens = part.tokens
            var index: Int64 = 0
            while (index + 1 < tokens.size) {
                let kind = tokens[index].kind
                if ([TokenKind.CLASS, TokenKind.INTERFACE, TokenKind.STRUCT, TokenKind.TYPE].contains(kind)) {
                    index++
                    let token = tokens[index]
                    if (token.kind == TokenKind.IDENTIFIER && !upperCamelType(token.Value())) {
                        engine.findings.add(Finding(engine.path, token.Begin(), token.End(),
                            "G_NAM_03_identifier_naming_information", [token.Value()]))
                    }
                } else if (kind == TokenKind.ENUM) {
                    while (index + 1 < tokens.size && tokens[index].kind != TokenKind.RCURL) {
                        let previousIsFunction = tokens[index].kind == TokenKind.FUNC
                        index++
                        let token = tokens[index]
                        if (!previousIsFunction && token.kind == TokenKind.IDENTIFIER && !upperCamelType(token.Value())) {
                            engine.findings.add(Finding(engine.path, token.Begin(), token.End(),
                                "G_NAM_03_identifier_naming_information", [token.Value()]))
                        }
                    }
                }
                index++
            }
        }
    }
}

func checkResolvedTypeNames(engine: RuleEngine, root: Node): Unit {
    Walker(root, visitPre: { node: Node =>
        if (let Some(declaration) <- (node as ClassDecl)) {
            let name = declaration.identifier.Val()
            if (!name.endsWith("Error") && !name.endsWith("Exception") &&
                isExceptionClass(declaration, HashSet<Decl>())) {
                engine.emit(declaration, "G_NAM_03_exception_naming_information", [name])
            }
            diagnoseTypeName(engine, declaration)
            return VisitAction.SKIP_CHILDREN
        }
        if (let Some(declaration) <- (node as EnumDecl)) {
            for (constructor in declaration.constructors) { diagnoseTypeName(engine, constructor) }
            diagnoseTypeName(engine, declaration)
            return VisitAction.SKIP_CHILDREN
        }
        if ((node as InterfaceDecl).isSome() || (node as StructDecl).isSome() || (node as TypeAliasDecl).isSome()) {
            if (let Some(declaration) <- (node as Decl)) { diagnoseTypeName(engine, declaration) }
            return VisitAction.SKIP_CHILDREN
        }
        if (let Some(quotation) <- (node as QuoteExpr)) { checkQuotedTypeNames(engine, quotation) }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
