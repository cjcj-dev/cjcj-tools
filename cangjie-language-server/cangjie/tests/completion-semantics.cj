package completion_semantics
import std.fs.*
import cangjie_lsp_core.*
import cangjie_lsp_protocol.*
import cjcj::ast.*

func show(candidate: Candidate, label: String): Unit {
    println("LOOKUP " + label + " hasDecl=${candidate.hasDecl} decls=${candidate.decls.size} tys=${candidate.tys.size}")
    for (decl in candidate.decls) {
        let ty = if (let Some(t) <- decl.GetTy()) { t.String() } else { "NONE" }
        println("DECL ${decl.identifier.Val()} scope=${decl.scopeName} type=${ty}")
    }
}

main(args: Array<String>): Int64 {
    try {
        if (args.size != 3) { return 2 }
        let path = args[1] + "/input.cj"
        let mode = args[2]
        let hole = if (mode == "raw-dot") { "box." } else if (mode == "member") { "box.__completionHole" } else { "__completionHole" }
        let source = "package completion_probe\nclass Box<T> {\n public let value: T\n private let secret: Int64 = 9\n public init(item: T) { value = item }\n}\nfunc use(parameter: Int64): Unit {\n let shadow: Int64 = 1\n let box = Box<Int64>(parameter)\n if (true) {\n  let shadow: Bool = true\n  let result = " + hole + "\n  let later: Int64 = 2\n }\n}\n"
        File.writeTo(path, source.toArray())
        let document = SemanticDocument(DocumentSnapshot(path, 1, source), args[0])
        println("COMPILE success=${document.succeeded} errors=${document.diagnostics.GetErrorCount()} records=${document.records.size}")
        for (d in document.records) { println("DIAGNOSTIC " + d.message) }
        var holes: Int64 = 0
        for (pkg in document.compiler.GetSourcePackages()) {
            let context = document.compiler.GetASTContextByPackage(pkg)
            println("PACKAGE ${pkg.fullPackageName} context=${context.isSome()}")
            for (file in pkg.files) {
                Walker(file, visitPre: Some({ node: Node =>
                    if (let Some(ref) <- (node as RefExpr)) {
                        if (ref.ref.identifier.Val() == "__completionHole") {
                            holes++
                            println("HOLE ref scope=${ref.scopeName} file=${ref.curFile.isSome()}")
                            if (let Some(ctx) <- context) {
                                for (name in ["shadow", "parameter", "later", "box", "noSuchName"]) {
                                    let probe = RefExpr(SrcIdentifier(name, ref.begin, ref.end, false))
                                    CopyNodeScopeInfo(probe, ref)
                                    show(document.compiler.GetGivenReferenceTarget(ctx, ref.scopeName, probe, true), name)
                                }
                            }
                        }
                    }
                    if (let Some(member) <- (node as MemberAccess)) {
                        if (member.field.Val() == "__completionHole") {
                            holes++
                            let baseTy = if (let Some(base) <- member.baseExpr) { if (let Some(t) <- base.GetTy()) { t.String() } else { "NONE" } } else { "NO_BASE" }
                            println("HOLE member scope=${member.scopeName} receiver=${baseTy}")
                            if (let Some(ctx) <- context) {
                                for (name in ["value", "secret", "noSuchMember"]) {
                                    let probe = MemberAccess()
                                    CopyNodeScopeInfo(probe, member)
                                    probe.begin = member.begin; probe.end = member.end
                                    probe.baseExpr = member.baseExpr; probe.dotPos = member.dotPos
                                    probe.field = SrcIdentifier(name, member.field.Begin(), member.field.End(), false)
                                    show(document.compiler.GetGivenReferenceTarget(ctx, member.scopeName, probe, true), name)
                                }
                            }
                        }
                    }
                    VisitAction.WALK_CHILDREN
                }), walkExprDesugar: false).Walk()
            }
        }
        println("OBSERVED holes=${holes}")
        return 0
    } catch (e: Exception) { eprintln(e.message); return 41 }
}
