package cjhead

import std.collection.*
import std.env.getVariable
import std.regex.*
import cjcj::utils.FileUtil

let helpText = "Usage:  cjhead [OPTION...]\n\nOPTION:\n  -i,              Input file or directory\n  -o,              Output directory or file (default: .)\n  -p,              Merge each package into one .cj.d file\n  --import-path,   Cjo path to scan (repeatable)\n  --macro-path,    Macro path to resolve the macro (repeatable)\n  --exclude,       File of exclusion regular expressions\n  -h,              Print help\n"

class HeadOptions {
    var input = ""
    var output = "."
    var packageMode = false
    var help = false
    let importPaths = ArrayList<String>()
    let macroPaths = ArrayList<String>()
    let excludes = ArrayList<Regex>()

    func parse(args: Array<String>): Unit {
        if (args.isEmpty()) { help = true; return }
        var i: Int64 = 0
        while (i < args.size) {
            let arg = args[i]
            if (arg == "-h") { help = true; return }
            if (arg == "-p") { packageMode = true; i++; continue }
            if (!["-i", "-o", "--import-path", "--macro-path", "--exclude"].contains(arg)) {
                throw Exception("Unknown option: " + arg)
            }
            if (i + 1 >= args.size) { throw Exception("Missing value for " + arg) }
            let value = args[i + 1]
            if (arg == "-o") { output = value }
            else {
                let path = FileUtil.GetAbsPath(value) ?? throw Exception("Invalid argument value: " + value)
                if (arg == "-i") { input = path }
                if (arg == "--import-path") { importPaths.add(path) }
                if (arg == "--macro-path") { macroPaths.add(path) }
                if (arg == "--exclude") {
                    let (ok, content, reason) = readText(path)
                    if (!ok) { throw Exception(reason) }
                    for (line in content.split("\n")) {
                        let pattern = line.trimAsciiEnd()
                        if (pattern.isEmpty()) { continue }
                        try { excludes.add(Regex(pattern)) }
                        catch (e: Exception) { println("invalid regex : " + pattern + " " + e.message) }
                    }
                }
            }
            i += 2
        }
        if (input.isEmpty()) { throw Exception("Missing input: -i <file or directory>") }
        if (output.isEmpty()) { throw Exception("Empty output path") }
        if ((getVariable("CANGJIE_HOME") ?? "").isEmpty()) {
            throw Exception("can not find CANGJIE_HOME, please setup CANGJIE_HOME")
        }
    }

    func excluded(path: String): Bool {
        for (pattern in excludes) {
            if (pattern.matcher(path).find().isSome()) { return true }
        }
        return false
    }
}
