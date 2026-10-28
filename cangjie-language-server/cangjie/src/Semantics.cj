package cangjie_lsp_core

import std.collection.*
import cangjie_lsp_protocol.*
import cjcj::ast.{Node, Decl, RefExpr, MemberAccess, Identifier, Walker, VisitAction, Attribute}
import cjcj::mangle.BaseMangler
import cjcj::basic.DiagnosticEngine as BasicDiagnosticEngine
import cjcj::basic.{Diagnostic, DiagnosticHandler, DiagHandlerKind, DiagSeverity}
import cjcj::frontend.{CompilerInvocation, CompilerInstance, CompileStage, DiagnosticEngine, SrcCodeCacheInfo}

public class SemanticLocation {
    public let path: String
    public let start: ProtocolPosition
    public let end: ProtocolPosition
    public init(path: String, start: ProtocolPosition, end: ProtocolPosition) {
        this.path = path; this.start = start; this.end = end
    }
}

private class ServerDiagnosticHandler <: DiagnosticHandler {
    public let records = ArrayList<Diagnostic>()
    public init(engine: BasicDiagnosticEngine) { super(engine, DiagHandlerKind.LSP_HANDLER) }
    public override func HandleDiagnose(item: Diagnostic): Unit {
        // DiagnosticHandler owns counting in the frontend contract. Retaining
        // wire diagnostics alone must not make a failed SEMA snapshot succeed.
        if (item.diagSeverity == DiagSeverity.DS_ERROR) {
            diag.IncreaseErrorCount(item.diagCategory)
        } else if (item.diagSeverity == DiagSeverity.DS_WARNING) {
            diag.IncreaseWarningCount(item.diagCategory)
        }
        synchronized(mtx) { records.add(item) }
    }
}

private class BoundOccurrence {
    let declaration: Decl
    let location: SemanticLocation
    let isDeclaration: Bool
    init(declaration: Decl, location: SemanticLocation, isDeclaration: Bool) {
        this.declaration = declaration; this.location = location; this.isDeclaration = isDeclaration
    }
}

// The instance owns source storage, declarations and resolved references for
// this immutable snapshot. Queries never borrow an AST from another version.
public class SemanticDocument {
    public let snapshot: DocumentSnapshot
    public let diagnostics = DiagnosticEngine()
    public let compiler: CompilerInstance
    public let succeeded: Bool
    public let records: ArrayList<Diagnostic>
    private let occurrences = ArrayList<BoundOccurrence>()

    public init(snapshot: DocumentSnapshot, targetSdk: String, importPaths!: Array<String> = [], companions!: Array<DocumentSnapshot> = [], compilerArguments!: Array<String> = []) {
        this.snapshot = snapshot
        let invocation = CompilerInvocation()
        let args = ArrayList<String>(compilerArguments)
        if (args.isEmpty()) {
            args.add(targetSdk + "/bin/cjc"); args.add("--output-type=staticlib")
            for (directory in importPaths) { args.add("--import-path=" + directory) }
            args.add(snapshot.uri)
            for (peer in companions) { if (peer.uri != snapshot.uri) { args.add(peer.uri) } }
        }
        if (!invocation.ParseArgs(args)) { throw IllegalArgumentException("Invalid frontend arguments") }
        invocation.globalOptions.executablePath = targetSdk + "/bin/cjc"
        // --sdk selects the analysis modules independently of the host process
        // and of a symlinked compiler entry. DetectCangjieHome realpaths argv0.
        invocation.globalOptions.cangjieHome = targetSdk
        invocation.globalOptions.environment.cangjieHome.hasValue = false
        compiler = CompilerInstance(invocation, diagnostics)
        let handler = ServerDiagnosticHandler(compiler.importManager.getOrThrow().GetDiagnosticEngine())
        compiler.importManager.getOrThrow().GetDiagnosticEngine().RegisterHandler(handler)
        records = handler.records
        compiler.loadSrcFilesFromCache = true
        compiler.bufferCache[snapshot.uri] = SrcCodeCacheInfo(snapshot.text)
        for (peer in companions) { compiler.bufferCache[peer.uri] = SrcCodeCacheInfo(peer.text) }
        succeeded = compiler.Compile(stage: CompileStage.SEMA) && diagnostics.GetErrorCount() == 0
        if (succeeded) {
            for (sourcePackage in compiler.GetSourcePackages()) {
                if (!compilerArguments.isEmpty()) { BaseMangler().MangleExportIds(sourcePackage) }
                for (file in sourcePackage.files) {
                    Walker(file, visitPre: Some({ node: Node => collect(node) }), walkExprDesugar: false).Walk()
                }
            }
        }
    }

    private func location(identifier: Identifier): Option<SemanticLocation> {
        let begin = identifier.Begin()
        let end = identifier.End()
        if (begin.fileID == 0 || begin.fileID != end.fileID || begin.line < 1 || end.line < 1) { return None }
        let source = compiler.GetSourceManager().GetSource(begin.fileID)
        let first = source.PosToOffset(begin)
        let last = source.PosToOffset(end)
        if (last <= first) { return None }
        return Some(SemanticLocation(source.path, ProtocolPositionAt(source.buffer, first), ProtocolPositionAt(source.buffer, last)))
    }

    private func add(declaration: Decl, identifier: Identifier, isDeclaration: Bool): Unit {
        if (let Some(found) <- location(identifier)) {
            for (old in occurrences) {
                if (old.declaration == declaration && old.isDeclaration == isDeclaration &&
                    old.location.path == found.path && old.location.start.line == found.start.line &&
                    old.location.start.character == found.start.character) { return }
            }
            occurrences.add(BoundOccurrence(declaration, found, isDeclaration))
        }
    }

    private func collect(node: Node): VisitAction {
        if (let Some(declaration) <- (node as Decl)) { add(declaration, declaration.identifier, true) }
        if (let Some(reference) <- (node as RefExpr)) {
            if (let Some(target) <- reference.ref.target) { add(target, reference.ref.identifier, false) }
        }
        if (let Some(member) <- (node as MemberAccess)) {
            if (let Some(target) <- member.target) { add(target, member.field, false) }
        }
        return VisitAction.WALK_CHILDREN
    }

    private func target(position: ProtocolPosition): Option<Decl> {
        for (occurrence in occurrences) {
            let found = occurrence.location
            if (found.path == snapshot.uri && position.line == found.start.line &&
                position.line == found.end.line && position.character >= found.start.character &&
                position.character < found.end.character) { return Some(occurrence.declaration) }
        }
        return None
    }

    // The CJO writer and reader use this same frontend export identity. Local
    // declarations retain instance identity; they never match by spelling.
    private func exportedKey(declaration: Decl): String {
        if (!declaration.TestAttr(Attribute.GLOBAL) || declaration.exportId.isEmpty() || declaration.fullPackageName.isEmpty()) { return "" }
        return declaration.fullPackageName + "|" + declaration.exportId
    }
    public func ExportedTarget(position: ProtocolPosition): String {
        if (let Some(declaration) <- target(position)) { return exportedKey(declaration) }
        return ""
    }
    public func ExportedOccurrences(key: String, declarationsOnly!: Bool = false, includeDeclaration!: Bool = false): Array<SemanticLocation> {
        let result = ArrayList<SemanticLocation>()
        if (key.isEmpty()) { return result.toArray() }
        for (item in occurrences) {
            if (exportedKey(item.declaration) == key &&
                (if (declarationsOnly) { item.isDeclaration } else { includeDeclaration || !item.isDeclaration })) { result.add(item.location) }
        }
        return result.toArray()
    }

    public func Definition(position: ProtocolPosition): Option<SemanticLocation> {
        if (let Some(declaration) <- target(position)) { return location(declaration.identifier) }
        return None
    }

    public func References(position: ProtocolPosition, includeDeclaration!: Bool = false): Array<SemanticLocation> {
        let results = ArrayList<SemanticLocation>()
        if (let Some(declaration) <- target(position)) {
            for (occurrence in occurrences) {
                if (occurrence.declaration == declaration && (includeDeclaration || !occurrence.isDeclaration)) {
                    results.add(occurrence.location)
                }
            }
        }
        return results.toArray()
    }
}
