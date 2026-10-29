package cjlint

import cjcj::ast.*
import cjcj::utils.FileUtil
import std.collection.*

func checkFinally(engine: RuleEngine, root: Node): Unit {
    Walker(root, visitPre: { node: Node =>
        if (let Some(expr) <- (node as TryExpr)) {
            if (let Some(block) <- expr.finallyBlock) {
                for (item in block.body) {
                    Walker(item, visitPre: { subnode: Node =>
                        if (let Some(jump) <- (subnode as JumpExpr)) {
                            engine.emit(jump, if (jump.isBreak) { "G_ERR_04_avoid_break_finally" }
                                else { "G_ERR_04_avoid_continue_finally" }, [])
                            return VisitAction.SKIP_CHILDREN
                        }
                        if ((subnode as ReturnExpr).isSome()) {
                            engine.emit(subnode, "G_ERR_04_avoid_return_finally", [])
                            return VisitAction.SKIP_CHILDREN
                        }
                        if ((subnode as ThrowExpr).isSome()) {
                            engine.emit(subnode, "G_ERR_04_avoid_throw_finally", [])
                            return VisitAction.SKIP_CHILDREN
                        }
                        if ((subnode as WhileExpr).isSome() || (subnode as ForInExpr).isSome() ||
                            (subnode as DoWhileExpr).isSome() || (subnode as FuncDecl).isSome() ||
                            (subnode as LambdaExpr).isSome() || (subnode as TryExpr).isSome()) {
                            return VisitAction.SKIP_CHILDREN
                        }
                        return VisitAction.WALK_CHILDREN
                    }).Walk()
                }
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

func lowerPackageName(name: String): Bool {
    var value = name
    if (value.startsWith("_")) { value = value[1..] }
    if (value.isEmpty() || value[0] < b'a' || value[0] > b'z') { return false }
    for (c in value.toArray()) {
        if (!((c >= b'a' && c <= b'z') || (c >= b'0' && c <= b'9') || c == b'_')) { return false }
    }
    return true
}

func checkPackageName(engine: RuleEngine, file: File): Unit {
    if (let Some(pkg) <- file.packageSpec) {
        let full = pkg.GetPackageName()
        if (!lowerPackageName(pkg.packageName.Val())) {
            engine.findings.add(Finding(engine.path, pkg.packageName.Begin(), pkg.packageName.Begin(),
                "G_NAM_01_Package_Information", [full]))
        }
        if (pkg.prefixPaths.isEmpty() || (pkg.hasDoubleColon && pkg.prefixPaths.size == 1)) { return }
        let wanted = ArrayList<String>()
        for (index in 0..pkg.prefixPaths.size) {
            if (index != 0 || !pkg.hasDoubleColon) { wanted.add(pkg.prefixPaths[index]) }
        }
        wanted.add(pkg.packageName.Val())
        let segments = FileUtil.GetDirPath(engine.path).replace("\\", "/").split("/")
        var found = false
        for (start in 0..segments.size) {
            if (start + wanted.size > segments.size) { break }
            var same = true
            for (index in 0..wanted.size) { if (segments[start + index] != wanted[index]) { same = false } }
            if (same) { found = true; break }
        }
        if (!found) {
            engine.findings.add(Finding(engine.path, pkg.packageName.Begin(), pkg.packageName.End(),
                "G_NAM_01_Package_name_should_match_path", [full]))
        }
    }
}

func checkFileName(engine: RuleEngine, file: File): Unit {
    let name = file.fileName
    let stem = name[..name.size - 3]
    var valid = !stem.isEmpty()
    var hasLetter = false
    for (c in stem.toArray()) {
        if (c >= b'a' && c <= b'z') { hasLetter = true }
        else if (!((c >= b'0' && c <= b'9') || c == b'_')) { valid = false }
    }
    let point = Position(file.begin.fileID, 1, 1)
    if (!valid || !hasLetter) {
        engine.findings.add(Finding(engine.path, point, point, "G_NAM_02_filename_lower_information", [name]))
        return
    }
    var publicCount: Int64 = 0
    var publicName = ""
    for (decl in file.decls) {
        if (((decl as ClassDecl).isSome() || (decl as InterfaceDecl).isSome() || (decl as StructDecl).isSome()) &&
            hasModifier(decl, TokenKind.PUBLIC)) {
            publicCount++; publicName = decl.identifier.Val()
        }
    }
    if (publicCount == 1 && stem.replace("_", "") != publicName.toAsciiLower().replace("_", "")) {
        engine.findings.add(Finding(engine.path, point, point, "G_NAM_02_filename_standard_information", [name, publicName]))
    }
}

func containsCopyright(text: String): Bool {
    for (marker in ["Copyright", "版权所有"]) {
        if (let Some(index) <- text.indexOf(marker)) {
            if (text[index + marker.size..].trimAsciiStart().startsWith("(c)")) { return true }
        }
    }
    return false
}

func checkCopyright(engine: RuleEngine, file: File): Unit {
    var groups = file.comments.leadingComments
    if (groups.isEmpty()) {
        if (let Some(pkg) <- file.packageSpec) { groups = pkg.comments.leadingComments }
        else if (!file.imports.isEmpty() && !file.imports[0].begin.IsZero()) { groups = file.imports[0].comments.leadingComments }
        else if (!file.decls.isEmpty()) { groups = file.decls[0].comments.leadingComments }
        else { return }
    }
    if (groups.isEmpty() || groups[0].cms.isEmpty() || !containsCopyright(groups[0].cms[0].info.Value())) {
        engine.emit(file, "G_FMT_13_header_comments_copyright_01", [])
    } else {
        let block = match (groups[0].cms[0].kind) { case CommentKind.BLOCK => true; case _ => false }
        if (!block) { engine.emit(file, "G_FMT_13_header_comments_copyright_02", []) }
    }
}

func runSyntaxRules(engine: RuleEngine, file: File): Unit {
    if (engine.selected.contains("G.ERR.04")) { checkFinally(engine, file) }
    if (engine.selected.contains("G.NAM.01")) { checkPackageName(engine, file) }
    if (engine.selected.contains("G.NAM.02")) { checkFileName(engine, file) }
    if (engine.selected.contains("G.FMT.13")) { checkCopyright(engine, file) }
}
