package cjcompat

import std.collection.*
import std.env.*
import std.fs.Directory
import cjcj::utils.FileUtil
import cjcj::basic.CANGJIE_VERSION

class Options {
    var oldPath = ""
    var newPath = ""
    var api = false
    var abi = false
    var debug = false
    var end = false
    let paths = ArrayList<String>()
    init() {}
}

func Help(): Unit {
    println("Usage: cjcompat --old /path/to/old.cjo --new /path/to/new.cjo [--api] [--abi] [--import-path /path]")
    println("Options:\n   -h                      Show usage\n   -v                      Show version\n   --old <value>           Old library CJO\n   --new <value>           New library CJO\n   --import-path <value>   Add CJO search path (repeatable)\n   --api                   Enforce API compatibility\n   --abi                   Enforce ABI compatibility")
}

func ParseOptions(args: Array<String>): Options {
    let opts = Options()
    let sdk = getVariable("CANGJIE_HOME") ?? ""
    if (sdk.isEmpty() || !FileUtil.IsDir(sdk)) {
        throw Exception("Can not find realpath of CANGJIE_HOME, please setup CANGJIE_HOME")
    }
    if (args.isEmpty()) { Help(); opts.end = true; return opts }
    var index: Int64 = 0
    while (index < args.size) {
        let arg = args[index]
        match (arg) {
            case "-h" => Help(); opts.end = true; return opts
            case "-v" => println("Cangjie Compliance: 1.3.0-alpha.08\nCangjie Compiler: " + CANGJIE_VERSION)
                opts.end = true; return opts
            case "--api" => opts.api = true
            case "--abi" => opts.abi = true
            case "--printDebugInfo" => opts.debug = true
            case "--old" | "--new" | "--import-path" =>
                index++
                if (index >= args.size || args[index].startsWith("--")) {
                    throw Exception("Option that requires an argument: " + arg)
                }
                let value = args[index]
                if (arg == "--old") {
                    if (!opts.oldPath.isEmpty()) { throw Exception("Argument: --old, used more than once!") }
                    opts.oldPath = value
                } else if (arg == "--new") {
                    if (!opts.newPath.isEmpty()) { throw Exception("Argument: --new, used more than once!") }
                    opts.newPath = value
                } else { opts.paths.add(value) }
            case _ => throw Exception("Illegal option: " + arg)
        }
        index++
    }
    if (!opts.oldPath.endsWith(".cjo")) { throw Exception("Essential argument --old wrong or missing!") }
    if (!opts.newPath.endsWith(".cjo")) { throw Exception("Essential argument --new wrong or missing!") }
    if (!opts.api && !opts.abi) { opts.api = true; opts.abi = true }
    let envPaths = getVariable("CANGJIE_PATH") ?? ""
    for (value in envPaths.split(":")) { if (!value.isEmpty()) { opts.paths.add(value) } }
    let modules = sdk + "/modules"
    if (FileUtil.IsDir(modules)) {
        opts.paths.add(modules)
        for (entry in Directory.readFrom(modules)) {
            if (entry.isDirectory()) { opts.paths.add(entry.path.toString()) }
        }
    }
    return opts
}
