package cjlint

import cjcj::ast.*
import cjcj::sema.TypeManager

// Implemented against the frontend's resolved types. These rules remain outside
// portedRuleIds until the real semantic pipeline is installed and exercised.
let resolvedTypeRuleIds = ["G.FMT.15", "G.EXP.06", "G.TYP.03", "FFI.C.7", "G.ITF.04", "G.NAM.06", "G.OPR.02",
    "G.ERR.03", "G.CON.01", "G.NAM.03", "G.ENU.01", "G.ENU.02", "G.EXP.01", "G.FUN.03",
    "G.ITF.01", "G.ITF.02", "G.ITF.03", "G.OTH.04", "G.SEC.01", "G.ERR.02", "G.OTH.02", "G.EXP.07", "G.OTH.03", "G.CLS.01", "G.OPR.01", "G.SER.01", "G.SER.02", "G.SYN.01", "G.VAR.02", "G.EXP.04", "G.EXP.02", "G.DCL.01", "G.CON.02", "G.CON.03", "P.03", "G.CHK.04", "G.EXP.03", "P.01", "G.CHK.02"]

func parameterCamel(name: String): Bool {
    if (name.size < 2 || name[0] < b'a' || name[0] > b'z') { return false }
    for (byte in name.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z'))) { return false }
    }
    return true
}

func checkResolvedNames(engine: RuleEngine, node: Node): Unit {
    if (let Some(property) <- (node as PropDecl)) {
        if (!parameterCamel(property.identifier.Val())) { engine.emitIdentifier(property, "G_NAM_06_propertie_camelCase_name") }
    } else if (let Some(parameter) <- (node as FuncParam)) {
        if (!parameterCamel(parameter.identifier.Val())) { engine.emitIdentifier(parameter, "G_NAM_06_parameter_camelCase_name") }
    } else if (let Some(variable) <- (node as VarDecl)) {
        if (!variable.isVar) {
            if (let Some(ty) <- variable.GetTy()) {
                if (ty.IsFloating() || ty.IsInteger()) { return }
            }
        }
        if (!parameterCamel(variable.identifier.Val())) { engine.emitIdentifier(variable, "G_NAM_06_var_camelCase_name") }
    } else if (let Some(generic) <- (node as GenericParamDecl)) {
        for (byte in generic.identifier.Val().toArray()) {
            if (byte >= b'a' && byte <= b'z') {
                engine.emitIdentifier(generic, "G_NAM_06_generic_type_parameters")
                break
            }
        }
    }
}

func checkResolvedLiteral(engine: RuleEngine, literal: LitConstExpr): Unit {
    if (let Some(ty) <- literal.GetTy()) {
        if (ty.IsFloating()) {
            let parts = literal.rawString.split(".")
            if (parts.size == 1 || (parts.size > 1 && parts[0] == "-")) {
                engine.emit(literal, "G_FMT_15_leading_zero_before_decimal", [literal.rawString])
            }
        }
    }
}

func checkResolvedBinary(engine: RuleEngine, binary: BinaryExpr): Unit {
    if (binary.op != TokenKind.EQUAL && binary.op != TokenKind.NOTEQ) { return }
    if (let Some(left) <- binary.leftExpr) {
        if (let Some(right) <- binary.rightExpr) {
            if (let Some(leftType) <- left.GetTy()) {
                if (let Some(rightType) <- right.GetTy()) {
                    if (engine.selected.contains("G.EXP.06") && leftType.IsBoolean() && rightType.IsBoolean() &&
                        ((left as LitConstExpr).isSome() || (right as LitConstExpr).isSome())) {
                        engine.findings.add(Finding(engine.path, binary.operatorPos, binary.operatorPos + 2,
                            "G_EXP_06_avoid_redundant_op_in_bool_type_comparisons", []))
                    }
                    if (engine.selected.contains("G.TYP.03") && (leftType.IsFloating() || rightType.IsFloating())) {
                        if (let Some(member) <- (left as MemberAccess)) {
                            if (member.field == "NaN") { engine.emit(right, "G_TYP_03_use_isNaN_method_float", []) }
                        }
                        if (let Some(member) <- (right as MemberAccess)) {
                            if (member.field == "NaN") { engine.emit(left, "G_TYP_03_use_isNaN_method_float", []) }
                        }
                    }
                }
            }
        }
    }
}

func checkResolvedPointer(engine: RuleEngine, pointer: PointerExpr): Unit {
    if (let Some(toType) <- pointer.GetTy()) {
        if (let Some(argument) <- pointer.arg) {
            if (let Some(fromType) <- argument.GetTy()) {
                if (!toType.typeArgs.isEmpty() && !fromType.typeArgs.isEmpty() &&
                    toType.typeArgs[0].kind != fromType.typeArgs[0].kind) {
                    engine.emit(pointer, "FFI_C_7_avoid_truncation_error", [""])
                }
            }
        }
    }
}

func checkResolvedInterfaceTypes(engine: RuleEngine, function: FuncDecl): Unit {
    if (let Some(body) <- function.funcBody) {
        if (let Some(ty) <- function.GetTy()) {
            if (let Some(functionType) <- (ty as FuncTy)) {
                if (functionType.retTy.IsInterface()) {
                    engine.emit(function, "G_ITF_04_avoid_directly_using_interfaces_as_types_02", [function.identifier.Val()])
                }
            }
        }
        for (list in body.paramLists) {
            for (parameter in list.params) {
                if (let Some(ty) <- parameter.GetTy()) {
                    if (ty.IsInterface()) {
                        engine.emit(parameter, "G_ITF_04_avoid_directly_using_interfaces_as_types_01", [parameter.identifier.Val()])
                    }
                }
            }
        }
    }
}

func checkEnumCallOperator(engine: RuleEngine, declaration: Decl): Unit {
    var enumeration = (declaration as EnumDecl).isSome()
    if ((declaration as ExtendDecl).isSome()) {
        if (let Some(ty) <- declaration.GetTy()) { enumeration = ty.kind == TypeKind.TYPE_ENUM }
    }
    if (!enumeration) { return }
    for (member in declaration.GetMemberDecls()) {
        if ((member as FuncDecl).isSome() && member.TestAttr(Attribute.OPERATOR) && member.identifier.Val() == "()") {
            engine.emit(member, "G_OPR_02_enum_parentheses_overload_information", [member.identifier.Val()])
        }
    }
}

func runResolvedTypeRules(engine: RuleEngine, root: Node, manager: TypeManager): Unit {
    if (engine.selected.contains("G.SYN.01")) { checkRestrictedPrimitiveTypes(engine, root) }
    if (engine.selected.contains("G.VAR.02")) { checkMinimumScope(engine, root) }
    if (engine.selected.contains("G.EXP.04")) { checkEvaluationOrder(engine, root) }
    if (engine.selected.contains("G.EXP.02")) { checkFloatAccuracy(engine, root) }
    if (engine.selected.contains("G.DCL.01")) { checkShadows(engine, root) }
    if (engine.selected.contains("G.CON.02")) { checkTryLocks(engine, root) }
    if (engine.selected.contains("G.CON.03")) { checkThreadSafeOverrides(engine, root) }
    if (engine.selected.contains("P.03")) { checkDefensiveCopies(engine, root) }
    if (engine.selected.contains("G.CHK.04")) { checkRegexInputs(engine, root) }
    if (engine.selected.contains("G.EXP.03")) { ShortCircuitCheck(engine).run(root) }
    if (engine.selected.contains("G.CHK.02")) { LogInputCheck(engine).run(root) }
    runSerializationRules(engine, root)
    runClassOperatorRules(engine, root)
    runInterfaceRules(engine, root, manager)
    runSecurityRules(engine, root)
    if (engine.selected.contains("G.EXP.07")) { checkConstantComparisons(engine, root) }
    if (engine.selected.contains("G.OTH.03")) { checkHardcodedAddresses(engine, root) }
    if (let Some(file) <- (root as File)) {
        if (engine.selected.contains("G.ENU.01")) { checkEnumDeclarationNames(engine, file) }
        if (engine.selected.contains("G.ENU.02")) { checkEnumOverloads(engine, file) }
        if (engine.selected.contains("G.FUN.03")) { checkFunctionOverloads(engine, file) }
    }
    if (engine.selected.contains("G.EXP.01")) { checkMatchPatterns(engine, root) }
    if (engine.selected.contains("G.ERR.03")) { checkOptionThrows(engine, root, false) }
    if (engine.selected.contains("G.CON.01")) { checkMutexVisibility(engine, root) }
    if (engine.selected.contains("G.NAM.03")) { checkResolvedTypeNames(engine, root) }
    Walker(root, visitPre: { node: Node =>
        if (engine.selected.contains("G.NAM.06")) { checkResolvedNames(engine, node) }
        if (engine.selected.contains("G.FMT.15")) {
            if (let Some(literal) <- (node as LitConstExpr)) { checkResolvedLiteral(engine, literal) }
        }
        if (let Some(binary) <- (node as BinaryExpr)) { checkResolvedBinary(engine, binary) }
        if (engine.selected.contains("FFI.C.7")) {
            if (let Some(pointer) <- (node as PointerExpr)) { checkResolvedPointer(engine, pointer) }
        }
        if (engine.selected.contains("G.ITF.04")) {
            if (let Some(function) <- (node as FuncDecl)) { checkResolvedInterfaceTypes(engine, function) }
        }
        if (engine.selected.contains("G.OPR.02")) {
            if (let Some(declaration) <- (node as Decl)) { checkEnumCallOperator(engine, declaration) }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
