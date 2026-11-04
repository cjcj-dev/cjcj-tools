package cjfmt

import std.collection.*
import cjcj::basic.Unicode

class Doc {
    // text, concatenation, indentation, semantic group, soft line, hard line,
    // fill, assignment choice. Planning never mutates the source document.
    let kind: Int64
    let value: String
    let children: Array<Doc>
    let amount: Int64
    init(kind: Int64, value!: String = "", children!: Array<Doc> = [], amount!: Int64 = 0) {
        this.kind = kind; this.value = value; this.children = children; this.amount = amount
    }
}

func text(value: String): Doc { return Doc(0, value: value) }
func concat(docs: ArrayList<Doc>): Doc { return Doc(1, children: docs.toArray()) }
func nest(doc: Doc, amount: Int64): Doc { return Doc(2, children: [doc], amount: amount) }
func group(doc: Doc): Doc { return Doc(3, children: [doc]) }
func soft(space: String, penalty!: Int64 = 30): Doc { return Doc(4, value: space, amount: penalty) }
func hard(): Doc { return Doc(5) }
func fill(doc: Doc): Doc { return Doc(6, children: [doc]) }
func choice(doc: Doc, indent: Int64, literal: Bool): Doc {
    return Doc(7, value: if (literal) { "literal" } else { "" }, children: [doc], amount: indent)
}
func flattenLines(doc: Doc): Doc {
    if (doc.kind == 5 || doc.kind == 4) { return text(if (doc.kind == 5) { " " } else { doc.value }) }
    let children = ArrayList<Doc>()
    if (doc.kind == 7) { children.add(text(" ")) }
    for (child in doc.children) { children.add(flattenLines(child)) }
    return Doc(if (doc.kind == 7 || doc.kind == 8) { 1 } else { doc.kind }, value: doc.value, children: children.toArray(), amount: doc.amount)
}
func spaces(count: Int64): String {
    return String.fromUtf8(Array<UInt8>(if (count > 0) { count } else { 0 }, repeat: b' '))
}

class FillItem {
    let docs = ArrayList<Doc>()
    var width: Int64 = 0
    let separator: Doc
    let indent: Int64
    let penalty: Int64
    init(separator: Doc, indent: Int64, penalty: Int64) {
        this.separator = separator; this.indent = indent; this.penalty = penalty
    }
}

class FillCollector {
    let width: Int64
    let items = ArrayList<FillItem>()
    var supported = true
    var visits: Int64 = 0
    init(width: Int64, indent: Int64) { this.width = width; items.add(FillItem(text(""), indent, 0)) }
    func collect(doc: Doc, indent: Int64, protection: Int64): Unit {
        visits++
        if (visits > 131072) { supported = false; return }
        match (doc.kind) {
            case 0 =>
                if (doc.value.contains("\n") || doc.value.contains("\t")) { supported = false; return }
                items[items.size - 1].docs.add(doc)
                items[items.size - 1].width += Unicode.DisplayWidth(doc.value)
            case 4 => items.add(FillItem(doc, indent, doc.amount + protection))
            case 2 => collect(doc.children[0], indent + doc.amount, protection)
            case 1 | 3 | 6 =>
                var next = protection
                if (doc.kind == 3) {
                    // Keep complete nested syntax together when it can fit on
                    // a continuation line; otherwise permit its internal breaks.
                    next += if (Renderer(width, "\n").flatSize(doc, width) + indent <= width) { 1000 } else { 5 }
                }
                for (child in doc.children where supported) { collect(child, indent, next) }
            case _ => supported = false
        }
    }
}

class Renderer {
    let width: Int64
    let newline: String
    let result = ArrayList<String>()
    var column: Int64 = 0
    var pendingIndent: Int64 = 0
    var lineStart: Bool = true
    var lineIndent: Int64 = 0
    init(width: Int64, newline: String) { this.width = width; this.newline = newline }

    func flatSize(doc: Doc, remaining: Int64): Int64 {
        if (remaining < 0) { return width + 1 }
        if (doc.kind == 5 || doc.value.contains("\n") || (doc.kind == 8 && doc.value == "force")) { return width + 1 }
        if (doc.kind == 0 || doc.kind == 4) { return Unicode.DisplayWidth(doc.value) }
        var total: Int64 = if (doc.kind == 7) { 1 } else { 0 }
        for (child in doc.children) {
            total += flatSize(child, remaining - total)
            if (total > remaining) { break }
        }
        return total
    }
    func append(value: String): Unit {
        if (value.isEmpty()) { return }
        if (lineStart) { result.add(spaces(pendingIndent)); column = pendingIndent; lineIndent = pendingIndent; lineStart = false }
        result.add(value)
        // Tabs use output column tab stops, including tabs inside literals.
        let rows = value.split("\n", removeEmpty: false)
        for (row in 0..rows.size) {
            if (row > 0) {
                column = 0
                lineIndent = Unicode.DisplayWidth(rows[row][..rows[row].size - rows[row].trimAsciiStart().size])
            }
            let tabs = rows[row].split("\t", removeEmpty: false)
            for (i in 0..tabs.size) {
                if (i > 0) { column = (column / 8 + 1) * 8 }
                column += Unicode.DisplayWidth(tabs[i])
            }
        }
    }
    func breakLine(indent: Int64): Unit {
        result.add(newline); column = 0; pendingIndent = indent; lineStart = true
    }
    // Following punctuation and comments belong to the current fit budget,
    // up to the next real break opportunity. A multiline leaf is indivisible.
    func inlineWidth(docs: Array<Doc>): Int64 {
        var total: Int64 = 0
        for (doc in docs) {
            if (doc.kind == 4 || doc.kind == 5 || doc.kind == 7) { break }
            if (doc.kind == 0) {
                if (doc.value.isEmpty()) { continue }
                if (doc.value.contains("\t")) { return width + 1 }
                let lines = doc.value.split("\n", removeEmpty: false)
                total += Unicode.DisplayWidth(lines[0])
                if (lines.size > 1) { break }
            } else {
                let measured = inlinePrefix(doc)
                total += measured[0]
                if (measured[1] != 0) { break }
            }
        }
        return total
    }
    func inlinePrefix(doc: Doc): (Int64, Int64) {
        if (doc.kind == 4 || doc.kind == 5 || doc.kind == 7) { return (0, 1) }
        if (doc.kind == 0) {
            if (doc.value.isEmpty()) { return (0, 0) }
            let lines = doc.value.split("\n", removeEmpty: false)
            return (if (doc.value.contains("\t")) { width + 1 } else { Unicode.DisplayWidth(lines[0]) }, if (lines.size > 1) { 1 } else { 0 })
        }
        var total: Int64 = 0
        for (child in doc.children) {
            let part = inlinePrefix(child); total += part[0]
            if (part[1] != 0) { return (total, 1) }
        }
        return (total, 0)
    }
    func renderFill(doc: Doc, indent: Int64, suffix: Array<Doc>): Unit {
        let collector = FillCollector(width, indent)
        collector.collect(doc, indent, 0)
        let items = collector.items
        if (!collector.supported || items.size < 2) { render(doc, indent, false, suffix: suffix); return }
        let count = items.size
        let overflow = Array<Int64>(count + 1, repeat: 0)
        let penalties = Array<Int64>(count + 1, repeat: 0)
        let lines = Array<Int64>(count + 1, repeat: 0)
        let ends = Array<Int64>(count, repeat: count)
        let current = if (lineStart) { pendingIndent } else { column }
        let tail = inlineWidth(suffix)
        var transitions: Int64 = 0
        var start = count - 1
        while (start >= 0) {
            var column = if (start == 0) { current } else { items[start].indent }
            var bestOverflow = Int64.Max; var bestPenalty = Int64.Max; var bestLines = Int64.Max
            for (end in start..count) {
                transitions++
                if (transitions > 131072) { break }
                if (end > start) { column += Unicode.DisplayWidth(items[end].separator.value) }
                column += items[end].width
                let endColumn = column + if (end + 1 == count) { tail } else { 0 }
                let costOverflow = max(0, endColumn - width) + overflow[end + 1]
                let costPenalty = (if (end + 1 < count) { items[end + 1].penalty } else { 0 }) + penalties[end + 1]
                let costLines = 1 + lines[end + 1]
                if (costOverflow < bestOverflow || (costOverflow == bestOverflow &&
                    (costPenalty < bestPenalty || (costPenalty == bestPenalty && costLines <= bestLines)))) {
                    bestOverflow = costOverflow; bestPenalty = costPenalty; bestLines = costLines; ends[start] = end + 1
                }
                if (column > width) { break }
            }
            if (transitions > 131072) { break }
            overflow[start] = bestOverflow; penalties[start] = bestPenalty; lines[start] = bestLines
            start--
        }
        let breaks = HashSet<Int64>()
        if (transitions <= 131072) {
            var next = ends[0]
            while (next < count) { breaks.add(next); next = ends[next] }
        } else {
            // Bounded deterministic fallback for exceptionally large syntax.
            var position = current
            for (i in 0..count) {
                let space = if (i > 0) { Unicode.DisplayWidth(items[i].separator.value) } else { 0 }
                if (i > 0 && position + space + items[i].width + (if (i + 1 == count) { tail } else { 0 }) > width) {
                    breaks.add(i); position = items[i].indent
                } else { position += space }
                position += items[i].width
            }
        }
        for (i in 0..count) {
            if (i > 0) {
                if (breaks.contains(i)) { breakLine(items[i].indent) } else { append(items[i].separator.value) }
            }
            for (leaf in items[i].docs) { render(leaf, items[i].indent, true) }
        }
    }
    func render(doc: Doc, indent: Int64, flat: Bool, suffix!: Array<Doc> = []): Unit {
        match (doc.kind) {
            case 0 => append(doc.value)
            case 1 =>
                for (i in 0..doc.children.size) {
                    let tail = ArrayList<Doc>()
                    for (j in i + 1..doc.children.size) { tail.add(doc.children[j]) }
                    tail.add(all: suffix)
                    render(doc.children[i], indent, flat, suffix: tail.toArray())
                }
            case 2 => render(doc.children[0], indent + doc.amount, flat, suffix: suffix)
            case 3 =>
                let remaining = width - if (lineStart) { pendingIndent } else { column }
                render(doc.children[0], indent, flat || flatSize(doc.children[0], remaining) + inlineWidth(suffix) <= remaining, suffix: suffix)
            case 4 =>
                if (flat) { append(doc.value) }
                else { breakLine(indent) }
            case 5 => breakLine(indent)
            case 6 =>
                if (flat) { render(doc.children[0], indent, true, suffix: suffix) }
                else { renderFill(doc.children[0], indent, suffix) }
            case 7 =>
                let current = if (lineStart) { pendingIndent } else { column }
                let first = inlinePrefix(doc.children[0])[0]
                if (current + 1 + first > width && !(doc.value == "literal" && first > width)) {
                    breakLine(indent + doc.amount)
                } else { append(" ") }
                render(doc.children[0], indent, false, suffix: suffix)
            case 8 =>
                // Render the complete receiver first. Calls and lambdas may
                // change its final column, so source token widths cannot decide
                // the continuation layout of the following member chain.
                render(doc.children[0], indent, flat)
                let rest = ArrayList<Doc>()
                for (i in 1..doc.children.size) { rest.add(doc.children[i]) }
                let current = if (lineStart) { pendingIndent } else { column }
                let expand = doc.value == "force" || (!flat && doc.value == "auto" &&
                    current + flatSize(concat(rest), width) + inlineWidth(suffix) > width)
                for (i in 1..doc.children.size) {
                    if (expand) { breakLine(indent + doc.amount) }
                    let tail = ArrayList<Doc>()
                    if (!expand) { for (j in i + 1..doc.children.size) { tail.add(doc.children[j]) } }
                    tail.add(all: suffix)
                    render(doc.children[i], indent + if (expand) { doc.amount } else { 0 }, flat, suffix: tail.toArray())
                }
            case 9 => render(doc.children[0], lineIndent, flat, suffix: suffix)
            case _ => ()
        }
    }
    func finish(doc: Doc, indent: Int64): String {
        pendingIndent = indent; render(doc, indent, false)
        let output = StringBuilder()
        for (chunk in result) { output.append(chunk) }
        return output.toString()
    }
}
