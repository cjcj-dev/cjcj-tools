// Copyright (c) Huawei Technologies Co., Ltd. 2025-2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof
import std.collection.*
import std.convert.*

func help(): Unit {
    println("Usage: cjprof [--help] COMMAND [ARGS]\n\nThe supported commands are:\n  -v        Print version of cjprof\n  heap      Dump heap into a dump file or analyze the heap dump file\n  record    Run a command and record its profile data into data file\n  report    Read profile data file and display the profile")
}
func heapHelp(): Unit {
    println("Usage: cjprof heap [options]\n  -d, --dump PID         request live runtime heap dump\n  -o, --output FILE      dump destination (default cjprof.data)\n  -i, --input FILE       input dump file (default cjprof.data)\n  -t, --show-thread      show threads and stacks\n  --show-reference[=NAMES] show outgoing references, names separated by ;\n  --incoming-reference   show incoming references\n  -D, --depth N          maximum reference depth (default 10)\n  -V, --verbose          parser information\n  --json                 structured heap analysis")
}
func heap(args: Array<String>): Int64 {
    var input = "cjprof.data"; var output = "cjprof.data"; var pid: Int32 = 0
    var threads = false; var refs = false; var incoming = false; var verbose = false; var json = false
    var http = false; var port: UInt16 = 8080
    var names = ""; var depth: Int64 = 10
    let parsed=parseCli(args,[CliSpec("depth","D",1),CliSpec("dump","d",1),CliSpec("dump-report","",2),
        CliSpec("help","h",0),CliSpec("incoming-reference","",0),CliSpec("input","i",1),CliSpec("output","o",1),
        CliSpec("show-reference","",2),CliSpec("show-thread","t",0),CliSpec("verbose","V",0),CliSpec("legacy-r","r",2),CliSpec("json","",0)])
    if(!parsed.operands.isEmpty()) { throw IllegalArgumentException("unexpected heap operand ${parsed.operands[0]}") }
    for(option in parsed.options) {
        let value=option.value ?? ""
        match(option.name) {
            case "help" => heapHelp(); return 1
            case "input" => input=value
            case "output" => output=value
            case "dump" => let id=cliPositive(value); if(id>2147483647) { throw IllegalArgumentException("Invalid pid") }; pid=Int32(id)
            case "depth" =>
                try { let d=cliPositive(value); if(d>2147483647) { throw IllegalArgumentException("depth") }; depth=Int64(d) }
                catch(_: Exception) { println("warning: Invalid depth value, use the default value (${depth}).") }
            case "show-thread" => threads=true
            case "show-reference" => refs=true; names=value
            case "incoming-reference" => incoming=true
            case "verbose" => verbose=true
            case "json" => json=true
            case "dump-report" =>
                http=true
                if(option.value.isSome()) { try { let p=cliPositive(value); if(p<=65535) { port=UInt16(p) } } catch(_: Exception) {} }
            case _ => throw IllegalArgumentException("unsupported heap option ${option.name}")
        }
    }
    if (pid != 0) { return dumpHeap(pid,output) }
    if (http) {
        var cached: Option<Analysis> = None
        try { cached = ProfileCache.load(input); println("DatabaseCache::load: ${input}.cjprof.db") } catch (_: Exception) { }
        let a = cached ?? Analysis(Profile.load(input))
        if (cached.isNone()) {
            try { ProfileCache.save(input, a); println("Cache save done: ${input}.cjprof.db") }
            catch (e: Exception) { println("warning: cache save failed: ${e.message}") }
        }
        startHttp(a, port); return 0
    }
    let p = Profile.load(input)
    let a = Analysis(p)
    if (json) { println(a.json()); return 0 }
    if (verbose) { println("[PROFILE] version=${p.version} idSize=${p.idSize} objects=${a.nodes.size}") }
    if (!threads && !refs) { a.showObjects() }
    if (threads) { a.showThreads() }
    if (refs) { a.showReferences(names, depth, incoming) }
    return 0
}
main(args: Array<String>): Int64 {
    try {
        if (args.isEmpty()) { help(); return 0 }
        match (args[0]) {
            case "-v" | "--version" => println("Cangjie Profile: 1.3.0-alpha.08"); return 0
            case "heap" => return heap(args)
            case "report" => return report(args)
            case "record" => return record(args)
            case _ => help(); return 0
        }
    } catch (e: Exception) { println("error: ${e.message}"); return 1 }
}
