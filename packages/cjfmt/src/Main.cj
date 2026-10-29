package cjfmt

import std.fs.*
import std.collection.*

let usage = "Usage:\ncjfmt -f fileName [-o fileName] [-l start:end] [-c config]\ncjfmt -d fileDir [-o fileDir] [-c config]\n-h Show usage\n-v Show version"

func parseFormattingSource(input: String, value: String, stage: String): Syntax {
    try { return Syntax(input, value) }
    catch (e: Exception) { throw Exception("${stage}: ${input}: ${e}") }
}

func formatFile(input: String, output: String, options: Options, args: Arguments): Unit {
    let bytes = File.readFrom(input)
    var raw = ""
    try { raw = String.fromUtf8(bytes) }
    catch (e: Exception) {
        println("Warning: invalid UTF-8; original source retained: ${input}")
        File.writeTo(output, bytes); return
    }
    let bom = if (raw.startsWith("\u{FEFF}")) { "\u{FEFF}" } else { "" }
    let text = raw[bom.size..]
    let syntax = parseFormattingSource(input, text, "reading syntax")
    var formatted = text
    if (syntax.valid) {
        try { formatted = formatSource(syntax, options, args) }
        catch (e: Exception) { throw Exception("rendering: ${input}: ${e}") }
        let checked = parseFormattingSource(input, formatted, "checking formatted syntax")
        if (!syntax.sameProgram(checked)) {
            println("Warning: formatting changed syntax (${syntax.difference}); original source retained: ${input}")
            formatted = text
        }
    } else { println("Warning: cannot parse; original source retained: ${input}") }
    File.writeTo(output, (bom + formatted).toArray())
}

func formatDirectory(input: Path, output: Path, options: Options, args: Arguments, ancestors: HashSet<String>): Unit {
    let identity = canonicalize(input).toString()
    if (ancestors.contains(identity)) { return }
    ancestors.add(identity)
    let entries = ArrayList<FileInfo>()
    Directory.walk(canonicalize(input)) { info => entries.add(info); true }
    for (entry in entries) {
        let source = entry.path
        let target = output.join(source.fileName)
        if (!exists(source)) { continue }
        if (!args.output.isEmpty() && canonicalize(source).toString() == canonicalize(args.output).toString()) { continue }
        let resolved = FileInfo(canonicalize(source))
        if (resolved.isDirectory()) {
            if (ancestors.contains(resolved.path.toString())) { continue }
            if (!exists(target)) { Directory.create(target, recursive: true) }
            formatDirectory(source, target, options, args, ancestors)
        } else if (resolved.isRegular() && source.toString().endsWith(".cj")) {
            formatFile(source.toString(), target.toString(), options, args)
        }
    }
    ancestors.remove(identity)
}

main(args: Array<String>): Int64 {
    try {
        let action = parseArguments(args)
        if (action.help) { println(usage); return 0 }
        if (action.version) { println("cjfmt Version: 1.3.0-alpha.08"); return 0 }
        let options = readOptions(action.config)
        if (action.directory) {
            validatePath(action.input, "*|;&$><`?!\n")
            action.first = 0; action.last = Int64.Max
            let target = if (action.output.isEmpty()) { action.input } else { action.output }
            if (!exists(target)) { Directory.create(target, recursive: true) }
            formatDirectory(Path(action.input), Path(target), options, action, HashSet<String>())
        } else {
            if (!action.input.endsWith(".cj") || action.input.size < 4) {
                throw Exception("CangjieFormat only support Cangjie source code file!")
            }
            var target = action.output
            if (target.isEmpty()) { target = action.input }
            else if (!target.contains(".cj") || target.size < 4) { target += ".cj" }
            formatFile(action.input, target, options, action)
        }
        println("Formatting complete.")
        return 0
    } catch (e: Exception) { eprintln(e.message); return 1 }
}
