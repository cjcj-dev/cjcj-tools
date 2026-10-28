package cjlint

import cjcj::ast.*
import cjcj::basic.Position
import cjcj::utils.FileUtil
import std.fs.File as SourceFile
import std.collection.*
import std.regex.{Regex, RegexFlag}

func ruleSettings(engine: RuleEngine, name: String): JsonValue {
    let settings = readJson(FileUtil.JoinPath(engine.configRoot, "config/structural_rule_" + name + ".json"))
    if (settings.kind != "object") { fail("Rule settings must be a JSON object: " + name) }
    return settings
}

func settingStrings(settings: JsonValue, name: String): Array<String> {
    let list = settings.field(name)
    if (list.kind != "array") { fail("Rule setting must be a string array: " + name) }
    let strings = ArrayList<String>()
    for (value in list.items) { strings.add(value.text()) }
    return strings.toArray()
}

func containsSetting(text: String, values: Array<String>): Bool {
    for (value in values) { if (text.contains(value)) { return true } }
    return false
}

func sensitiveStringType(ty: Ty, visited: HashSet<Ty>): Bool {
    if (visited.contains(ty)) { return false }
    visited.add(ty)
    if (ty.IsString()) { return true }
    if (!(ty.IsStructArray() || ty.IsCoreOptionType() || ty.IsTuple() || ty.kind == TypeKind.TYPE_CLASS)) { return false }
    for (argument in ty.typeArgs) { if (sensitiveStringType(argument, visited)) { return true } }
    return false
}

func checkSensitiveStorage(engine: RuleEngine, root: Node): Unit {
    let names = settingStrings(ruleSettings(engine, "G_OTH_04"), "SensitiveDataVar")
    Walker(root, visitPre: { node: Node =>
        if (let Some(variable) <- (node as VarDecl)) {
            if (containsSetting(variable.identifier.Val().toAsciiLower(), names)) {
                if (let Some(ty) <- variable.GetTy()) {
                    if (sensitiveStringType(ty, HashSet<Ty>())) {
                        engine.findings.add(Finding(engine.path, variable.identifier.Begin(), variable.identifier.End(),
                            "G_OTH_04_avoid_use_string_type_to_store_sensitive_data", [variable.identifier.Val()]))
                    }
                }
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

func checkSecurityMethod(engine: RuleEngine, function: FuncDecl, expressions: Array<Regex>): Unit {
    for (expression in expressions) {
        if (expression.matcher(function.identifier.Val()).fullMatch().isSome()) {
            engine.emitIdentifier(function, "G_SEC_01_open_check_function_information")
        }
    }
}

func checkOpenSecurityMethods(engine: RuleEngine, root: Node): Unit {
    let expressions = ArrayList<Regex>()
    for (pattern in settingStrings(ruleSettings(engine, "G_SEC_01"), "CheckingFunction")) {
        expressions.add(Regex(pattern, [RegexFlag.IgnoreCase]))
    }
    Walker(root, visitPre: { node: Node =>
        if (let Some(declaration) <- (node as ClassDecl)) {
            var extensible = hasModifier(declaration, TokenKind.OPEN)
            for (member in declaration.GetMemberDecls()) {
                if (hasModifier(member, TokenKind.OPEN)) { extensible = true }
            }
            for (member in declaration.GetMemberDecls()) {
                if (let Some(function) <- (member as FuncDecl)) {
                    for (modifier in function.modifiers) {
                        if (modifier.modifier == TokenKind.OPEN || (modifier.modifier == TokenKind.STATIC && extensible)) {
                            checkSecurityMethod(engine, function, expressions.toArray())
                        }
                    }
                }
            }
            return VisitAction.SKIP_CHILDREN
        }
        if (let Some(declaration) <- (node as InterfaceDecl)) {
            for (member in declaration.GetMemberDecls()) {
                if (let Some(function) <- (member as FuncDecl)) { checkSecurityMethod(engine, function, expressions.toArray()) }
            }
            return VisitAction.SKIP_CHILDREN
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

// Resolve text through AST initializers and the frontend's desugared string
// concatenation. Regular expressions apply only to configured payload matches.
func exceptionText(expression: Option<Expr>, visited: HashSet<Decl>): String {
    if (let Some(value) <- expression) {
        if (let Some(literal) <- (value as LitConstExpr)) { return literal.stringValue }
        if (let Some(reference) <- (value as RefExpr)) {
            if (let Some(target) <- reference.ref.target) {
                if (visited.contains(target)) { return "" }
                visited.add(target)
                if (let Some(variable) <- (target as VarDecl)) { return exceptionText(variable.initializer, visited) }
            }
        }
        if (let Some(binary) <- (value as BinaryExpr)) {
            if (let Some(desugared) <- binary.desugarExpr) {
                if (let Some(call) <- (desugared as CallExpr)) {
                    var text = ""
                    if (let Some(base) <- call.baseFunc) {
                        if (let Some(member) <- (base as MemberAccess)) {
                            if (member.field != "+") { return "" }
                            text = exceptionText(member.baseExpr, visited)
                        }
                    }
                    if (!call.args.isEmpty()) { text += exceptionText(call.args[0].expr, HashSet<Decl>()) }
                    return text
                }
            }
        }
    }
    return ""
}

func checkSensitiveExceptions(engine: RuleEngine, root: Node): Unit {
    let settings = ruleSettings(engine, "G_ERR_02")
    let sensitiveTypes = settingStrings(settings, "SensitiveException")
    let keywords = settingStrings(settings, "SensitiveKeyword")
    let emitted = HashSet<String>()
    Walker(root, visitPre: { node: Node =>
        if (let Some(thrown) <- (node as ThrowExpr)) {
            if (let Some(value) <- thrown.expr) {
                if (let Some(call) <- (value as CallExpr)) {
                    if (let Some(ty) <- call.GetTy()) {
                        let location = "${call.begin.fileID}:${call.begin.line}:${call.begin.column}"
                        if (sensitiveTypes.contains(ty.name) && !emitted.contains(location + ty.name)) {
                            emitted.add(location + ty.name)
                            engine.emit(call, "G_ERR_02_sensitive_exception", [ty.name])
                        }
                        if (call.args.size == 1) {
                            var argument = call.args[0].expr
                            if (let Some(desugared) <- call.desugarExpr) {
                                if (let Some(actual) <- (desugared as CallExpr)) {
                                    if (actual.args.isEmpty()) { return VisitAction.SKIP_CHILDREN }
                                    argument = actual.args[0].expr
                                }
                            }
                            let text = exceptionText(argument, HashSet<Decl>())
                            for (keyword in keywords) {
                                for (found in Regex("\\b" + keyword + "\\b", [RegexFlag.IgnoreCase]).findAll(text)) {
                                    let word = found.matchString(0)
                                    if (!emitted.contains(location + word)) {
                                        emitted.add(location + word)
                                        engine.emit(call, "G_ERR_02_sensitive_info", [word])
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return VisitAction.SKIP_CHILDREN
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}

func scanConfiguredText(engine: RuleEngine, expressions: Array<Regex>, kind: String): Unit {
    let lines = String.fromUtf8(SourceFile.readFrom(engine.path)).split("\n")
    for (index in 0..lines.size) {
        for (expression in expressions) {
            for (found in expression.findAll(lines[index])) {
                let location = found.matchPosition(0)
                let start = Position(engine.fileID, index + 1, location.start + 1)
                let finish = Position(engine.fileID, index + 1, location.end + 1)
                engine.findings.add(Finding(engine.path, start, finish, kind, [found.matchString(0)]))
            }
        }
    }
}

func checkHardcodedSecrets(engine: RuleEngine, root: Node): Unit {
    let settings = ruleSettings(engine, "G_OTH_02")
    let names = settingStrings(settings, "SenInfoName")
    let weak = settingStrings(settings, "WeakPasscode")
    Walker(root, visitPre: { node: Node =>
        if (let Some(variable) <- (node as VarDecl)) {
            if (variable.initializer.isSome() && containsSetting(variable.identifier.Val(), names)) {
                engine.emit(variable, "G_OTH_02_hardcode_sensitivename_information", [variable.identifier.Val()])
            }
        } else if (let Some(patterned) <- (node as VarWithPatternDecl)) {
            if (patterned.initializer.isSome()) {
                if (let Some(pattern) <- patterned.irrefutablePattern) {
                    Walker(pattern, visitPre: { nested: Node =>
                        if (let Some(binding) <- (nested as VarPattern)) {
                            if (let Some(variable) <- binding.varDecl) {
                                if (containsSetting(variable.identifier.Val(), names)) {
                                    engine.emit(variable, "G_OTH_02_hardcode_sensitivename_information", [variable.identifier.Val()])
                                }
                            }
                        }
                        return VisitAction.WALK_CHILDREN
                    }).Walk()
                }
            }
        } else if (let Some(literal) <- (node as LitConstExpr)) {
            if (containsSetting(literal.ToString(), weak)) {
                engine.emit(literal, "G_OTH_02_hardcode_weakpasscode_information", [literal.ToString()])
            }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
    let expressions = ArrayList<Regex>()
    for (pattern in settingStrings(settings, "RegexSet")) {
        try { expressions.add(Regex(pattern)) } catch (_: Exception) { continue }
    }
    scanConfiguredText(engine, expressions.toArray(), "G_OTH_02_hardcode_sensitive_information")
}

func runSecurityRules(engine: RuleEngine, root: Node): Unit {
    if (engine.selected.contains("G.OTH.04")) { checkSensitiveStorage(engine, root) }
    if (engine.selected.contains("G.SEC.01")) { checkOpenSecurityMethods(engine, root) }
    if (engine.selected.contains("G.ERR.02")) { checkSensitiveExceptions(engine, root) }
    if (engine.selected.contains("G.OTH.02")) { checkHardcodedSecrets(engine, root) }
}
