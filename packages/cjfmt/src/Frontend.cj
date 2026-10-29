package cjfmt

import cjcj::basic.{Source, Position, DiagnosticEngine}
import cjcj::lex.{LexerImpl, LexerConfig, Token, TokenKind}
import cjcj::ast.*
import std.collection.*
import std.sort.*

func sourceOffset(source: Source, position: Position): Int64 {
    if (position.line < 1 || position.column < 1) { return 0 }
    if (position.line > source.lineOffsets.size) { return source.buffer.size }
    let offset = source.lineOffsets[position.line - 1] + position.column - 1
    return if (offset < source.buffer.size) { offset } else { source.buffer.size }
}

class Lexeme {
    let token: Token
    let first: Int64
    let last: Int64
    let text: String
    init(token: Token, source: Source) {
        this.token = token
        first = sourceOffset(source, token.Begin())
        last = sourceOffset(source, token.End())
        text = source.buffer[first..last]
    }
}

class Syntax {
    let input: FormattingInput
    let source: Source
    var tokens: Array<Lexeme> = []
    let statements = HashSet<Int64>()
    let emptyLines = HashSet<Int64>()
    let unary = HashSet<Int64>()
    let postfix = HashSet<Int64>()
    let binaryOperators = HashSet<Int64>()
    let binaryGroups = HashMap<Int64, Int64>()
    let operatorLines = HashSet<Int64>()
    let spacedColons = HashSet<Int64>()
    let angles = HashSet<Int64>()
    let blocks = HashSet<Int64>()
    let opaque = HashMap<Int64, Int64>()
    let annotationEnds = HashSet<Int64>()
    let enumGroups = HashMap<Int64, Int64>()
    let enumPipes = HashSet<Int64>()
    let interpolations = HashMap<Int64, ArrayList<InterpolationExpr>>()
    let macroAttributes = HashMap<Int64, MacroInvocation>()
    let shape = ArrayList<ASTKind>()
    let chains = ArrayList<(Array<MemberAccess>, Position)>()
    let multiline = HashSet<Int64>()
    var valid: Bool = true
    var difference = ""

    init(name: String, text: String) {
        input = FormattingInput(name, text)
        let sm = input.sourceManager
        let id = input.fileID
        source = sm.GetSource(id)
        let diag = input.diagnostics
        let tree = input.file
        valid = diag.GetErrorCount() == 0
        if (!valid) { diag.EmitCategoryGroup(); diag.close(); return }
        collect(tree, text, Position(id, 1, 1))
        diag.close()
    }

    init(parent: Syntax, body: Node) {
        input = parent.input; source = parent.source
        collect(body, source.buffer[sourceOffset(source, body.begin)..sourceOffset(source, body.end)], body.begin)
    }

    func collect(tree: Node, value: String, base: Position): Unit {
        let diag = DiagnosticEngine()
        let sm = input.sourceManager
        diag.SetSourceManager(sm)
        let id = input.fileID
        let lexer = LexerImpl(value, diag, sm,
            LexerConfig(fileID: id, posBase: base, splitAmbiguousToken: false))
        let stream = ArrayList<Lexeme>()
        while (true) {
            let token = lexer.Next()
            if (token.kind == TokenKind.END) { break }
            if (token.kind != TokenKind.NL && token.kind != TokenKind.COMMENT) {
                stream.add(Lexeme(token, source))
            }
        }
        for (comment in lexer.GetComments()) { stream.add(Lexeme(comment, source)) }
        let ordered = stream.toArray()
        sort(ordered, by: { left: Lexeme, right: Lexeme => left.first.compare(right.first) })
        valid = valid && diag.GetErrorCount() == 0
        if (let Some(file) <- (tree as File)) {
            markDeclarations(file.decls, true)
            for (spec in file.imports) { addPosition(statements, spec.begin) }
            if (!file.imports.isEmpty() && (file.packageSpec.isSome() || file.feature.isSome())) {
                addPosition(emptyLines, file.imports[0].begin)
            }
            if (!file.decls.isEmpty() && (!file.imports.isEmpty() || file.packageSpec.isSome() || file.feature.isSome())) {
                addPosition(emptyLines, FormattingBegin(file.decls[0]))
            }
        }
        try { Walker(tree, visitPre: { node: Node =>
            shape.add(node.astKind)
            if (let Some(literal) <- (node as LitConstExpr)) {
                if (let Some(parts) <- literal.siExpr) {
                    let expressions = ArrayList<InterpolationExpr>()
                    for (part in parts.strPartExprs) {
                        if (let Some(expr) <- (part as InterpolationExpr)) { expressions.add(expr) }
                    }
                    if (!expressions.isEmpty()) { interpolations[sourceOffset(source, literal.begin)] = expressions }
                }
            }
            if (let Some(decl) <- (node as Decl)) {
                if ((node as FuncParam).isNone()) {
                    for (annotation in decl.annotations) { annotationEnds.add(sourceOffset(source, annotation.end)) }
                }
            }
            if (let Some(member) <- (node as MemberAccess)) { chains.add((chainOf(member).toArray(), member.end)) }
            if (let Some(call) <- (node as CallExpr)) {
                chains.add((chainOf(call).toArray(), call.end))
                if (call.args.size >= 2 && call.rightParenPos.line != call.args[call.args.size - 1].end.line) {
                    addPosition(multiline, call.leftParenPos)
                }
            }
            if (let Some(subscript) <- (node as SubscriptExpr)) { chains.add((chainOf(subscript).toArray(), subscript.end)) }
            if (let Some(array) <- (node as ArrayLit)) {
                if (array.children.size >= 2 && array.rightSquarePos.line != array.children[array.children.size - 1].end.line) {
                    addPosition(multiline, array.leftSquarePos)
                }
            }
            if (let Some(body) <- (node as EnumDecl)) {
                addPosition(blocks, body.leftCurlPos)
                let count = body.constructors.size
                let preserveLines = count > 1 && body.constructors[0].begin.line != body.constructors[count - 1].begin.line
                for (pos in body.bitOrPosVector) { addPosition(if (preserveLines) { statements } else { enumPipes }, pos) }
                if (!preserveLines && count > 0) {
                    var begin = sourceOffset(source, FormattingBegin(body.constructors[0]))
                    if (!body.bitOrPosVector.isEmpty()) { begin = min(begin, sourceOffset(source, body.bitOrPosVector[0])) }
                    let end = if (body.hasEllipsis) { sourceOffset(source, body.ellipsisPos) + 3 }
                        else { sourceOffset(source, body.constructors[count - 1].end) }
                    enumGroups[begin] = end
                }
                for (member in body.members) { addPosition(statements, member.begin) }
                if (!body.members.isEmpty()) { addPosition(emptyLines, FormattingBegin(body.members[0])) }
            }
            if (let Some(matchCase) <- (node as MatchCase)) { addPosition(statements, matchCase.begin) }
            if (let Some(matchCase) <- (node as MatchCaseOther)) { addPosition(statements, matchCase.begin) }
            if (let Some(block) <- (node as Block)) {
                addPosition(blocks, block.leftCurlPos)
                for (i in 0..block.body.size) {
                    let child = block.body[i]
                    addPosition(statements, FormattingBegin(child))
                    if (i > 0 && hasBlankBetween(block.body[i - 1], child)) { addPosition(emptyLines, FormattingBegin(child)) }
                }
            }
            if (let Some(expr) <- (node as LambdaExpr)) {
                if (expr.begin.line != expr.end.line) { addPosition(blocks, expr.begin) }
            }
            if (let Some(expr) <- (node as RangeExpr)) { addPosition(spacedColons, expr.colonPos) }
            if (let Some(body) <- (node as ClassBody)) { addPosition(blocks, body.leftCurlPos); markDeclarations(body.decls, false) }
            if (let Some(body) <- (node as StructBody)) { addPosition(blocks, body.leftCurlPos); markDeclarations(body.decls, false) }
            if (let Some(body) <- (node as InterfaceBody)) { addPosition(blocks, body.leftCurlPos); markDeclarations(body.decls, false) }
            if (let Some(body) <- (node as ExtendDecl)) { addPosition(blocks, body.leftCurlPos); markDeclarations(body.members, false) }
            if (let Some(body) <- (node as PropDecl)) {
                addPosition(blocks, body.leftCurlPos)
                for (getter in body.getters) { addPosition(statements, FormattingBegin(getter)) }
                for (setter in body.setters) { addPosition(statements, FormattingBegin(setter)) }
            }
            if (let Some(body) <- (node as MatchExpr)) { addPosition(blocks, body.leftCurlPos) }
            if (let Some(expr) <- (node as UnaryExpr)) { addPosition(unary, expr.operatorPos) }
            if (let Some(expr) <- (node as BinaryExpr)) {
                addPosition(binaryOperators, expr.operatorPos)
                if (let Some(left) <- expr.leftExpr) {
                    if (left.end.line < expr.operatorPos.line) { addPosition(operatorLines, expr.operatorPos) }
                }
                let begin = sourceOffset(source, expr.begin); let end = sourceOffset(source, expr.end)
                if (end > (binaryGroups.get(begin) ?? begin)) { binaryGroups[begin] = end }
            }
            if (let Some(expr) <- (node as IncOrDecExpr)) { addPosition(postfix, expr.operatorPos) }
            if (let Some(ty) <- (node as OptionType)) {
                for (position in ty.questVector) { addPosition(unary, position) }
            }
            if (let Some(ty) <- (node as RefType)) { addAngles(ty.leftAnglePos, ty.rightAnglePos) }
            if (let Some(ty) <- (node as QualifiedType)) { addAngles(ty.leftAnglePos, ty.rightAnglePos) }
            if (let Some(ty) <- (node as VArrayType)) { addAngles(ty.leftAnglePos, ty.rightAnglePos) }
            if (let Some(pattern) <- (node as EnumPattern)) { addAngles(pattern.leftAnglePos, pattern.rightAnglePos) }
            if (let Some(expr) <- (node as NameReferenceExpr)) { addAngles(expr.leftAnglePos, expr.rightAnglePos) }
            if (let Some(generic) <- (node as Generic)) { addAngles(generic.leftAnglePos, generic.rightAnglePos) }
            if ((node as QuoteExpr).isSome()) {
                if (node.begin.line > 0 && node.end.line > 0) {
                    opaque[sourceOffset(source, node.begin)] = sourceOffset(source, node.end)
                    return VisitAction.SKIP_CHILDREN
                }
            }
            if (let Some(expansion) <- (node as MacroExpandExpr)) { return markMacro(node, expansion.invocation) }
            if (let Some(expansion) <- (node as MacroExpandDecl)) { return markMacro(node, expansion.invocation) }
            if (let Some(expansion) <- (node as MacroExpandParam)) { return markMacro(node, expansion.invocation) }
            return VisitAction.WALK_CHILDREN
        }).Walk() } catch (e: Exception) { throw Exception("walking syntax: ${e}") }
        let expanded = ArrayList<Lexeme>()
        for (lexeme in ordered) {
            // Only the parser-confirmed type punctuation is split. In expression
            // context >=, >>, >>= and ?? remain the lexer's complete token.
            if (lexeme.text.size > 1 && (angles.contains(lexeme.first) ||
                (lexeme.text == "??" && unary.contains(lexeme.first)))) {
                for (i in 0..lexeme.text.size) {
                    let value = lexeme.text[i..i + 1]
                    let kind = if (value == ">") { TokenKind.GT } else if (value == "?") { TokenKind.QUEST } else { TokenKind.ASSIGN }
                    let begin = lexeme.token.Begin() + i
                    expanded.add(Lexeme(Token(kind, value, begin, begin + 1), source))
                }
            } else { expanded.add(lexeme) }
        }
        tokens = expanded.toArray()
        for (i in 1..tokens.size) {
            if (tokens[i].text == "{" && tokens[i - 1].text == "foreign") { blocks.add(tokens[i].first) }
        }
        if (!valid) { diag.EmitCategoryGroup() }
        diag.close()
    }

    func markDeclarations(decls: ArrayList<Decl>, top: Bool): Unit {
        for (i in 0..decls.size) {
            let current = decls[i]
            let begin = FormattingBegin(current)
            addPosition(statements, begin)
            if (i > 0) {
                let previous = decls[i - 1]
                let bothVariables = ((previous as VarDecl).isSome() || (previous as VarWithPatternDecl).isSome()) &&
                    ((current as VarDecl).isSome() || (current as VarWithPatternDecl).isSome())
                if ((top && !bothVariables) || hasBlankBetween(previous, current)) {
                    addPosition(emptyLines, begin)
                }
            }
        }
    }

    func hasBlankBetween(previous: Node, current: Node): Bool {
        let begin = FormattingBegin(current)
        if (begin.line <= previous.end.line + 1) { return false }
        let between = source.buffer[sourceOffset(source, previous.end)..sourceOffset(source, begin)]
        return !between.contains("//") && !between.contains("/*")
    }

    func chainOf(expr: Expr): ArrayList<MemberAccess> {
        let result = ArrayList<MemberAccess>()
        if (let Some(member) <- (expr as MemberAccess)) {
            if (let Some(base) <- member.baseExpr) { result.add(all: chainOf(base)) }
            result.add(member)
        } else if (let Some(call) <- (expr as CallExpr)) {
            if (let Some(base) <- call.baseFunc) { result.add(all: chainOf(base)) }
        } else if (let Some(subscript) <- (expr as SubscriptExpr)) {
            if (let Some(base) <- subscript.baseExpr) { result.add(all: chainOf(base)) }
        }
        return result
    }

    func markMacro(node: Node, invocation: MacroInvocation): VisitAction {
        let begin = sourceOffset(source, node.begin)
        if ((node as MacroExpandDecl).isSome() || (node as MacroExpandParam).isSome()) {
            if (invocation.leftSquarePos.line > 0 && invocation.rightSquarePos.line > 0) { macroAttributes[begin] = invocation }
        }
        if (let Some(decl) <- invocation.decl) {
            let declBegin = FormattingBegin(decl)
            let end = sourceOffset(source, declBegin)
            if (end > begin) {
                opaque[begin] = begin + source.buffer[begin..end].trimAsciiEnd().size
            }
            if ((node as MacroExpandDecl).isSome()) { addPosition(statements, declBegin) }
            return VisitAction.WALK_CHILDREN
        }
        opaque[begin] = sourceOffset(source, node.end)
        return VisitAction.SKIP_CHILDREN
    }

    func selectedRegion(first: Int64, last: Int64): (Int64, Int64) {
        let tracker = RegionFormattingTracker(if (first < 1) { 1 } else { first }, last)
        Walker(input.file, visitPre: { node: Node =>
            if (tracker.ShouldFormat(node)) { tracker.ProcessNodeFormatted(node) }
            return VisitAction.WALK_CHILDREN
        }).Walk()
        return (tracker.shouldFormatBegin.line, tracker.shouldFormatEnd.line)
    }

    func addPosition(target: HashSet<Int64>, position: Position): Unit {
        if (position.line > 0 && position.column > 0) { target.add(sourceOffset(source, position)) }
    }
    func addAngles(left: Position, right: Position): Unit {
        addPosition(angles, left); addPosition(angles, right)
    }

    func sameProgram(other: Syntax): Bool {
        if (!other.valid) { difference = "formatted source failed to parse"; return false }
        if (shape.size != other.shape.size) { difference = "AST size changed"; return false }
        for (i in 0..shape.size) { if (shape[i] != other.shape[i]) { difference = "AST kind changed at ${i}"; return false } }
        let before = ArrayList<Lexeme>(); let after = ArrayList<Lexeme>()
        let commentsBefore = ArrayList<String>(); let commentsAfter = ArrayList<String>()
        for (t in tokens) {
            if (t.token.kind == TokenKind.COMMENT) { commentsBefore.add(commentKey(t.text)) } else { before.add(t) }
        }
        for (t in other.tokens) {
            if (t.token.kind == TokenKind.COMMENT) { commentsAfter.add(commentKey(t.text)) } else { after.add(t) }
        }
        if (commentsBefore.size != commentsAfter.size) { difference = "comment count changed"; return false }
        for (i in 0..commentsBefore.size) { if (commentsBefore[i] != commentsAfter[i]) { difference = "comment text changed at ${i}"; return false } }
        if (before.size != after.size) { difference = "token count changed"; return false }
        for (i in 0..before.size) {
            if (before[i].token.kind != after[i].token.kind || tokenKey(before[i]) != other.tokenKey(after[i])) {
                difference = "token changed at source line ${before[i].token.Begin().line}"; return false
            }
        }
        return true
    }

    func tokenKey(token: Lexeme): String {
        if (let Some(expressions) <- interpolations.get(token.first)) {
            let key = StringBuilder()
            var cursor = token.first
            for (expr in expressions) {
                if (let Some(body) <- expr.block) {
                    let begin = sourceOffset(source, body.begin) + 1
                    let end = sourceOffset(source, body.end) - 1
                    key.append(source.buffer[cursor..begin])
                    let nested = Syntax(this, body)
                    for (i in 1..nested.tokens.size - 1) {
                        let item = nested.tokens[i]
                        let value = if (item.token.kind == TokenKind.COMMENT) { commentKey(item.text) } else { nested.tokenKey(item) }
                        key.append("${value.size}:${value}")
                    }
                    cursor = end
                }
            }
            key.append(source.buffer[cursor..token.last])
            return key.toString()
        }
        return token.text
    }
}

func commentKey(value: String): String {
    if (value.startsWith("//")) { return value.trimAsciiEnd() }
    if (value.size < 4) { return value }
    let doc = value.startsWith("/**") && value.size > 4
    let begin: Int64 = if (doc) { 3 } else { 2 }
    let body = value[begin..value.size - 2]
    if (body.contains("/*")) { return value }
    let lines = body.replace("\r\n", "\n").split("\n", removeEmpty: false)
    var key = ""
    for (i in 0..lines.size) {
        var line = lines[i].trimAscii()
        if (i > 0 && line.startsWith("*")) { line = line[1..].trimAsciiStart() }
        key += "\n" + line
    }
    return (if (doc) { "/**" } else { "/*" }) + key.trimAscii()
}
