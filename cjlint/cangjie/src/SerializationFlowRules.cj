package cjlint

import cjcj::chir.*
import std.collection.*

func flowDetailedType(input: Type): String {
    let ty = flowBaseType(input)
    if (let Some(custom) <- (ty as CustomType)) {
        let prefix = if (ty is ClassType) { "Class-" } else if (ty is StructType) { "Struct-" } else if (ty is EnumType) { "Enum-" } else { "" }
        var name = prefix + custom.GetCustomTypeDef().GetSrcCodeIdentifier()
        let args = custom.GetTypeArgs()
        for (index in 0..args.size) { name += (if (index == 0) { "<" } else { ", " }) + flowDetailedType(args[index]) }
        if (!args.isEmpty()) { name += ">" }
        return name
    }
    return ty.ToString()
}

func flowValueExpression(value: Value): Option<Expression> {
    if (let Some(local) <- (value as LocalVar)) { return local.GetExpr() }
    return None
}

func flowMemberName(value: Value): String {
    if (!value.GetSrcCodeIdentifier().isEmpty()) { return value.GetSrcCodeIdentifier() }
    if (let Some(expression) <- flowValueExpression(value)) {
        if (let Some(element) <- (expression as GetElementRef)) {
            var result = ""
            if (let Some(ty) <- element.GetLocation().GetType()) {
                var current = flowBaseType(ty)
                for (index in element.GetPath()) {
                    if (let Some(custom) <- (current as CustomType)) {
                        let member = custom.GetCustomTypeDef().GetInstanceVar(Int64(index))
                        result += (if (result.isEmpty()) { "" } else { "." }) + member.name
                        current = flowBaseType(member.ty)
                    } else { return result }
                }
            }
            return result
        }
    }
    return ""
}

class SerialTypeInfo {
    let name: String; let location: DebugLocation
    init(name: String, location: DebugLocation) { this.name = name; this.location = location }
}

class SerializationFlowCheck {
    let findings: ArrayList<Finding>
    let types = ArrayList<SerialTypeInfo>()
    let returnedFields = HashMap<String, ArrayList<SerialTypeInfo>>()
    let fields = HashMap<String, ArrayList<SerialTypeInfo>>()
    let visited = HashSet<Int64>()
    let location: DebugLocation
    init(findings: ArrayList<Finding>, location: DebugLocation) { this.findings = findings; this.location = location }
    func serializeInfo(expression: Expression, field: Bool): Option<SerialTypeInfo> {
        if (let Some((callee, args)) <- flowCall(expression)) {
            if (FlowFunctionSpec("serialize", "NOT_CARE", ["NOT_CARE"], "DataModel", "NOT_CARE", 0).matches(callee) && !args.isEmpty()) {
                let signature = (callee.GetType().getOrThrow() as FuncType).getOrThrow()
                var pos = expression.GetDebugLocation()
                if (field) {
                    if (let Some(argExpression) <- flowValueExpression(args[0])) {
                        pos = argExpression.GetDebugLocation()
                        if (let Some(load) <- (argExpression as Load)) {
                            if (let Some(inner) <- flowValueExpression(load.GetLocation())) { pos = inner.GetDebugLocation() }
                        }
                    }
                }
                return SerialTypeInfo(flowDetailedType(signature.GetParamTypes()[0]), pos)
            }
        }
        return None
    }
    func add(map: HashMap<String, ArrayList<SerialTypeInfo>>, key: String, info: SerialTypeInfo): Unit {
        if (!map.contains(key)) { map[key] = ArrayList<SerialTypeInfo>() }; map[key].add(info)
    }
    func collect(expression: Expression): Unit {
        if (let Some(store) <- (expression as Store)) {
            if (let Some(target) <- (store.GetLocation() as LocalVar)) {
                if (target.IsRetValue()) {
                    if (let Some(call) <- flowValueExpression(store.GetValue())) {
                        if (let Some(info) <- serializeInfo(call, false)) {
                            types.add(info)
                            let args = flowCall(call).getOrThrow()[1]
                            var argument = flowValueExpression(args[0])
                            if (let Some(argumentExpr) <- argument) {
                                if (let Some(cast) <- (argumentExpr as TypeCast)) { argument = flowValueExpression(cast.GetSourceValue()) }
                            }
                            if (let Some(expr) <- argument) {
                                if (let Some(load) <- (expr as Load)) { add(returnedFields, flowMemberName(load.GetLocation()), info) }
                            }
                        }
                    }
                    return
                }
            }
        }
        if (let Some((callee, args)) <- flowCall(expression)) {
            if (FlowFunctionSpec("init", "NOT_CARE", ["Field", "String", "DataModel"], "Field", "stdx.serialization.serialization", 0).matches(callee) && args.size == 3) {
                let key = flowLiteral(args[1])
                if (!key.isEmpty()) {
                    if (let Some(serialized) <- flowValueExpression(args[2])) {
                        if (let Some(info) <- serializeInfo(serialized, true)) { add(fields, key, info) }
                    }
                }
            } else if (FlowFunctionSpec("add", "NOT_CARE", ["DataModelStruct", "Field"], "DataModelStruct", "stdx.serialization.serialization", 0).matches(callee) && args.size == 2) {
                if (let Some(fieldExpr) <- flowValueExpression(args[1])) {
                    if (let Some((_, fieldArgs)) <- flowCall(fieldExpr)) {
                        if (fieldArgs.size < 2) { return }
                        let key = flowLiteral(fieldArgs[0])
                        if (!key.isEmpty()) {
                            if (let Some(data) <- flowValueExpression(fieldArgs[1])) {
                                if (let Some(load) <- (data as Load)) {
                                    add(fields, key, SerialTypeInfo(flowDetailedType(load.GetLocation().GetType().getOrThrow()), expression.GetDebugLocation()))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    func joinInfos(infos: ArrayList<SerialTypeInfo>, dataModel!: Bool = false): String {
        var text = ""
        for (index in 0..infos.size) {
            let info = infos[index]
            if (index > 0) { text += if (index == infos.size - 1) { " or " } else { ", " } }
            text += "'" + (if (dataModel) { "DataModel" + info.name } else { info.name }) + "'(line ${info.location.GetBeginPos().line})"
        }
        return text
    }
    func hasType(infos: ArrayList<SerialTypeInfo>, name: String): Bool {
        for (info in infos) { if (info.name == name) { return true } }; return false
    }
    func check(expression: Expression): Unit {
        if (let Some((callee, args)) <- flowCall(expression)) {
            if (!FlowFunctionSpec("deserialize", "NOT_CARE", ["DataModel"], "NOT_CARE", "NOT_CARE", 0).matches(callee) || args.isEmpty()) {
                if (let Some(function) <- (callee as Function)) {
                    if (!visited.contains(function.nodeId)) {
                        visited.add(function.nodeId)
                        if (let Some(body) <- function.GetBody()) { walkFlow(body, { nested => check(nested) }) }
                    }
                }
                return
            }
            let result = expression.GetResult().getOrThrow().GetType().getOrThrow()
            let name = flowDetailedType(result)
            let description = "'" + name + "'(line ${expression.GetDebugLocation().GetBeginPos().line})"
            if (let Some(arg) <- flowValueExpression(args[0])) {
                if (let Some((get, getArgs)) <- flowCall(arg)) {
                    if (FlowFunctionSpec("get", "DataModelStruct", ["DataModelStruct", "String"], "DataModel", "stdx.serialization.serialization", 0).matches(get) && getArgs.size == 2) {
                        let key = flowLiteral(getArgs[1])
                        if (!key.isEmpty()) {
                            let fieldTypes = fields.get(key) ?? ArrayList<SerialTypeInfo>()
                            let returnTypes = returnedFields.get(key) ?? ArrayList<SerialTypeInfo>()
                            if (fieldTypes.isEmpty() && !returnTypes.isEmpty()) {
                                flowEmit(findings, location, "G_SER_03_return_error", [key, description, joinInfos(returnTypes, dataModel: true)])
                            } else if (fieldTypes.isEmpty()) {
                                flowEmit(findings, location, "G_SER_03_key_lack", [key, description, key])
                            } else if (!hasType(fieldTypes, name)) {
                                flowEmit(findings, location, "G_SER_03_type_error", [key, description, joinInfos(fieldTypes)])
                            }
                        }
                    }
                }
            }
            if (!types.isEmpty() && !hasType(types, name)) {
                flowEmit(findings, location, "G_SER_03_type_lack", [name, "${expression.GetDebugLocation().GetBeginPos().line}", joinInfos(types)])
            }
        }
    }
}

func checkSerializationFlow(findings: ArrayList<Finding>, pkg: Package): Unit {
    let definitions = ArrayList<CustomTypeDef>()
    for (definition in pkg.GetClasses()) { definitions.add(definition) }
    for (definition in pkg.GetStructs()) { definitions.add(definition) }
    for (definition in definitions) {
        if (definition.TestAttr(Attribute.GENERIC_INSTANTIATED) || !flowSubtype(definition, "Serializable", "stdx.serialization.serialization", HashSet<Int64>())) { continue }
        var serialize: Option<Function> = None; var deserialize: Option<Function> = None
        let name = definition.GetSrcCodeIdentifier()
        for (method in definition.GetMethods()) {
            if (let Some(function) <- (method as Function)) {
                if (FlowFunctionSpec("serialize", name, [name], "DataModel", "NOT_CARE", 0).matches(function)) { serialize = function }
                if (FlowFunctionSpec("deserialize", name, ["DataModel"], name, "NOT_CARE", 0).matches(function)) { deserialize = function }
            }
        }
        if (let Some(serial) <- serialize) {
            if (let Some(deserial) <- deserialize) {
                let check = SerializationFlowCheck(findings, deserial.GetDebugLocation())
                if (let Some(body) <- serial.GetBody()) { walkFlow(body, { expression => check.collect(expression) }) }
                check.visited.add(deserial.nodeId)
                if (let Some(body) <- deserial.GetBody()) { walkFlow(body, { expression => check.check(expression) }) }
            }
        }
    }
}
