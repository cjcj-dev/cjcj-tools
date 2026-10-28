package cangjie_lsp_core

import std.collection.*
import cangjie_lsp_protocol.*
import cjcj::ast.*
import cjcj::ast.File as ASTFile
import cjcj::lex.{Lexer, TokenKind}
import cjcj::basic.SourceManager
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

public class SemanticHover {
    public let text: String
    public let location: SemanticLocation
    public init(text: String, location: SemanticLocation) { this.text = text; this.location = location }
}

private class BoundOccurrence {
    let declaration: Decl
    let location: SemanticLocation
    let isDeclaration: Bool
    let resolvedType: Option<Ty>
    init(declaration: Decl, location: SemanticLocation, isDeclaration: Bool, resolvedType: Option<Ty>) {
        this.declaration = declaration; this.location = location; this.isDeclaration = isDeclaration
        this.resolvedType = resolvedType
    }
}

// Immutable source coordinates cross compiler instances; AST pointers never do.
public class SemanticBinding {
    public let location: SemanticLocation
    public let declaration: Option<SemanticLocation>
    public let exportKey: String
    public let kind: String
    public let name: String
    public let isDeclaration: Bool
    public let canRename: Bool
    public init(location: SemanticLocation, declaration: Option<SemanticLocation>, exportKey: String,
        kind: String, name: String, isDeclaration: Bool, canRename: Bool) {
        this.location = location; this.declaration = declaration; this.exportKey = exportKey
        this.kind = kind; this.name = name; this.isDeclaration = isDeclaration; this.canRename = canRename
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
    private let unsupportedImports = HashSet<Decl>()

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
                    for (spec in file.imports) { collectImport(file, spec.content) }
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

    private func add(declaration: Decl, identifier: Identifier, isDeclaration: Bool, resolvedType: Option<Ty>): Unit {
        if (let Some(found) <- location(identifier)) {
            for (old in occurrences) {
                if (old.declaration == declaration && old.isDeclaration == isDeclaration &&
                    old.location.path == found.path && old.location.start.line == found.start.line &&
                    old.location.start.character == found.start.character) { return }
            }
            occurrences.add(BoundOccurrence(declaration, found, isDeclaration, resolvedType))
        }
    }

    private func collectImport(file: ASTFile, content: ImportContent): Unit {
        if (content.kind == ImportKind.IMPORT_MULTI) {
            for (item in content.items) { collectImport(file, item) }; return
        }
        if (content.kind == ImportKind.IMPORT_ALL) { return }
        let lookup = if (content.kind == ImportKind.IMPORT_ALIAS) { content.aliasName.Val() } else { content.identifier.Val() }
        let targets = compiler.importManager.getOrThrow().GetImportedDeclsByName(file, lookup)
        // Ambiguous import groups cannot supply an exact single-token rename.
        if (targets.size != 1) { for (decl in targets) { unsupportedImports.add(decl) }; return }
        add(targets[0], content.identifier, false, targets[0].GetTy())
    }

    private func collect(node: Node): VisitAction {
        if (let Some(declaration) <- (node as Decl)) { add(declaration, declaration.identifier, true, declaration.GetTy()) }
        if (let Some(reference) <- (node as RefExpr)) {
            if (let Some(target) <- reference.ref.target) {
                if (target.TestAttr(Attribute.CONSTRUCTOR) && target.outerDecl.isSome()) {
                    add(target.outerDecl.getOrThrow(), reference.ref.identifier, false, reference.GetTy())
                } else { add(target, reference.ref.identifier, false, reference.GetTy()) }
            }
        }
        if (let Some(member) <- (node as MemberAccess)) {
            if (let Some(target) <- member.target) { add(target, member.field, false, member.GetTy()) }
        }
        if (let Some(reference) <- (node as RefType)) {
            if (let Some(target) <- reference.ref.target) { add(target, reference.ref.identifier, false, reference.GetTy()) }
        }
        if (let Some(reference) <- (node as QualifiedType)) {
            if (let Some(target) <- reference.target) { add(target, reference.field, false, reference.GetTy()) }
        }
        if (let Some(call) <- (node as CallExpr)) {
            if (let Some(function) <- call.resolvedFunction) {
                if (let Some(body) <- function.funcBody) {
                    for (argument in call.args where !argument.name.Empty()) {
                        for (list in body.paramLists) { for (param in list.params) {
                            if (param.isNamedParam && param.identifier.Val() == argument.name.Val()) {
                                add(param, argument.name, false, param.GetTy())
                            }
                        } }
                    }
                }
            }
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


    public func SourcePackageName(): String {
        let packages = compiler.GetSourcePackages()
        if (!succeeded || packages.size != 1) { throw IllegalArgumentException("Rename requires one successful source package per command") }
        return packages[0].fullPackageName
    }
    public func ImportedPackages(): Array<String> {
        let names = HashSet<String>()
        for (pkg in compiler.importManager.getOrThrow().GetAllImportedPackages()) { names.add(pkg.fullPackageName) }
        return names.toArray()
    }
    public func ExportCandidate(): Array<UInt8> {
        let _ = SourcePackageName()
        let bytes = compiler.ExportAST(true, compiler.GetSourcePackages()[0])
        if (bytes.isEmpty() || diagnostics.GetErrorCount() != 0) { throw IllegalArgumentException("Candidate CJO export failed") }
        return bytes
    }
    public func ValidateRenameName(name: String): Unit {
        let diag = BasicDiagnosticEngine()
        let lexer = Lexer(name, diag, SourceManager())
        let token = lexer.Next()
        if (token.kind != TokenKind.IDENTIFIER || token.Length() != name.size || token.Begin().column != 1 ||
            lexer.Next().kind != TokenKind.END || diag.GetErrorCount() != 0) {
            throw IllegalArgumentException("Rename requires one complete legal identifier")
        }
    }
    private func renameAllowed(decl: Decl): Bool {
        if (decl.isInMacroCall || decl.curMacroCall.isSome() || unsupportedImports.contains(decl) ||
            decl.TestAnyAttr(Attribute.CONSTRUCTOR, Attribute.PRIMARY_CONSTRUCTOR, Attribute.ENUM_CONSTRUCTOR) ||
            decl.TestAnyAttr(Attribute.OVERRIDE, Attribute.OPEN, Attribute.ABSTRACT)) { return false }
        if (let Some(owner) <- decl.outerDecl) {
            if (let Some(inherited) <- (owner as InheritableDecl)) {
                if (!inherited.inheritedTypes.isEmpty() || (owner as InterfaceDecl).isSome() || owner.IsOpen()) { return false }
            }
        }
        return (decl as VarDecl).isSome() || (decl as FuncDecl).isSome() || (decl as StructDecl).isSome() ||
            (decl as ClassDecl).isSome() || (decl as TypeAliasDecl).isSome() || (decl as GenericParamDecl).isSome()
    }
    public func Bindings(): Array<SemanticBinding> {
        let result = ArrayList<SemanticBinding>()
        if (!succeeded) { return result.toArray() }
        for (item in occurrences) {
            let decl = item.declaration
            let key = if (decl.exportId.isEmpty() || decl.fullPackageName.isEmpty()) { "" }
                else { decl.fullPackageName + "|" + decl.exportId }
            result.add(SemanticBinding(item.location, location(decl.identifier), key,
                ASTKindName(decl.astKind), decl.identifier.Val(), item.isDeclaration, renameAllowed(decl)))
        }
        return result.toArray()
    }

    public func Hover(position: ProtocolPosition): Option<SemanticHover> {
        if (!succeeded) { return None }
        for (item in occurrences) {
            let found = item.location
            if (found.path != snapshot.uri || position.line != found.start.line ||
                position.line != found.end.line || position.character < found.start.character ||
                position.character >= found.end.character) { continue }
            // A reference's type belongs to this resolved occurrence (including
            // instantiated generics and selected overloads), not its spelling or
            // the uninstantiated declaration in another compiler instance.
            if (let Some(ty) <- item.resolvedType) {
                if (!ty.IsInvalid() && !ty.HasInvalidTy()) {
                    return Some(SemanticHover(item.declaration.identifier.Val() + ": " + ty.String(), found))
                }
            }
            return None
        }
        return None
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
