// Copyright (c) Huawei Technologies Co., Ltd. 2025. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjfmt

import cjcj::parse.Parser
import cjcj::basic.{SourceManager, DiagnosticEngine}
import cjcj::ast.File

// Own the source and diagnostics for the entire AST traversal. The formatter
// consumes the same Cangjie Parser as the compiler. Layout reads the public
// lexer's complete comment tokens; it never consumes Node.comments. Avoid the
// separate attachment pass and retain comments independently of AST ownership.
public class FormattingInput {
    public let sourceManager: SourceManager = SourceManager()
    public let diagnostics: DiagnosticEngine = DiagnosticEngine()
    public let parser: Parser
    public let file: File
    public let fileID: UInt64

    public init(name: String, source: String) {
        fileID = sourceManager.AddSource(name, source)
        diagnostics.SetSourceManager(sourceManager)
        parser = Parser(fileID, source, diagnostics, sourceManager)
        file = parseFormattingFile(parser)
    }

    public func HasErrors(): Bool { return diagnostics.GetErrorCount() != 0 }
}

func parseFormattingFile(parser: Parser): File {
    try { return parser.ParseTopLevel() }
    catch (e: Exception) { e.printStackTrace(); throw Exception("Parser.ParseTopLevel: ${e}") }
}
