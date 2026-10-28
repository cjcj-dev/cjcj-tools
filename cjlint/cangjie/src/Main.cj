package cjlint

import cjcj::basic.Position
import cjcj::utils.{FileUtil, GetApplicationPath}
import std.fs.File as SourceFile
import std.fs.{Directory, FileInfo, exists}
import std.env.{getStdErr, getVariables, getCommand, getCommandLine}
import std.collection.*
import std.sort.*

func fail(message: String): Nothing { throw Exception(message) }
func errorln(message: String): Unit { getStdErr().write((message + "\n").toArray()) }

let helpText = #"
Usage: cjlint [options]
   -h                    Show usage
   -v                    Show version
   -f <directory>        Source package directory
   -e <patterns>         Exclude paths relative to source directory
   -o <path>             Report file or directory (default name cjReport)
   -r <json|csv>         Report format (default json)
   -c <directory>        Directory containing config/
   -m <directory>        Compiler modules directory
   --import-path <path>  Import search path
"#

class Options {
    var source = ""
    let sources = ArrayList<String>()
    var output = ""
    var format = "json"
    var config = ""
    var modules = ""
    var importPath = ""
    var exclusions = ""
    var applicationRoot = ""
    var showHelp = false
    var showVersion = false
    func parse(args: Array<String>): Unit {
        var index: Int64 = 1
        while (index < args.size) {
            let name = args[index]
            if (name == "-h") { showHelp = true; return }
            if (name == "-v") { showVersion = true; return }
            let valueOptions = ["-f", "-o", "-r", "-c", "-m", "-e", "--import-path"]
            if (!valueOptions.contains(name)) { fail("Illegal option: " + name) }
            if (index + 1 >= args.size || valueOptions.contains(args[index + 1])) { fail("Option requires an argument: " + name) }
            let value = args[index + 1]
            match (name) {
                case "-f" => source = value
                case "-o" => output = value
                case "-r" => format = value
                case "-c" => config = value
                case "-m" => modules = value
                case "-e" => exclusions = value
                case "--import-path" => importPath = value
                case _ => fail("Illegal option: " + name)
            }
            index += 2
        }
        if (source.isEmpty()) { fail("Source directory is required: -f <directory>") }
        if (format != "json" && format != "csv") { fail("Unsupported report format: " + format) }
        let inputs = if (exists(source) && FileInfo(source).isDirectory()) { [source] } else { source.split(" ") }
        for (input in inputs) {
            if (input.isEmpty()) { continue }
            if (!exists(input) || !FileInfo(input).isDirectory()) { fail("Source must be a directory: " + input) }
            let absolute = FileUtil.GetAbsPath(input) ?? input
            if (!sources.contains(absolute)) { sources.add(absolute) }
        }
        if (sources.isEmpty()) { fail("Source directory is required: -f <directory>") }
        source = sources[0]
    }
}

func readJson(path: String): JsonValue {
    try { return JsonReader(String.fromUtf8(SourceFile.readFrom(path))).parse() }
    catch (e: Exception) { fail("Cannot read configuration ${path}: ${e.message}") }
}

func loadRules(config: String): HashSet<String> {
    let root = readJson(FileUtil.JoinPath(config, "config/cjlint_rule_list.json"))
    if (root.kind != "object") { fail("Rule configuration must be a JSON object") }
    let list = root.field("RuleList")
    if (list.kind != "array") { fail("RuleList must be a JSON array") }
    let selected = HashSet<String>()
    for (item in list.items) {
        let id = item.text().toAsciiUpper()
        if (!allRuleIds.contains(id)) { fail("Unknown rule: " + id) }
        selected.add(id)
    }
    let missing = ArrayList<String>()
    for (id in allRuleIds) {
        if (selected.contains(id) && !portedRuleIds.contains(id) && !resolvedTypeRuleIds.contains(id) && !dataflowRuleIds.contains(id)) { missing.add(id) }
    }
    if (!missing.isEmpty()) {
        fail("Selected rules still require implementation/frontend integration: " + String.join(missing.toArray(), delimiter: ", "))
    }
    return selected
}

// Glob matching is only for file-selection controls; it never analyzes source.
func globMatch(pattern: Array<UInt8>, text: Array<UInt8>, p: Int64, t: Int64): Bool {
    if (p == pattern.size) { return t == text.size }
    if (pattern[p] == b'*') {
        var next = p + 1
        let recursive = next < pattern.size && pattern[next] == b'*'
        if (recursive) { next++ }
        if (recursive && next < pattern.size && pattern[next] == b'/' && globMatch(pattern, text, next + 1, t)) {
            return true
        }
        var end = t
        while (true) {
            if (globMatch(pattern, text, next, end)) { return true }
            if (end == text.size || (!recursive && text[end] == b'/')) { return false }
            end++
        }
    }
    if (t == text.size) { return false }
    if (pattern[p] == b'?') {
        return text[t] != b'/' && globMatch(pattern, text, p + 1, t + 1)
    }
    return pattern[p] == text[t] && globMatch(pattern, text, p + 1, t + 1)
}

func collectSources(directory: String, files: ArrayList<String>): Unit {
    // Errors propagate. An unreadable directory must never turn into a clean report.
    for (entry in Directory.readFrom(directory)) {
        if (entry.isSymbolicLink()) { continue }
        let path = FileUtil.JoinPath(directory, entry.name)
        if (entry.isDirectory()) { collectSources(path, files) }
        else if (entry.isRegular() && entry.name.endsWith(".cj")) { files.add(path) }
    }
}

func run(options: Options): Int64 {
    let selected = loadRules(options.config)
    let selection = SourceSelection(options)
    let controls = DiagnosticControls(options.config)
    let files = ArrayList<String>()
    for (directory in options.sources) { collectSources(directory, files) }
    if (files.isEmpty()) { fail("No Cangjie source files found in " + options.source) }
    let sorted = files.toArray()
    sort(sorted)
    let findings = ArrayList<Finding>()
    let visited = HashSet<String>()
    let inputs = ArrayList<String>()
    var invalidEncoding = false
    for (path in sorted) {
        if (visited.contains(path)) { continue }
        visited.add(path)
        if (!selection.selected(path)) { continue }
        let bytes = SourceFile.readFrom(path)
        if (!validSourceUtf8(bytes)) {
            if (!selected.contains("G.FMT.01")) { fail("Source is not valid UTF-8: " + path) }
            let point = Position(0, 1, 1)
            findings.add(Finding(path, point, point, "G_FMT_01_encoding_UTF_8_information", [""]))
            errorln("cjlint: Source is not valid UTF-8: " + path)
            invalidEncoding = true
            continue
        }
        inputs.add(path)
    }
    var frontendSucceeded = true
    if (!inputs.isEmpty()) { frontendSucceeded = analyzeWithFrontend(options, selected, inputs, findings, controls) }
    let outputFindings = normalizeFindings(findings)
    // Do not append to a previous JSON array: a second invocation replaces it.
    if (!options.output.isEmpty()) {
        var output = options.output
        if (output.endsWith("/") || (exists(output) && FileInfo(output).isDirectory())) {
            output = FileUtil.JoinPath(output, "cjReport")
        }
        if (!output.endsWith("." + options.format)) { output += "." + options.format }
        SourceFile.writeTo(output, renderReport(outputFindings, options.format).toArray())
    } else {
        for (finding in outputFindings) {
            println("${finding.file}:${finding.begin.line}:${finding.begin.column}: ${finding.description}")
        }
    }
    return if (invalidEncoding || !frontendSucceeded) { 1 } else { 0 }
}

main(): Int64 {
    try {
        let command = getCommand()
        let rawArgs = getCommandLine()
        let argumentList = ArrayList<String>()
        if (rawArgs.isEmpty() || rawArgs[0] != command) { argumentList.add(command) }
        for (argument in rawArgs) { argumentList.add(argument) }
        let args = argumentList.toArray()
        if (args.size <= 1) { println(helpText); return 0 }
        let options = Options()
        options.parse(args)
        if (options.showHelp) { println(helpText); return 0 }
        if (options.showVersion) { println("cjlint 1.3.0-alpha.08 (Cangjie)"); return 0 }
        let env = HashMap<String, String>()
        for ((key, value) in getVariables()) { env[key] = value }
        let executable = GetApplicationPath(args[0], env) ?? fail("Cannot resolve executable path")
        options.applicationRoot = FileUtil.GetDirPath(FileUtil.GetDirPath(executable))
        if (options.config.isEmpty()) { options.config = options.applicationRoot }
        return run(options)
    } catch (e: Exception) {
        errorln("cjlint: " + e.message)
        return 1
    }
}
