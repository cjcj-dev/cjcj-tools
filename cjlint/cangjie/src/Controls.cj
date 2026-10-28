package cjlint

import cjcj::lex.Lexer
import cjcj::basic.{DiagnosticEngine, SourceManager}
import cjcj::utils.FileUtil
import std.fs.{File, exists}
import std.collection.*

class PathExclusion {
    let base: String
    let pattern: String
    let include: Bool
    let directory: Bool
    let anchored: Bool
    init(base: String, text: String) {
        this.base = base
        var value = text.trimAscii()
        include = value.startsWith("!")
        if (include) { value = value[1..].trimAscii() }
        if (value.contains("..")) { fail("Exclusion must not contain '..': " + text) }
        value = value.replace("\\", "/").replace("/./", "/").replace("//", "/")
        if (value.startsWith("./")) { value = value[1..] }
        directory = value.endsWith("/") || value == "."
        let withoutTrailing = if (value.endsWith("/")) { value[..value.size - 1] } else { value }
        anchored = withoutTrailing.contains("/")
        if (value.startsWith("/")) { value = value[1..] }
        if (value.endsWith("/")) { value = value[..value.size - 1] }
        pattern = if (value == ".") { "**" } else { value }
    }
    func matches(path: String): Bool {
        if (!path.startsWith(base + "/")) { return false }
        let relative = path[base.size + 1..]
        let segments = relative.split("/")
        let limit = if (directory) { segments.size - 1 } else { segments.size }
        for (start in 0..segments.size) {
            if (anchored && start > 0) { break }
            var candidate = ""
            for (end in start..limit) {
                if (end > start) { candidate += "/" }
                candidate += segments[end]
                if (globMatch(pattern.toArray(), candidate.toArray(), 0, 0)) { return true }
            }
        }
        return false
    }
}

class SourceSelection {
    let rules = ArrayList<PathExclusion>()
    var explicitConfig = false
    init(options: Options) {
        for (text in options.exclusions.split(" ")) {
            if (text.trimAscii().isEmpty()) { continue }
            if (text.endsWith(".cfg")) {
                explicitConfig = true
                loadFile(FileUtil.JoinPath(options.source, text), true)
            } else { add(options.source, text) }
        }
        if (!explicitConfig) { loadFile(FileUtil.JoinPath(options.source, "cjlint_file_exclude.cfg"), false) }
    }
    func add(base: String, text: String): Unit {
        let trimmed = text.trimAscii()
        if (trimmed.isEmpty() || trimmed.startsWith("#")) { return }
        rules.add(PathExclusion(base, trimmed))
    }
    func loadFile(file: String, required: Bool): Unit {
        if (!exists(file)) {
            if (required) { fail("Cannot read exclusion config: " + file) }
            return
        }
        let absolute = FileUtil.GetAbsPath(file) ?? file
        for (line in String.fromUtf8(File.readFrom(absolute)).split("\n")) { add(FileUtil.GetDirPath(absolute), line) }
    }
    func selected(path: String): Bool {
        var index = rules.size - 1
        while (index >= 0) {
            if (!rules[index].matches(path)) { index--; continue }
            if (!rules[index].include) { return false }
            index--
            while (index >= 0) {
                if (rules[index].directory && rules[index].matches(path)) { return false }
                index--
            }
            return true
        }
        return true
    }
}

class IgnoreDirective {
    let line: Int64
    let rules: HashSet<String>
    var end: Int64 = 0
    let region: Bool
    init(line: Int64, rules: HashSet<String>, region: Bool) {
        this.line = line; this.rules = rules; this.region = region
    }
}

class DiagnosticControls {
    let excludes: JsonValue
    init(config: String) {
        let file = FileUtil.JoinPath(config, "config/exclude_lists.json")
        excludes = if (exists(file)) { readJson(file) } else { JsonValue("object") }
        if (excludes.kind != "object") { fail("Diagnostic exclusion config must be an object") }
    }
    func directives(source: String): ArrayList<IgnoreDirective> {
        let lexer = Lexer(source, DiagnosticEngine(), SourceManager())
        lexer.GetTokens()
        let output = ArrayList<IgnoreDirective>()
        let stack = ArrayList<IgnoreDirective>()
        for (comment in lexer.GetComments()) {
            if (let Some(index) <- comment.Value().indexOf("cjlint-ignore")) {
                let text = comment.Value()[index..].split("\n")[0].replace("\t", " ")
                if (text != "cjlint-ignore" && !text.startsWith("cjlint-ignore ")) { continue }
                let rules = HashSet<String>()
                var start = false
                var end = false
                for (word in text.split(" ")) {
                    if (word == "-start") { start = true }
                    else if (word == "-end") { end = true }
                    else if (word.startsWith("!")) {
                        let rule = word[1..].replace("*/", "")
                        if (allRuleIds.contains(rule)) { rules.add(rule) }
                    }
                }
                let directive = IgnoreDirective(comment.Begin().line, rules, start)
                if (start) { stack.add(directive) }
                else if (end && !stack.isEmpty()) {
                    let first = stack.remove(at: stack.size - 1)
                    if (first.line < directive.line) { first.end = directive.line; output.add(first) }
                } else { output.add(directive) }
            }
        }
        return output
    }
    func retain(finding: Finding, ignores: ArrayList<IgnoreDirective>): Bool {
        let id = finding.description.split(":")[0]
        for (directive in ignores) {
            if (directive.rules.contains(id) && (finding.begin.line == directive.line ||
                (directive.end > 0 && finding.begin.line > directive.line && finding.begin.line < directive.end))) { return false }
        }
        if (let Some(list) <- excludes.fields.get(id)) {
            if (list.kind != "array") { fail("Diagnostic exclusion list must be an array: " + id) }
            for (item in list.items) {
                if (item.kind != "object") { fail("Diagnostic exclusion must be an object: " + id) }
                let path = if (let Some(value) <- item.fields.get("path")) { value.text().replace("\\", "/") } else { "" }
                let line = if (let Some(value) <- item.fields.get("line")) { value.text() } else { "" }
                let column = if (let Some(value) <- item.fields.get("column")) { value.text() } else { "" }
                if (!column.isEmpty() && column != finding.begin.column.toString()) { continue }
                if (path.endsWith(".cj") && finding.file.contains(path) && line == finding.begin.line.toString()) { return false }
            }
        }
        return true
    }
}
