package cjlint

import cjcj::ast.*
import cjcj::ast.AnnotationKind as AstAnnotationKind
import std.collection.*

func restrictedSyntaxName(key: String): String {
    match (key) {
        case "Import" => "import package"
        case "Let" => "let variable"
        case "Spawn" => "spawn"
        case "Synchronized" => "synchronized"
        case "Main" => "main function"
        case "MacroQuote" => "macro definition"
        case "Foreign" => "cross-language"
        case "While" => "while loop"
        case "Extend" => "extend"
        case "Type" => "type alias"
        case "Operator" => "operator overloading"
        case "GlobalVariable" => "global variable"
        case "Enum" => "enum definition"
        case "Class" => "class definition"
        case "Struct" => "struct definition"
        case "Interface" => "interface definition"
        case "Generic" => "generic definition"
        case "When" => "conditional compilation"
        case "Match" => "pattern matching"
        case "TryCatch" => "catch exceptions"
        case "HigherOrderFunc" => "higher order function"
        case _ => ""
    }
}

func restrictedNodeKeyword(node: Node): String {
    match (node.astKind) {
        case ASTKind.IMPORT_SPEC => "Import"
        case ASTKind.LET_PATTERN_DESTRUCTOR => "Let"
        case ASTKind.SPAWN_EXPR => "Spawn"
        case ASTKind.SYNCHRONIZED_EXPR => "Synchronized"
        case ASTKind.MAIN_DECL => "Main"
        case ASTKind.MACRO_DECL => "MacroQuote"
        case ASTKind.WHILE_EXPR | ASTKind.DO_WHILE_EXPR => "While"
        case ASTKind.EXTEND_DECL => "Extend"
        case ASTKind.TYPE_ALIAS_DECL => "Type"
        case ASTKind.ENUM_DECL => "Enum"
        case ASTKind.CLASS_DECL => "Class"
        case ASTKind.INTERFACE_DECL => "Interface"
        case ASTKind.STRUCT_DECL => "Struct"
        case ASTKind.MATCH_EXPR => "Match"
        case ASTKind.TRY_EXPR => "TryCatch"
        case _ => ""
    }
}

func emitRestrictedSyntax(engine: RuleEngine, selected: HashSet<String>, node: Node, key: String): Unit {
    if (selected.contains(key)) {
        engine.emit(node, "G_SYN_01_disable_syntax_information_01", [restrictedSyntaxName(key)])
    }
}

func checkRestrictedSyntax(engine: RuleEngine, root: Node): Unit {
    let selected = HashSet<String>()
    for (keyword in settingStrings(ruleSettings(engine, "G_SYN_01"), "SyntaxKeyword")) {
        if (restrictedSyntaxName(keyword).isEmpty() && keyword != "PrimitiveType" && keyword != "ContainerType") {
            println("This syntax check '" + keyword + "' is not supported, please check whether the keyword is spelled correctly.")
        } else { selected.add(keyword) }
    }
    Walker(root, visitPre: { node: Node =>
        emitRestrictedSyntax(engine, selected, node, restrictedNodeKeyword(node))
        if (let Some(variable) <- (node as VarDecl)) {
            // The reference dispatches only VAR_DECL, not parameters/patterns.
            if (variable.astKind == ASTKind.VAR_DECL) {
                if (!variable.keywordPos.IsZero() && !variable.isVar && !variable.isConst) {
                    emitRestrictedSyntax(engine, selected, variable, "Let")
                }
                if (variable.TestAttr(Attribute.GLOBAL)) { emitRestrictedSyntax(engine, selected, variable, "GlobalVariable") }
            }
        }
        if (let Some(function) <- (node as FuncDecl)) {
            if (function.astKind == ASTKind.FUNC_DECL) {
                if (function.TestAttr(Attribute.OPERATOR)) { emitRestrictedSyntax(engine, selected, function, "Operator") }
                if (hasModifier(function, TokenKind.FOREIGN)) { emitRestrictedSyntax(engine, selected, function, "Foreign") }
                if (let Some(body) <- function.funcBody) {
                    if (!body.paramLists.isEmpty()) {
                        for (parameter in body.paramLists[0].params) {
                            if (let Some(ty) <- parameter.typeNode) {
                                if ((ty as FuncType).isSome()) { emitRestrictedSyntax(engine, selected, parameter, "HigherOrderFunc") }
                            }
                        }
                    }
                    if (let Some(ty) <- body.retType) {
                        if ((ty as FuncType).isSome()) { emitRestrictedSyntax(engine, selected, ty, "HigherOrderFunc") }
                    }
                }
            }
        }
        if (let Some(block) <- (node as Block)) {
            if (block.TestAttr(Attribute.UNSAFE)) { emitRestrictedSyntax(engine, selected, block, "Foreign") }
        }
        if (let Some(declaration) <- (node as Decl)) {
            if (let Some(generic) <- declaration.generic) {
                if (!generic.typeParameters.isEmpty()) { emitRestrictedSyntax(engine, selected, declaration, "Generic") }
            }
            for (annotation in declaration.annotations) {
                if (annotation.kind == AstAnnotationKind.WHEN) { emitRestrictedSyntax(engine, selected, declaration, "When"); break }
            }
        }
        if (let Some(body) <- (node as FuncBody)) {
            if (let Some(generic) <- body.generic) {
                if (!generic.typeParameters.isEmpty()) { emitRestrictedSyntax(engine, selected, body, "Generic") }
            }
        }
        if (selected.contains("ContainerType")) {
            var name = ""
            if (let Some(reference) <- (node as RefExpr)) { name = reference.ref.identifier.Val() }
            if (let Some(reference) <- (node as RefType)) { name = reference.ref.identifier.Val() }
            if (["TreeMap", "HashMap", "HashSet", "ArrayList"].contains(name)) {
                engine.emit(node, "G_SYN_01_disable_syntax_information_03", [name])
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

func checkRestrictedPrimitiveTypes(engine: RuleEngine, root: Node): Unit {
    if (!settingStrings(ruleSettings(engine, "G_SYN_01"), "SyntaxKeyword").contains("PrimitiveType")) { return }
    Walker(root, visitPre: { node: Node =>
        if (let Some(ty) <- node.GetTy()) {
            if (ty.IsPrimitive() && ![TypeKind.TYPE_BOOLEAN, TypeKind.TYPE_INT64, TypeKind.TYPE_FLOAT64,
                TypeKind.TYPE_UNIT, TypeKind.TYPE_NOTHING].contains(ty.kind)) {
                engine.emit(node, "G_SYN_01_disable_syntax_information_02", [ty.String()])
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
