package cjlint

import cjcj::basic.Position
import std.collection.*
import std.sort.*

class Finding {
    let file: String
    let begin: Position
    let end: Position
    let kind: String
    let description: String
    init(file: String, begin: Position, end: Position, kind: String, arguments: Array<String>) {
        this.file = file; this.begin = begin; this.end = end; this.kind = kind
        // Scan only the original format. Inserted argument text is never
        // searched again, even when it contains a literal %s or %d.
        let format = diagnosticMessage(kind)
        let bytes = format.toArray()
        var message = ""
        var start: Int64 = 0
        var cursor: Int64 = 0
        var argument: Int64 = 0
        while (cursor + 1 < bytes.size && argument < arguments.size) {
            if (bytes[cursor] == 37 && (bytes[cursor + 1] == 115 || bytes[cursor + 1] == 100 ||
                bytes[cursor + 1] == 99 || bytes[cursor + 1] == 112)) {
                message += format[start..cursor] + arguments[argument]
                argument++
                cursor += 2
                start = cursor
            } else { cursor++ }
        }
        description = message + format[start..]
    }
    func json(): String {
        return "{\"file\":" + jsonQuote(file) + ",\"line\":${begin.line},\"column\":${begin.column}," +
            "\"endLine\":${end.line},\"endColumn\":${end.column},\"analyzerName\":\"cangjieCodeCheck\"," +
            "\"description\":" + jsonQuote(description) + ",\"defectLevel\":" + jsonQuote(diagnosticLevel(kind)) +
            ",\"defectType\":" + jsonQuote(kind) + ",\"language\":\"cangjie\"}"
    }
    func csv(): String {
        return csvQuote(file) + ",${begin.line},${begin.column},${end.line},${end.column}," +
            csvQuote(description) + "," + csvQuote(kind) + "," + diagnosticLevel(kind) + "\n"
    }
}

// Match the reference diagnostic list before any output consumer: source
// file ID, line, column; distinct diagnostics at one position are inserted
// before earlier ones. File paths disambiguate diagnostics without a real
// frontend file ID (for example invalid UTF-8 rejected before parsing).
func normalizeFindings(findings: ArrayList<Finding>): ArrayList<Finding> {
    let unique = HashSet<String>()
    let indexed = ArrayList<(Finding, Int64)>()
    for (index in 0..findings.size) {
        let finding = findings[index]
        let point = finding.begin
        if (!point.IsZero()) {
            let key = "${point.fileID}/${finding.file.size}:${finding.file}/${point.line}/${point.column}/${finding.description}"
            if (unique.contains(key)) { continue }
            unique.add(key)
        }
        indexed.add((finding, index))
    }
    let ordered = indexed.toArray()
    sort(ordered, lessThan: { left: (Finding, Int64), right: (Finding, Int64) =>
        let a = left[0].begin
        let b = right[0].begin
        if (a.IsZero() || b.IsZero()) {
            if (a.IsZero() != b.IsZero()) { return a.IsZero() }
            return left[1] > right[1]
        }
        if (a.fileID != b.fileID) { return a.fileID < b.fileID }
        if (left[0].file != right[0].file) { return left[0].file < right[0].file }
        if (a.line != b.line) { return a.line < b.line }
        if (a.column != b.column) { return a.column < b.column }
        return left[1] > right[1]
    })
    let result = ArrayList<Finding>()
    for ((finding, _) in ordered) { result.add(finding) }
    return result
}

func csvQuote(value: String): String { return "\"" + value.replace("\"", "\"\"") + "\"" }

func renderReport(findings: ArrayList<Finding>, format: String): String {
    if (format == "csv") {
        var out = "SourceFile,Line,Column,EndLine,EndColumn,Description,DefectType,DefectLevel\n"
        for (finding in findings) { out += finding.csv() }
        return out
    }
    var out = "["
    var first = true
    for (finding in findings) {
        if (!first) { out += "," }; first = false
        out += "\n  " + finding.json()
    }
    return out + "\n]\n"
}
