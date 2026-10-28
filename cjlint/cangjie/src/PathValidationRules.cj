package cjlint

import cjcj::chir.*
import std.collection.*

func pathDebug(debug: Debug): Bool {
    let ty = flowBaseType(debug.GetValue().GetType().getOrThrow())
    if (let Some(structure) <- (ty as StructType)) { return structure.GetCustomTypeDef().GetSrcCodeIdentifier() == "Path" }
    return false
}

class PathValidationAnalysis <: Analysis<TemporaryFileDomain> {
    let indexes = HashMap<String, Int64>()
    let settings: JsonValue
    let canonicalize: Bool
    init(function: Function, settings: JsonValue, canonicalize: Bool) {
        super(function); this.settings = settings; this.canonicalize = canonicalize
        if (let Some(body) <- function.GetBody()) {
            for (block in body.GetBlocks()) {
                for (expression in block.GetExpressions()) {
                    if (let Some(debug) <- (expression as Debug)) {
                        if (pathDebug(debug) && !indexes.contains(debug.GetSrcCodeIdentifier())) { indexes[debug.GetSrcCodeIdentifier()] = indexes.size }
                    }
                }
            }
        }
    }
    public override func Bottom(): TemporaryFileDomain { return TemporaryFileDomain(indexes.size) }
    public override func InitializeFuncEntryState(state: TemporaryFileDomain): Unit { state.SetReachable(true); state.GenAll() }
    func transfer(state: TemporaryFileDomain, from: Option<Debug>, to: Option<Debug>): Unit {
        if (let Some(source) <- from) {
            if (let Some(destination) <- to) {
                if (let Some(a) <- indexes.get(source.GetSrcCodeIdentifier())) {
                    if (let Some(b) <- indexes.get(destination.GetSrcCodeIdentifier())) { state.PropagateFrom(a, b) }
                }
            }
        }
    }
    public override func PropagateExpressionEffect(state: TemporaryFileDomain, expression: Expression): Unit {
        if (let Some(call) <- (expression as Apply)) {
            if (canonicalize && flowFunctionMatches(call.GetCallee(), settings, "CanonicalizeFunc")) {
                if (let Some(result) <- call.GetResult()) {
                    if (let Some(local) <- flowStoredLocal(result)) {
                        let debug = local.GetDebugExpr().getOrThrow()
                        if (let Some(index) <- indexes.get(debug.GetSrcCodeIdentifier())) { state.Kill(index) }
                    }
                }
            } else if (!canonicalize && flowFunctionMatches(call.GetCallee(), settings, "VerifyFunc")) {
                for (argument in call.GetArgs()) {
                    if (let Some(debug) <- flowDebug(argument)) {
                        if (pathDebug(debug)) { if (let Some(index) <- indexes.get(debug.GetSrcCodeIdentifier())) { state.Kill(index) } }
                    }
                }
            }
        }
        if (let Some(store) <- (expression as Store)) { transfer(state, flowDebug(store.GetValue()), flowDebug(store.GetLocation())) }
        if (let Some(load) <- (expression as Load)) {
            if (let Some(result) <- load.GetResult()) { transfer(state, flowDebug(load.GetLocation()), result.GetDebugExpr()) }
        }
    }
}

func checkPathFunction(findings: ArrayList<Finding>, function: Function, settings: JsonValue, canonicalize: Bool): Unit {
    let analysis = PathValidationAnalysis(function, settings, canonicalize)
    let result = Engine<TemporaryFileDomain>(function, analysis).IterateToFixpoint().getOrThrow()
    result.VisitWith({ state: TemporaryFileDomain, expression: Expression, _: Int64 =>
        if (let Some(call) <- (expression as Apply)) {
            if (!(call.GetCallee() as Function).isSome()) { return }
            let verify = flowFunctionMatches(call.GetCallee(), settings, "VerifyFunc")
            if (canonicalize && !verify) { return }
            if (!canonicalize && (verify || flowFunctionMatches(call.GetCallee(), settings, "CanonicalizeFunc"))) { return }
            for (argument in call.GetArgs()) {
                if (let Some(debug) <- flowDebug(argument)) {
                    let name = debug.GetSrcCodeIdentifier()
                    if (let Some(index) <- analysis.indexes.get(name)) {
                        if (state.IsTrueAt(index)) {
                            if (let Some(value) <- call.GetResult()) {
                                flowEmit(findings, value.GetDebugLocation(),
                                    if (canonicalize) { "G_CHK_03_without_canonicalize" } else { "G_CHK_03_without_verify" }, [name])
                            }
                        }
                    }
                }
            }
        }
    }, { _: TemporaryFileDomain, _: Expression, _: Int64 => },
    { _: TemporaryFileDomain, _: Expression, _: Option<Block> => })
}

func checkPathValidation(findings: ArrayList<Finding>, pkg: Package, settings: JsonValue): Unit {
    for (function in pkg.GetGlobalFuncsWithBody(includeSrcCodeImported: false)) {
        if (function.GetIdentifier().startsWith("@_CGV") || flowGeneric(function)) { continue }
        if (let Some(body) <- function.GetBody()) {
            for (block in body.GetBlocks()) {
                for (expression in block.GetExpressions()) {
                    if (let Some(call) <- (expression as Apply)) {
                        if (!flowFunctionMatches(call.GetCallee(), settings, "ExternalDateFunc")) { continue }
                        if (let Some(result) <- call.GetResult()) {
                            if (let Some(local) <- flowStoredLocal(result)) {
                                for (user in local.GetUsers()) {
                                    if (let Some(consumer) <- (user as Apply)) {
                                        if (let Some(callee) <- (consumer.GetCallee() as Function)) {
                                            if (callee.GetBody().isSome()) {
                                                checkPathFunction(findings, callee, settings, true)
                                                checkPathFunction(findings, callee, settings, false)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
