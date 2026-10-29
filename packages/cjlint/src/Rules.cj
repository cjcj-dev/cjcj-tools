package cjlint

import cjcj::ast.*
import cjcj::basic.{Position, SourceManager}
import std.collection.*

// These are executable ports, not the reference obligation list. Rules enter this
// list only with a real implementation; the CLI rejects every missing rule.
let portedRuleIds: Array<String> = ["G.DCL.02", "G.NAM.04", "G.NAM.05", "G.VAR.03", "G.PKG.01",
    "G.ERR.04", "G.NAM.01", "G.NAM.02", "G.FMT.13", "G.FUN.01", "G.EXP.05", "G.FUN.02", "G.FMT.01", "G.ERR.01"]

func hasModifier(decl: Decl, modifier: TokenKind): Bool {
    for (item in decl.modifiers) { if (item.modifier == modifier) { return true } }
    return false
}

func validLowerCamel(name: String): Bool {
    let bytes = name.toArray()
    if (bytes.isEmpty() || bytes[0] < 97 || bytes[0] > 122) { return false }
    for (c in bytes) {
        if (!((c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57))) { return false }
    }
    return true
}

func validCapital(name: String): Bool {
    let bytes = name.toArray()
    if (bytes.isEmpty() || !((bytes[0] >= 65 && bytes[0] <= 90) || bytes[0] == 95)) { return false }
    for (c in bytes) {
        if (!((c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95)) { return false }
    }
    return true
}

class RuleEngine {
    let selected: HashSet<String>
    let findings: ArrayList<Finding>
    let path: String
    let sources: SourceManager
    let configRoot: String
    let fileID: UInt64
    init(selected: HashSet<String>, findings: ArrayList<Finding>, path: String, sources: SourceManager,
        fileID!: UInt64, configRoot!: String = "") {
        this.selected = selected; this.findings = findings; this.path = path
        this.sources = sources
        this.configRoot = configRoot
        this.fileID = fileID
    }
    func emit(node: Node, kind: String, args: Array<String>): Unit {
        findings.add(Finding(path, node.begin, node.end, kind, args))
    }
    func emitIdentifier(decl: Decl, kind: String): Unit {
        findings.add(Finding(path, decl.identifier.Begin(), decl.identifier.End(), kind, [decl.identifier.GetRawText()]))
    }
    func checkDeclarationTypes(root: Node): Unit {
        Walker(root, visitPre: { node: Node =>
            if (let Some(fn) <- (node as FuncDecl)) {
                if (!fn.IsFinalizer() && !fn.TestAttr(Attribute.CONSTRUCTOR) && !hasModifier(fn, TokenKind.OPERATOR) &&
                    hasModifier(fn, TokenKind.PUBLIC)) {
                    if (let Some(body) <- fn.funcBody) {
                        if (body.retType.isNone()) { emitIdentifier(fn, "G_DCL_02_public_function_type") }
                    }
                }
            } else if (let Some(variable) <- (node as VarDecl)) {
                if (variable.astKind == ASTKind.VAR_DECL) {
                    if (hasModifier(variable, TokenKind.PUBLIC) && variable.typeNode.isNone()) {
                        emitIdentifier(variable, "G_DCL_02_public_variable_type")
                    }
                    return VisitAction.SKIP_CHILDREN
                }
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
    }
    func checkFunctionNames(root: Node): Unit {
        Walker(root, visitPre: { node: Node =>
            if (let Some(fn) <- (node as FuncDecl)) {
                if (!fn.IsFinalizer() && fn.identifier != "__mainInvoke" && !fn.keywordPos.IsZero() &&
                    !hasModifier(fn, TokenKind.OPERATOR) && !hasModifier(fn, TokenKind.FOREIGN) &&
                    !validLowerCamel(fn.identifier.Val())) {
                    emit(fn, "G_NAM_04_function_naming_information", [fn.identifier.Val()])
                }
            } else if (let Some(_) <- (node as VarDecl)) { return VisitAction.SKIP_CHILDREN }
            return VisitAction.WALK_CHILDREN
        }).Walk()
    }
    func checkVariables(root: Node, immutableNames: Bool): Unit {
        Walker(root, visitPre: { node: Node =>
            if (let Some(variable) <- (node as VarDecl)) {
                if (immutableNames) {
                    if (!variable.isVar && (variable.TestAttr(Attribute.GLOBAL) || variable.TestAttr(Attribute.STATIC)) &&
                        !validCapital(variable.identifier.Val())) {
                        emit(variable, "G_NAM_05_immutable_global_variable_naming_information", [variable.identifier.Val()])
                    }
                } else {
                    if (variable.TestAttr(Attribute.GLOBAL) && !variable.isConst) {
                        emit(variable, "G_VAR_03_global_variable_declaration_information", [variable.identifier.Val()])
                    }
                    return VisitAction.SKIP_CHILDREN
                }
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
    }
    func prefix(content: ImportContent, trailing: Bool): String {
        var out = ""
        for (i in 0..content.prefixPaths.size) {
            if (i > 0) { out += if (i == 1 && content.hasDoubleColon) { "::" } else { "." } }
            out += content.prefixPaths[i]
        }
        if (trailing && !out.isEmpty()) { out += "." }
        return out
    }
    func checkImports(root: Node): Unit {
        Walker(root, visitPre: { node: Node =>
            if (let Some(spec) <- (node as ImportSpec)) {
                if (spec.importPos == INVALID_POSITION || spec.TestAttr(Attribute.COMPILER_ADD)) {
                    return VisitAction.WALK_CHILDREN
                }
                let content = spec.content
                if (content.kind == ImportKind.IMPORT_ALL) {
                    emit(content, "G_PKG_01_avoid_wildcard", [prefix(content, false)])
                } else if (content.kind == ImportKind.IMPORT_MULTI) {
                    for (item in content.items) {
                        if (item.kind == ImportKind.IMPORT_ALL) {
                            emit(item, "G_PKG_01_avoid_wildcard", [prefix(content, true) + prefix(item, false)])
                        }
                    }
                }
            }
            return VisitAction.WALK_CHILDREN
        }).Walk()
    }
    func runParse(file: File): Unit {
        if (selected.contains("G.SYN.01")) { checkRestrictedSyntax(this, file) }
        if (selected.contains("G.DCL.02")) { checkDeclarationTypes(file) }
    }
    func run(file: File): Unit {
        if (selected.contains("G.NAM.04")) { checkFunctionNames(file) }
        if (selected.contains("G.NAM.05")) { checkVariables(file, true) }
        if (selected.contains("G.VAR.03")) { checkVariables(file, false) }
        if (selected.contains("G.PKG.01")) { checkImports(file) }
        runSyntaxRules(this, file)
        if (selected.contains("G.FUN.01")) { checkSingleResponsibility(this, file) }
        if (selected.contains("G.EXP.05")) { checkExpressionParentheses(this, file) }
        if (selected.contains("G.FUN.02")) { checkUnusedParameters(this, file) }
        if (selected.contains("G.ERR.01")) { checkExceptionHandling(this, file) }
    }
}
