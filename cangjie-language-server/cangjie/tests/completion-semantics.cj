package completion_semantics
import std.fs.File as DiskFile
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
        let candidateMode = mode.startsWith("candidate-")
        let requested = if (candidateMode) { mode[10..] } else { "" }
        let hole = if (candidateMode) { match (requested) { case "value" => "box.value" case "secret" => "box.secret" case "unrelated" => "shadow" case _ => requested } } else if (mode == "raw-dot") { "box." } else if (mode == "member") { "box.__completionHole" } else { "__completionHole" }
        let source = "package completion_probe\nclass Box<T> {\n public let value: T\n private let secret: Int64 = 9\n public init(item: T) { value = item }\n}\nfunc use(parameter: Int64): Unit {\n let shadow: Int64 = 1\n let box = Box<Int64>(parameter)\n if (true) {\n  let shadow: Bool = true\n  let result = " + hole + "\n  let later: Int64 = 2\n" + (if (requested == "unrelated") { "  let broken: Bool = 1\n" } else { "" }) + " }\n}\n"
        DiskFile.writeTo(path, source.toArray())
        let document = SemanticDocument(DocumentSnapshot(path, 1, source), args[0])
        println("COMPILE success=${document.succeeded} errors=${document.diagnostics.GetErrorCount()} records=${document.records.size}")
        for (d in document.records) { println("DIAGNOSTIC " + (if (d.isRefactor) { d.errorMessage } else { d.diagMessage })) }
        if (candidateMode) {
            let accepted = requested == "shadow" || requested == "parameter" || requested == "value"
            if (document.succeeded != accepted) { throw Exception("CANDIDATE_SEMA_TARGET " + requested) }
            if (accepted) {
                let index = source.indexOf("let result = ").getOrThrow() + "let result = ".size
                let location = ProtocolPositionAt(source, index + (if (requested == "value") { 4 } else { 0 }))
                let hover = document.Hover(location).getOrThrow()
                let expectedLine: Int64 = if (requested == "shadow") { 10 } else if (requested == "parameter") { 6 } else { 2 }
                let matches = Array<Int64>(1, repeat: 0)
                for (binding in document.Bindings()) {
                    if (!binding.isDeclaration && binding.location.path == path &&
                        binding.location.start.line == location.line && binding.location.start.character == location.character) {
                        let declaration = binding.declaration.getOrThrow()
                        println("CANDIDATE_BINDING name=" + binding.name + " declLine=" + declaration.start.line.toString())
                        if (declaration.path != path || declaration.start.line != expectedLine) {
                            throw Exception("CANDIDATE_DECL_TARGET " + requested)
                        }
                        matches[0]++
                    }
                }
                if (matches[0] != 1) { throw Exception("CANDIDATE_DECL_COUNT " + requested) }
                let expected = if (requested == "shadow") { "shadow: Bool" } else if (requested == "parameter") { "parameter: Int64" } else { "value: Int64" }
                println("CANDIDATE_TYPE actual=" + hover.text + " expected=" + expected)
                if (hover.text != expected) { throw Exception("CANDIDATE_TYPE_TARGET " + requested) }
            } else if (document.records.isEmpty()) { throw Exception("CANDIDATE_REJECTION_DIAGNOSTIC " + requested) }
            println("CANDIDATE_SEMA_PASS " + requested + " accepted=" + accepted.toString())
            return 0
        }
        let holes = Array<Int64>(1, repeat: 0)
        let checked = Array<Int64>(1, repeat: 0)
        for (pkg in document.compiler.GetSourcePackages()) {
            let context = document.compiler.GetASTContextByPackage(pkg)
            println("PACKAGE ${pkg.fullPackageName} context=${context.isSome()}")
            for (file in pkg.files) {
                Walker(file, visitPre: Some({ node: Node =>
                    if (let Some(ref) <- (node as RefExpr)) {
                        if (ref.ref.identifier.Val() == "__completionHole") {
                            holes[0]++
                            println("HOLE ref scope=${ref.scopeName} file=${ref.curFile.isSome()}")
                            if (let Some(ctx) <- context) {
                                for (name in ["shadow", "parameter", "later", "box", "noSuchName"]) {
                                    let probe = RefExpr(SrcIdentifier(name, ref.begin, ref.end, false))
                                    CopyNodeScopeInfo(probe, ref)
                                    if (mode == "context") {
                                        if (let Some(ty) <- probe.GetTy()) {
                                            if (Ty.IsTyCorrect(ty)) { throw Exception("CONTEXT_PROBE_ALREADY_TYPED") }
                                        }
                                    }
                                    let found = document.compiler.GetGivenReferenceTarget(ctx, ref.scopeName, probe, true)
                                    show(found, name)
                                    if (mode == "context") {
                                        if (ctx.symbolTable.isEmpty()) { throw Exception("CONTEXT_SYMBOLS_EMPTY") }
                                        if (name == "later" || name == "noSuchName") {
                                            if (!found.decls.isEmpty()) { throw Exception("CONTEXT_VISIBILITY_TARGET " + name) }
                                        } else {
                                            if (!found.hasDecl || found.decls.size != 1) { throw Exception("CONTEXT_DECL_TARGET " + name) }
                                            let declaration = found.decls[0]
                                            let line: Int64 = if (name == "shadow") { 11 } else if (name == "parameter") { 7 } else { 9 }
                                            let expected = if (name == "shadow") { "Bool" } else if (name == "parameter") { "Int64" } else { "Box<Int64>" }
                                            let actual = declaration.GetTy().getOrThrow().String()
                                            let origin = document.compiler.GetSourceManager().GetSource(declaration.identifier.Begin().fileID)
                                            println("CONTEXT_TARGET name=" + name + " line=" + declaration.identifier.Begin().line.toString() + " type=" + actual)
                                            if (origin.path != path || declaration.identifier.Begin().line != line || actual != expected) {
                                                throw Exception("CONTEXT_DECL_TYPE_TARGET " + name)
                                            }
                                        }
                                        checked[0]++
                                    }
                                }
                            }
                        }
                    }
                    if (let Some(member) <- (node as MemberAccess)) {
                        if (member.field.Val() == "__completionHole") {
                            holes[0]++
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
        if (mode == "context") {
            if (holes[0] != 1 || checked[0] != 5 || document.succeeded || document.diagnostics.GetErrorCount() != 1) {
                throw Exception("CONTEXT_INCOMPLETE_INPUT_TARGET")
            }
            println("CONTEXT_LOOKUP_PASS checked=" + checked[0].toString())
        }
        println("OBSERVED holes=${holes[0]}")
        return 0
    } catch (e: Exception) { eprintln(e.message); return 41 }
}
