package cjlint

import cjcj::chir.*
import std.collection.*

func temporaryFile(path: String): Bool {
    let lower = path.toAsciiLower()
    return lower.contains("tmp") || lower.contains("temp") || lower.contains("temporary")
}

func fileOperation(expression: Expression): Option<(String, Bool, DebugLocation)> {
    if (let Some((callee, args)) <- flowCall(expression)) {
        let name = callee.GetSrcCodeIdentifier()
        if (let Some(function) <- (callee as Function)) {
            let packageName = function.GetPackageName()
            let create = (name == "init" && packageName == "std.fs") || (name == "creat" && packageName == "std.posix")
            let remove = name == "remove" && (packageName == "std.fs" || packageName == "std.os.posix")
            if (!create && !remove) { return None }
            let index = if (name == "init") { 1 } else { 0 }
            if (index >= args.size) { return None }
            let path = flowLiteral(args[index])
            if (!path.isEmpty() && temporaryFile(path)) { return (path, create, args[index].GetDebugLocation()) }
        }
    }
    return None
}

class TemporaryFileDomain <: GenKillDomain<TemporaryFileDomain> {
    init(size: Int64) { super(size) }
    public override func Clone(): TemporaryFileDomain {
        let result = TemporaryFileDomain(Size()); result.CopyBaseFrom(this); return result
    }
    public override func CopyFrom(other: TemporaryFileDomain): Unit { CopyBaseFrom(other) }
    public override func Join(other: TemporaryFileDomain): Bool { return JoinStates(other, AnalysisKind.MAYBE) }
}

class TemporaryFileAnalysis <: Analysis<TemporaryFileDomain> {
    let indexes = HashMap<String, Int64>()
    let initial: ArrayList<String>
    init(function: Function, initial: ArrayList<String>) {
        super(function); this.initial = initial
        for (path in initial) { if (!indexes.contains(path)) { indexes[path] = indexes.size } }
        if (let Some(body) <- function.GetBody()) {
            walkFlow(body, { expression: Expression =>
                if (let Some((path, create, _)) <- fileOperation(expression)) {
                    if (create && !indexes.contains(path)) { indexes[path] = indexes.size }
                }
            })
        }
    }
    public override func Bottom(): TemporaryFileDomain { return TemporaryFileDomain(indexes.size) }
    public override func InitializeFuncEntryState(state: TemporaryFileDomain): Unit {
        state.SetReachable(true)
        for (path in initial) { state.Gen(indexes[path]) }
    }
    public override func PropagateExpressionEffect(state: TemporaryFileDomain, expression: Expression): Unit {
        if (let Some((path, create, _)) <- fileOperation(expression)) {
            if (let Some(index) <- indexes.get(path)) { if (create) { state.Gen(index) } else { state.Kill(index) } }
        }
    }
    public override func PropagateTerminatorEffect(state: TemporaryFileDomain, expression: Expression): Option<Block> {
        PropagateExpressionEffect(state, expression); return None
    }
}

func temporaryFileLocations(function: Function): HashMap<String, DebugLocation> {
    let locations = HashMap<String, DebugLocation>()
    if (let Some(body) <- function.GetBody()) {
        walkFlow(body, { expression: Expression =>
            if (let Some((path, create, location)) <- fileOperation(expression)) {
                if (create && !locations.contains(path)) { locations[path] = location }
            }
        })
    }
    return locations
}

func temporaryFilesAtExit(function: Function, initial: ArrayList<String>, action: (String, Expression) -> Unit): Unit {
    let analysis = TemporaryFileAnalysis(function, initial)
    let result = Engine<TemporaryFileDomain>(function, analysis).IterateToFixpoint().getOrThrow()
    result.VisitWith({ _: TemporaryFileDomain, _: Expression, _: Int64 => },
        { _: TemporaryFileDomain, _: Expression, _: Int64 => },
        { state: TemporaryFileDomain, expression: Expression, _: Option<Block> =>
            if (expression.GetExprKind() == ExprKind.EXIT) {
                for ((path, index) in analysis.indexes) { if (state.IsTrueAt(index)) { action(path, expression) } }
            }
        })
}

func checkTemporaryFiles(findings: ArrayList<Finding>, pkg: Package): Unit {
    let defaults = HashMap<String, ArrayList<String>>()
    let positions = HashMap<String, HashMap<String, DebugLocation>>()
    let functions = pkg.GetGlobalFuncsWithBody(includeSrcCodeImported: false)
    for (function in functions) {
        if (function.GetFuncKind() != FuncKind.DEFAULT_PARAMETER_FUNC) { continue }
        let host = function.GetParamDftValHostFunc().getOrThrow().GetIdentifier()
        if (!defaults.contains(host)) { defaults[host] = ArrayList<String>(); positions[host] = HashMap<String, DebugLocation>() }
        temporaryFilesAtExit(function, ArrayList<String>(), { path: String, _: Expression => defaults[host].add(path) })
        for ((path, location) in temporaryFileLocations(function)) { positions[host][path] = location }
    }
    for (function in functions) {
        if (function.GetFuncKind() == FuncKind.DEFAULT_PARAMETER_FUNC || function.GetIdentifier().startsWith("@_CGV") || flowGeneric(function)) { continue }
        let name = function.GetIdentifier()
        let initial = defaults.get(name) ?? ArrayList<String>()
        let locations = positions.get(name) ?? HashMap<String, DebugLocation>()
        for ((path, location) in temporaryFileLocations(function)) { if (!locations.contains(path)) { locations[path] = location } }
        temporaryFilesAtExit(function, initial, { path: String, expression: Expression =>
            let location = expression.GetDebugLocation()
            if (location.GetBeginPos().IsZero()) { flowEmit(findings, locations[path], "G_FIO_01_compile_add_return", [path]) }
            else { flowEmit(findings, locations[path], "G_FIO_01", [path, location.GetBeginPos().line.toString(), location.GetBeginPos().column.toString()]) }
        })
    }
}
