package cangjie_lsp_core
import std.collection.*
import cangjie_lsp_protocol.*
import cjcj::ast.*
import cjcj::lex.{Lexer, TokenKind}
import cjcj::basic.{SourceManager, DiagnosticEngine}
import cjcj::frontend.ExtendMemberQueryType

public class CompletionSpan {
    public let first: Int64
    public let last: Int64
    public let prefix: String
    public init(text: String, position: ProtocolPosition) {
        let offset = ProtocolOffset(text, position)
        let diagnostics = DiagnosticEngine()
        let lexer = Lexer(text, diagnostics, SourceManager())
        var start = offset
        var end = offset
        var chosen = false
        while (true) {
            let token = lexer.Next()
            if (token.kind == TokenKind.END) { break }
            let begin = byteOffset(text, token.Begin().line, token.Begin().column)
            let finish = begin + token.Length()
            if (begin <= offset && offset <= finish) {
                if (token.kind == TokenKind.IDENTIFIER) {
                    start = begin; end = finish; chosen = true
                } else if (!chosen && begin <= offset && offset < finish) {
                    throw IllegalArgumentException("Completion position is not an identifier boundary")
                }
            }
        }
        for (comment in lexer.GetComments()) {
            let begin = byteOffset(text, comment.Begin().line, comment.Begin().column)
            if (begin <= offset && offset < begin + comment.Length()) {
                throw IllegalArgumentException("Completion inside a comment is not a semantic reference")
            }
        }
        if (diagnostics.GetErrorCount() != 0) { throw IllegalArgumentException("Completion requires a lexically valid snapshot") }
        first = start; last = end
        prefix = if (chosen) { text[start..offset] } else { "" }
    }
    private func byteOffset(text: String, line: Int64, column: Int64): Int64 {
        var row: Int64 = 1; var offset: Int64 = 0
        let bytes = text.toArray()
        while (row < line && offset < bytes.size) { if (bytes[offset] == 10) { row++ }; offset++ }
        if (row != line || column < 1 || offset + column - 1 > bytes.size) { throw IllegalArgumentException("Invalid frontend token position") }
        return offset + column - 1
    }
}

// Names are discovered only from the request's lexical ancestors or actual
// receiver. These records are NOT completion results: normal SEMA must resolve
// every proposed replacement before it can cross the protocol boundary.
public class CompletionName {
    public let name: String
    public let declaration: Option<SemanticLocation>
    public let exportKey: String
    public let kind: String
    public init(name: String, declaration: Option<SemanticLocation>, exportKey: String, kind: String) {
        this.name = name; this.declaration = declaration; this.exportKey = exportKey; this.kind = kind
    }
}

extend SemanticDocument {
    public func CompletionNames(marker: String, at: Int64, prefix: String): Array<CompletionName> {
        let holes = ArrayList<Node>()
        for (pkg in compiler.GetSourcePackages()) { for (file in pkg.files) {
            Walker(file, visitPre: Some({ node: Node =>
                var identifier: Option<Identifier> = None
                if (let Some(ref) <- (node as RefExpr)) { identifier = Some(ref.ref.identifier) }
                if (let Some(member) <- (node as MemberAccess)) { identifier = Some(member.field) }
                if (let Some(ref) <- (node as RefType)) { identifier = Some(ref.ref.identifier) }
                if (let Some(member) <- (node as QualifiedType)) { identifier = Some(member.field) }
                if (let Some(id) <- identifier) {
                    if (id.Val() == marker && id.Begin().fileID != 0) {
                        let source = compiler.GetSourceManager().GetSource(id.Begin().fileID)
                        if (source.path == snapshot.uri && source.PosToOffset(id.Begin()) == at) { holes.add(node) }
                    }
                }
                VisitAction.WALK_CHILDREN
            }), walkExprDesugar: false).Walk()
        } }
        if (holes.size != 1 || holes[0].curFile.isNone() || holes[0].scopeName.isEmpty()) {
            throw IllegalArgumentException("Completion has no unambiguous current semantic hole")
        }
        let hole = holes[0]
        let candidates = ArrayList<CompletionName>()
        let seen = HashSet<String>()
        let add = { name: String, decl: Decl =>
            if (name != marker && name.startsWith(prefix) && !name.isEmpty()) {
                let id = decl.identifier; var location: Option<SemanticLocation> = None
                if (id.Begin().fileID != 0 && id.End().fileID == id.Begin().fileID) {
                    let source = compiler.GetSourceManager().GetSource(id.Begin().fileID)
                    location = Some(SemanticLocation(source.path,
                        ProtocolPositionAt(source.buffer, source.PosToOffset(id.Begin())),
                        ProtocolPositionAt(source.buffer, source.PosToOffset(id.End()))))
                }
                let key = if (!decl.fullPackageName.isEmpty() && !decl.exportId.isEmpty()) { decl.fullPackageName + "|" + decl.exportId } else { "" }
                let identity = name + ":" + decl.objectId.toString()
                if (seen.add(identity) && (location.isSome() || !key.isEmpty())) {
                    candidates.add(CompletionName(name, location, key, ASTKindName(decl.astKind)))
                }
            }
        }
        if (let Some(member) <- (hole as MemberAccess)) {
            let ty = member.baseExpr.getOrThrow().GetTy().getOrThrow()
            if (ty.IsInvalid() || ty.HasInvalidTy()) { throw IllegalArgumentException("Completion receiver type is invalid") }
            if (let Some(decl) <- Ty.GetDeclPtrOfTy(ty)) {
                for (item in decl.GetMemberDecls()) { add(item.identifier.Val(), item) }
                if (let Some(inherited) <- (decl as InheritableDecl)) {
                    for (parent in inherited.GetAllSuperDecls()) { for (item in parent.GetMemberDecls()) { add(item.identifier.Val(), item) } }
                }
            }
            for (item in compiler.GetAllVisibleExtendMembers(ExtendMemberQueryType.ByTy(ty), hole.curFile.getOrThrow())) { add(item.identifier.Val(), item) }
        } else if ((hole as QualifiedType).isSome()) {
            throw IllegalArgumentException("Qualified type completion requires a resolved package receiver")
        } else {
            let scopes = HashSet<String>(); var scope = hole.scopeName
            while (!scope.isEmpty()) { scopes.add(scope); scope = GetParentScopeName(scope) }
            for (pkg in compiler.GetSourcePackages()) { for (file in pkg.files) {
                Walker(file, visitPre: Some({ node: Node =>
                    if (let Some(decl) <- (node as Decl)) {
                        if (scopes.contains(decl.scopeName)) { add(decl.identifier.Val(), decl) }
                    }
                    VisitAction.WALK_CHILDREN
                }), walkExprDesugar: false).Walk()
            } }
            for (group in compiler.importManager.getOrThrow().GetImportedDecls(hole.curFile.getOrThrow())) {
                for (decl in group.decls) { add(group.name, decl) }
            }
        }
        return candidates.toArray()
    }
}
