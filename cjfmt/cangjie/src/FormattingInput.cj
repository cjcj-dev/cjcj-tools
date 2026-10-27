// Copyright (c) Huawei Technologies Co., Ltd. 2025. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjfmt_core

import cjcj::parse.Parser
import cjcj::basic.{SourceManager, DiagnosticEngine}
import cjcj::ast.File

// Own the source and diagnostics for the entire AST traversal. The formatter
// consumes the same Cangjie Parser as the compiler, with comment attachment.
public class FormattingInput {
    public let sourceManager: SourceManager = SourceManager()
    public let diagnostics: DiagnosticEngine = DiagnosticEngine()
    public let parser: Parser
    public let file: File
    public let fileID: UInt64

    public init(name: String, source: String) {
        fileID = sourceManager.AddSource(name, source)
        parser = Parser(fileID, source, diagnostics, sourceManager, attachComment: true)
        file = parser.ParseTopLevel()
    }

    public func HasErrors(): Bool { return diagnostics.GetErrorCount() != 0 }
}
