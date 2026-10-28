package cjfmt

import cjcj::lex.TokenKind
import cjcj::basic.Unicode
import cjcj::basic.DiagnosticEngine
import cjcj::parse.Parser
import cjcj::ast.Annotation
import std.collection.*

class Layout {
    let syntax: Syntax
    let options: Options
    let mates = HashMap<Int64, Int64>()
    let breakDots = HashSet<Int64>()
    init(syntax: Syntax, options: Options) {
        this.syntax = syntax; this.options = options
        let widths = Array<Int64>(syntax.tokens.size + 1, repeat: 0)
        for (i in 0..syntax.tokens.size) { widths[i + 1] = widths[i] + Unicode.DisplayWidth(syntax.tokens[i].text) }
        for ((chain, chainEnd) in syntax.chains) {
            if (chain.size < 2) { continue }
            let root = chain[chain.size - 1]
            let begin = sourceOffset(syntax.source, root.begin)
            let end = sourceOffset(syntax.source, chainEnd)
            let length = widths[tokenAt(end)] - widths[tokenAt(begin)]
            if ((options.methodChain && chain.size >= options.chainLevel) ||
                (options.chainOverLength && length + options.indentWidth > options.lineLength)) {
                for (member in chain) { breakDots.add(sourceOffset(syntax.source, member.dotPos)) }
            }
        }
        let stack = ArrayList<Int64>()
        for (i in 0..syntax.tokens.size) {
            let t = syntax.tokens[i]
            if (t.text == "(" || t.text == "[" || t.text == "{" ||
                (t.text == "<" && syntax.angles.contains(t.first))) { stack.add(i) }
            else if (t.text == ")" || t.text == "]" || t.text == "}" ||
                (t.text == ">" && syntax.angles.contains(t.first))) {
                if (!stack.isEmpty()) {
                    let open = stack.remove(at: stack.size - 1)
                    mates[open] = i
                }
            }
        }
    }

    func tokenAt(offset: Int64): Int64 {
        var begin: Int64 = 0; var end = syntax.tokens.size
        while (begin < end) {
            let middle = begin + (end - begin) / 2
            if (syntax.tokens[middle].first < offset) { begin = middle + 1 } else { end = middle }
        }
        return begin
    }

    func comment(t: Lexeme): Doc {
        if (t.text.startsWith("//")) { return text(t.text.trimAsciiEnd()) }
        if (!t.text.startsWith("/*") || t.text.size < 4 ||
            t.text[2..t.text.size - 2].contains("/*")) { return text(t.text) }
        let docs = ArrayList<Doc>()
        let docComment = t.text.startsWith("/**") && t.text.size > 4
        let begin: Int64 = if (docComment) { 3 } else { 2 }
        let body = t.text[begin..t.text.size - 2]
        if (body.trimAscii().isEmpty()) { return text(if (t.text == "/**/") { "/**/" } else { openerForEmpty(docComment) }) }
        let lines = body.replace("\r\n", "\n").split("\n", removeEmpty: false)
        let opener = if (docComment) { "/**" } else { "/*" }
        if (lines.size == 1) {
            return text(opener + " " + body.trimAscii() + " */")
        }
        docs.add(text(opener + if (lines[0].trimAscii().isEmpty()) { "" } else { " " + lines[0].trimAscii() }))
        for (i in 1..lines.size) {
            var line = lines[i].trimAscii()
            if (line.startsWith("*")) { line = line[1..].trimAsciiStart() }
            if (i == lines.size - 1 && line.isEmpty()) { break }
            docs.add(hard()); docs.add(text(" *" + if (line.isEmpty()) { "" } else { " " + line }))
        }
        docs.add(hard()); docs.add(text(" */"))
        return concat(docs)
    }

    func literal(t: Lexeme): Doc {
        if (let Some(expressions) <- syntax.interpolations.get(t.first)) {
            let value = StringBuilder()
            var cursor = t.first
            for (expr in expressions) {
                if (let Some(body) <- expr.block) {
                    let begin = sourceOffset(syntax.source, body.begin) + 1
                    let end = sourceOffset(syntax.source, body.end) - 1
                    value.append(syntax.source.buffer[cursor..begin])
                    let nested = Syntax(syntax, body)
                    let layout = Layout(nested, options)
                    var singleLine = !t.text.startsWith("\"\"\"") && !t.text.startsWith("'''" )
                    for (token in nested.tokens) {
                        if (token.token.kind == TokenKind.COMMENT && token.text.startsWith("//")) { singleLine = false }
                    }
                    let doc = layout.sequence(1, nested.tokens.size - 1, false)
                    let renderer = Renderer(options.lineLength, options.lineBreak)
                    value.append(renderer.finish(if (singleLine) { group(flattenLines(doc)) } else { group(doc) }, 0).trimAscii())
                    cursor = end
                }
            }
            value.append(syntax.source.buffer[cursor..t.last])
            return text(value.toString())
        }
        return text(t.text)
    }

    func macroPrefix(t: Lexeme, end: Int64): Doc {
        if (let Some(invocation) <- syntax.macroAttributes.get(t.first)) {
            let begin = sourceOffset(syntax.source, invocation.leftSquarePos)
            let stop = sourceOffset(syntax.source, invocation.rightSquarePos) + 1
            let diag = DiagnosticEngine()
            diag.SetSourceManager(syntax.input.sourceManager)
            let annotation = Annotation()
            let parser = Parser(syntax.source.buffer[begin..stop], diag, syntax.input.sourceManager, pos: invocation.leftSquarePos)
            parser.ParseAnnotationArguments(annotation)
            if (diag.GetErrorCount() == 0) {
                annotation.begin = invocation.leftSquarePos
                annotation.end = invocation.rightSquarePos + 1
                let nested = Syntax(syntax, annotation)
                if (!annotation.args.isEmpty() && invocation.rightSquarePos.line != annotation.args[annotation.args.size - 1].end.line) {
                    nested.multiline.add(begin)
                }
                let layout = Layout(nested, options)
                let parts = ArrayList<Doc>()
                parts.add(text(syntax.source.buffer[t.first..begin]))
                parts.add(layout.sequence(0, nested.tokens.size, false))
                parts.add(text(syntax.source.buffer[stop..end]))
                diag.close()
                return concat(parts)
            }
            diag.close()
        }
        // Macro attributes may be arbitrary tokens. Only a successful public
        // annotation parse permits expression layout; otherwise retain the bytes.
        return text(syntax.source.buffer[t.first..end])
    }

    func separator(previous: Int64, current: Int64, inList: Bool): Doc {
        if (previous < 0) { return text("") }
        let left = syntax.tokens[previous]; let right = syntax.tokens[current]
        let a = left.text; let b = right.text
        if (breakDots.contains(right.first)) { return nest(hard(), options.indentWidth) }
        let gap = syntax.source.buffer[left.last..right.first]
        let lines = right.token.Begin().line - left.token.End().line
        let lineBreak = lines > 0 || gap.contains("\n") || gap.contains("\r")
        if (left.token.kind == TokenKind.COMMENT) {
            if (a.startsWith("//") || lineBreak) { return commentGap(lines) }
            return text(" ")
        }
        if (right.token.kind == TokenKind.COMMENT) {
            return if (lineBreak) { commentGap(lines) } else { text(" ") }
        }
        if (syntax.annotationEnds.contains(left.last)) { return hard() }
        if (syntax.enumPipes.contains(right.first)) { return soft(" ") }
        if (syntax.emptyLines.contains(right.first) && !inList && a != "{") {
            let lines = ArrayList<Doc>(); lines.add(hard()); lines.add(hard()); return concat(lines)
        }
        if (syntax.postfix.contains(right.first)) { return text("") }
        if (syntax.operatorLines.contains(right.first)) { return hard() }
        if (syntax.spacedColons.contains(right.first)) { return text(" ") }
        if (a == "=>" && lineBreak && !inList) { return hard() }
        if (b == "," || b == ";" || b == ")" || b == "]" || b == "." || b == "?." ||
            b == ":" || b == "::" || ((b == "?" || b == "!") && !syntax.unary.contains(right.first))) { return text("") }
        if (a == "." || a == "::" || a == "@" || a == "?." || a == "$" || a == "#") { return text("") }
        if (syntax.unary.contains(left.first)) { return text("") }
        if (syntax.binaryOperators.contains(left.first)) {
            return if (syntax.operatorLines.contains(left.first)) { text(" ") } else { soft(" ") }
        }
        if ((a == "<" && syntax.angles.contains(left.first)) ||
            (b == ">" && syntax.angles.contains(right.first)) ||
            (b == "<" && syntax.angles.contains(right.first))) { return text("") }
        if (a == ",") { return soft(" ") }
        if (a == ";") { return if (inList) { text(" ") } else { hard() } }
        if (b == "(" && !["if", "while", "for", "match", "catch", "synchronized"].contains(a)) { return text("") }
        if (b == "[") { return text("") }
        if (a == "(" || a == "[") { return text("") }
        if (syntax.statements.contains(right.first) && !inList && a != "{" && a != "=>") { return hard() }
        if (lineBreak && !inList && !["else", "catch", "finally", "{", ")", "]"].contains(b) &&
            !["=", "=>", "->", ":", ",", "."].contains(a) &&
            !syntax.binaryOperators.contains(left.first) && !syntax.binaryOperators.contains(right.first) && b != ".") {
            return hard()
        }
        if (a == ".." || a == "..=" || b == ".." || b == "..=") { return text("") }
        return text(" ")
    }

    func sequence(first: Int64, last: Int64, inList: Bool, forced!: Bool = false, skipGroup!: Int64 = -1): Doc {
        let docs = ArrayList<Doc>()
        var i = first
        var previous: Int64 = -1
        while (i < last) {
            let t = syntax.tokens[i]
            docs.add(if (forced && previous >= 0 && syntax.tokens[previous].text == ",") { hard() } else { separator(previous, i, inList) })
            if (t.first != skipGroup) {
                if (let Some(end) <- syntax.enumGroups.get(t.first)) {
                    let stop = tokenAt(end)
                    if (stop > i && stop <= last) {
                        docs.add(group(sequence(i, stop, inList, skipGroup: t.first)))
                        previous = stop - 1; i = stop; continue
                    }
                }
            }
            let binaryEnd = syntax.binaryGroups.get(t.first) ?? t.last
            var groupEnd = i + 1
            while (groupEnd < last && syntax.tokens[groupEnd].first < binaryEnd) { groupEnd++ }
            if (t.first != skipGroup && binaryEnd > t.last && groupEnd <= last && syntax.tokens[groupEnd - 1].last == binaryEnd) {
                docs.add(group(nest(sequence(i, groupEnd, inList, skipGroup: t.first), options.indentWidth)))
                i = groupEnd - 1
            } else if (let Some(end) <- syntax.opaque.get(t.first)) {
                docs.add(macroPrefix(t, end))
                while (i + 1 < last && syntax.tokens[i + 1].first < end) { i++ }
            } else if (t.token.kind == TokenKind.COMMENT) { docs.add(comment(t)) }
            else if (let Some(close) <- mates.get(i)) {
                if (close < last) {
                    let block = t.text == "{" && syntax.blocks.contains(t.first)
                    let forcedList = syntax.multiline.contains(t.first)
                    let inner = sequence(i + 1, close, !block, forced: forcedList)
                    let parts = ArrayList<Doc>()
                    parts.add(text(t.text))
                    if (i + 1 != close) {
                        if (block) {
                            let body = ArrayList<Doc>(); body.add(hard()); body.add(inner)
                            parts.add(nest(concat(body), options.indentWidth)); parts.add(hard())
                        } else {
                            let space = if (t.text == "{") { " " } else { "" }
                            let body = ArrayList<Doc>(); body.add(if (forcedList) { hard() } else { soft(space) }); body.add(inner)
                            parts.add(nest(concat(body), options.indentWidth)); parts.add(if (forcedList) { hard() } else { soft(space) })
                        }
                    }
                    parts.add(text(syntax.tokens[close].text))
                    docs.add(if (block) { concat(parts) } else { group(concat(parts)) })
                    i = close
                } else { docs.add(text(t.text)) }
            } else { docs.add(literal(t)) }
            previous = i; i++
        }
        return concat(docs)
    }
}

func openerForEmpty(docComment: Bool): String { return if (docComment) { "/** */" } else { "/* */" } }

func commentGap(lines: Int64): Doc {
    if (lines < 2) { return hard() }
    let docs = ArrayList<Doc>(); docs.add(hard()); docs.add(hard()); return concat(docs)
}

func formatSource(syntax: Syntax, options: Options, args: Arguments): String {
    if (syntax.tokens.isEmpty()) { return syntax.source.buffer }
    let layout = Layout(syntax, options)
    let renderer = Renderer(options.lineLength, options.lineBreak)
    if (args.first == 0 && args.last == Int64.Max) {
        return renderer.finish(layout.sequence(0, syntax.tokens.size, false), 0).trimAsciiEnd() + options.lineBreak
    }
    if (args.last < 1) { return syntax.source.buffer }
    let source = syntax.source
    let starts = source.lineOffsets
    let selectedRegion = syntax.selectedRegion(args.first, args.last)
    let firstLine = selectedRegion[0]
    if (firstLine > starts.size) { return source.buffer }
    let begin = starts[firstLine - 1]
    let end = if (selectedRegion[1] < starts.size) { starts[selectedRegion[1]] } else { source.buffer.size }
    var first: Int64 = 0; var last: Int64 = 0; var level: Int64 = 0
    while (first < syntax.tokens.size && syntax.tokens[first].last <= begin) {
        let token = syntax.tokens[first]
        if (["{", "(", "["].contains(token.text) || (token.text == "<" && syntax.angles.contains(token.first))) { level++ }
        if (["}", ")", "]"].contains(token.text) || (token.text == ">" && syntax.angles.contains(token.first))) { level-- }
        first++
    }
    last = first
    while (last < syntax.tokens.size && syntax.tokens[last].first < end) { last++ }
    if (last == first) { return source.buffer }
    // A partial comment or literal is indivisible. Keep the untouched source.
    if (syntax.tokens[first].first < begin || syntax.tokens[last - 1].last > end) {
        return formatSelectedComments(syntax, layout, options, args)
    }
    if (["}", ")", "]", ">"].contains(syntax.tokens[first].text)) { level-- }
    let selected = renderer.finish(layout.sequence(first, last, false), level * options.indentWidth).trimAsciiEnd()
    return source.buffer[..begin] + selected + options.lineBreak + source.buffer[end..]
}

func formatSelectedComments(syntax: Syntax, layout: Layout, options: Options, args: Arguments): String {
    var output = syntax.source.buffer
    var i = syntax.tokens.size - 1
    while (i >= 0) {
        let token = syntax.tokens[i]
        if (token.token.kind == TokenKind.COMMENT && token.text.contains("\n") &&
            token.token.Begin().line <= args.last && token.token.End().line >= args.first) {
            let indent = token.token.Begin().column - 1
            let replacement = Renderer(options.lineLength, options.lineBreak).finish(layout.comment(token), indent)
            output = output[..token.first] + replacement[indent..] + output[token.last..]
        }
        i--
    }
    return output
}
