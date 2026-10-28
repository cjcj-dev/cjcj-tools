package parserConsumer

import cjcj::basic.{SourceManager, DiagnosticEngine}
import cjcj::parse.Parser
import std.fs.File

// A direct consumer for handing public Parser failures to its owner. This is
// independent of cjfmt layout, comment rewriting and program equivalence checks.
main(args: Array<String>): Int64 {
    if (args.size != 2) { return 2 }
    let source = String.fromUtf8(File.readFrom(args[0]))
    let manager = SourceManager()
    let diagnostics = DiagnosticEngine()
    diagnostics.SetSourceManager(manager)
    let id = manager.AddSource(args[0], source)
    let parser = Parser(id, source, diagnostics, manager, attachComment: args[1] == "true")
    try {
        let file = parser.ParseTopLevel()
        println("PARSE_RETURNED declarations=${file.decls.size} errors=${diagnostics.GetErrorCount()}")
        return if (diagnostics.GetErrorCount() == 0) { 0 } else { 1 }
    } catch (e: Exception) {
        e.printStackTrace()
        return 1
    }
}
