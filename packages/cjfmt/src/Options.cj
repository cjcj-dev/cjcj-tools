package cjfmt

import std.collection.*
import std.convert.*
import std.fs.*
import std.env.*

class Options {
    var indentWidth: Int64 = 4
    var lineLength: Int64 = 120
    var lineBreak: String = "\n"
    var methodChain: Bool = false
    var chainLevel: Int64 = 5
    var chainOverLength: Bool = true
}

class Arguments {
    var input: String = ""
    var output: String = ""
    var directory: Bool = false
    var config: String = ""
    var first: Int64 = 0
    var last: Int64 = Int64.Max
    var help: Bool = false
    var version: Bool = false
}

func parseArguments(args: Array<String>): Arguments {
    let result = Arguments()
    var file = ""; var directory = ""; var fileOutput = ""; var directoryOutput = ""
    var fileOption = false
    var invalid: Option<String> = None
    var i: Int64 = 0
    while (i < args.size) {
        let arg = args[i]
        if (arg == "--") {
            if (i + 1 < args.size) { invalid = Some(args[i + 1]) }
            break
        }
        if (arg.size < 2 || !arg.startsWith("-")) { invalid = Some(arg); i++; continue }
        let option = arg[..2]
        if (option == "-h") { result.help = true; return result }
        if (option == "-v") { result.version = true; return result }
        if (!["-f", "-d", "-o", "-c", "-l"].contains(option) || (arg.size == 2 && i + 1 >= args.size)) {
            throw Exception("invalid option or option requires an argument: ${arg}")
        }
        if (arg.size == 2) { i++ }
        let value = if (arg.size == 2) { args[i] } else { arg[2..] }
        match (option) {
            case "-f" => file = value; fileOption = true
            case "-d" =>
                if (!exists(value)) { throw Exception("Source file path not exist!") }
                directory = value
            case "-o" =>
                if (fileOption) { fileOutput = value; fileOption = false }
                else { validatePath(value, "*?\"<>|"); directoryOutput = value }
            case "-c" => result.config = value
            case "-l" =>
                let parts = value.split(":", removeEmpty: false)
                if (parts.size != 2 || parts[0].isEmpty() || parts[1].isEmpty()) {
                    throw Exception("Invalid region format, use <start>:<end>")
                }
                for (part in parts) {
                    for (b in part.toArray()) {
                        if (b < b'0' || b > b'9') { throw Exception("Invalid region format") }
                    }
                }
                result.first = Int64.parse(parts[0]); result.last = Int64.parse(parts[1])
                if (result.first > Int64(Int32.Max) || result.last > Int64(Int32.Max)) {
                    throw Exception("Invalid region format, number out of range")
                }
                if (result.first > result.last) { throw Exception("Invalid region format, start exceeds end") }
            case _ => ()
        }
        i++
    }
    if (let Some(value) <- invalid) { throw Exception("invalid argument: ${value}") }
    result.directory = !directory.isEmpty()
    result.input = if (result.directory) { directory } else { file }
    result.output = if (result.directory) { directoryOutput } else { fileOutput }
    if (result.input.isEmpty()) { throw Exception("Action has no specific file or directory to operate on.") }
    return result
}

func validatePath(value: String, forbidden: String): Unit {
    for (byte in forbidden.toArray()) {
        if (value.toArray().contains(byte)) { throw Exception("The path cannot contain invalid characters: ${forbidden}") }
    }
}

func readOptions(config: String): Options {
    let opts = Options()
    let candidates = ArrayList<String>()
    if (!config.isEmpty()) { candidates.add(config) }
    let home = getVariable("CANGJIE_HOME") ?? ""
    if (!home.isEmpty()) { candidates.add(home + "/tools/config/cangjie-format.toml") }
    var content = ""; var loaded = false
    for (selected in candidates) {
        try {
            content = String.fromUtf8(File.readFrom(selected)); loaded = true; break
        } catch (e: Exception) { println("Warning: cannot read format configuration: ${selected}") }
    }
    if (!loaded) { println("Using built-in formatting options"); return opts }
    let lines = content.split("\n", removeEmpty: false)
    let values = HashMap<String, String>()
    for (line in lines) {
        let comment = line.indexOf("#")
        let text = (if (let Some(index) <- comment) { line[..index] } else { line }).trimAscii()
        if (text.isEmpty()) { continue }
        let equal = text.indexOf("=")
        if (equal.isNone()) { println("Warning: invalid configuration entry"); continue }
        let index = equal.getOrThrow()
        let key = text[..index].trimAscii(); let value = text[index + 1..].trimAscii()
        values[key] = value
    }
    for ((key, value) in values) {
        try {
            match (key) {
                case "indentWidth" =>
                    let n = Int64.parse(value)
                    if (n < 0 || n > 8) { throw Exception("range [0, 8]") }
                    opts.indentWidth = n
                case "linelimitLength" =>
                    let n = Int64.parse(value)
                    if (n < 1 || n > 120) { throw Exception("range [1, 120]") }
                    opts.lineLength = n
                case "lineBreakType" =>
                    if (value != "\"LF\"" && value != "\"CRLF\"") { throw Exception("expected LF or CRLF") }
                    opts.lineBreak = if (value == "\"CRLF\"") { "\r\n" } else { "\n" }
                case "allowMultiLineMethodChain" => opts.methodChain = configBool(value)
                case "multipleLineMethodChainLevel" =>
                    let n = Int64.parse(value)
                    if (n < 2 || n > 10) { throw Exception("range [2, 10]") }
                    opts.chainLevel = n
                case "multipleLineMethodChainOverLineLength" => opts.chainOverLength = configBool(value)
                case _ => ()
            }
        } catch (e: Exception) { println("Warning: ${key}: ${e.message}; built-in option retained") }
    }
    return opts
}

func configBool(value: String): Bool {
    if (value != "true" && value != "false") { throw Exception("expected boolean") }
    return value == "true"
}
