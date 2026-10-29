package astCoverage

import cjcj::basic.{SourceManager, DiagnosticEngine}
import cjcj::parse.Parser
import cjcj::ast.{Node, Walker, VisitAction, ASTKindName}
import std.fs.File
import std.collection.HashSet

// Inventory the public AST of files that the installed CLI actually produced.
// This is coverage evidence only, not a formatter or a syntax acceptance oracle.
main(args: Array<String>): Int64 {
    for (path in args) {
        let manager = SourceManager()
        let diagnostics = DiagnosticEngine()
        diagnostics.SetSourceManager(manager)
        let raw = String.fromUtf8(File.readFrom(path))
        let source = if (raw.startsWith("\u{FEFF}")) { raw[3..] } else { raw }
        let id = manager.AddSource(path, source)
        let tree = Parser(id, source, diagnostics, manager).ParseTopLevel()
        if (diagnostics.GetErrorCount() != 0) { eprintln("Invalid coverage input: ${path}"); return 1 }
        let kinds = HashSet<String>()
        Walker(tree, visitPre: { node: Node =>
            kinds.add(ASTKindName(node.astKind))
            return VisitAction.WALK_CHILDREN
        }).Walk()
        for (kind in kinds) { println("${path}\t${kind}") }
    }
    return 0
}
