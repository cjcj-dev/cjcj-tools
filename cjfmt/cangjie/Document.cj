package cjfmt

import std.collection.*
import cjcj::basic.Unicode

class Doc {
    // text, concatenation, indentation, group, soft line, hard line
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
func soft(space: String): Doc { return Doc(4, value: space) }
func hard(): Doc { return Doc(5) }
func flattenLines(doc: Doc): Doc {
    if (doc.kind == 5 || doc.kind == 4) { return text(if (doc.kind == 5) { " " } else { doc.value }) }
    let children = ArrayList<Doc>()
    for (child in doc.children) { children.add(flattenLines(child)) }
    return Doc(doc.kind, value: doc.value, children: children.toArray(), amount: doc.amount)
}
func spaces(count: Int64): String {
    return String.fromUtf8(Array<UInt8>(if (count > 0) { count } else { 0 }, repeat: b' '))
}

class Renderer {
    let width: Int64
    let newline: String
    let result = ArrayList<String>()
    var column: Int64 = 0
    var pendingIndent: Int64 = 0
    var lineStart: Bool = true
    init(width: Int64, newline: String) { this.width = width; this.newline = newline }

    func flatSize(doc: Doc, remaining: Int64): Int64 {
        if (remaining < 0) { return width + 1 }
        if (doc.kind == 5 || doc.value.contains("\n")) { return width + 1 }
        if (doc.kind == 0 || doc.kind == 4) { return Unicode.DisplayWidth(doc.value) }
        var total: Int64 = 0
        for (child in doc.children) {
            total += flatSize(child, remaining - total)
            if (total > remaining) { break }
        }
        return total
    }
    func append(value: String): Unit {
        if (value.isEmpty()) { return }
        if (lineStart) { result.add(spaces(pendingIndent)); column = pendingIndent; lineStart = false }
        result.add(value)
        if (let Some(last) <- value.lastIndexOf("\n")) { column = Unicode.DisplayWidth(value[last + 1..]) }
        else { column += Unicode.DisplayWidth(value) }
    }
    func render(doc: Doc, indent: Int64, flat: Bool): Unit {
        match (doc.kind) {
            case 0 => append(doc.value)
            case 1 => for (child in doc.children) { render(child, indent, flat) }
            case 2 => render(doc.children[0], indent + doc.amount, flat)
            case 3 =>
                let remaining = width - if (lineStart) { pendingIndent } else { column }
                render(doc.children[0], indent, flat || flatSize(doc.children[0], remaining) <= remaining)
            case 4 =>
                if (flat) { append(doc.value) }
                else { result.add(newline); column = 0; pendingIndent = indent; lineStart = true }
            case 5 => result.add(newline); column = 0; pendingIndent = indent; lineStart = true
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
