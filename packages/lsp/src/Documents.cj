package cangjie_lsp_core

import cangjie_lsp_protocol.*
import cjcj::parse.Parser
import cjcj::ast.File
import cjcj::basic.{SourceManager, DiagnosticEngine}

// A parse result keeps the exact immutable document snapshot, source manager,
// parser and diagnostics alive together. No C++ AST or borrowed native handle.
public class ParsedDocument {
    public let snapshot: DocumentSnapshot
    public let sources = SourceManager()
    public let diagnostics = DiagnosticEngine()
    public let parser: Parser
    public let ast: File
    public init(snapshot: DocumentSnapshot) {
        this.snapshot = snapshot
        let fileID = sources.AddSource(snapshot.uri, snapshot.text)
        parser = Parser(fileID, snapshot.text, diagnostics, sources, attachComment: true)
        ast = parser.ParseTopLevel()
    }
}
