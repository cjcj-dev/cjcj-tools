// Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof
import std.collection.*
import std.env.*
import std.convert.*

class CliSpec {
    let name: String
    let abbrev: String
    let arity: Int64 // getopt: 0=no_argument, 1=required_argument, 2=optional_argument
    init(name: String, abbrev: String, arity: Int64) { this.name=name; this.abbrev=abbrev; this.arity=arity }
}
class CliArg {
    let name: String
    let value: Option<String>
    init(name: String, value: Option<String>) { this.name=name; this.value=value }
}
class CliArgs {
    let options=ArrayList<CliArg>()
    let operands=ArrayList<String>()
}
// GNU getopt_long semantics used by the fixed Linux Commands/*.cpp: unique
// long abbreviations, clustered short options, required attached/separate
// values, attached-only optional values, permutation, POSIX mode and --.
func parseCli(args: Array<String>, specs: Array<CliSpec>): CliArgs {
    let result=CliArgs(); var i: Int64=1; var ended=false
    let posix=getVariable("POSIXLY_CORRECT").isSome()
    while(i<args.size) {
        let arg=args[i]
        if(ended) { result.operands.add(arg); i++; continue }
        if(arg=="--") { ended=true; i++; continue }
        if(!arg.startsWith("-") || arg=="-") {
            result.operands.add(arg); if(posix) { ended=true }; i++; continue
        }
        if(arg.startsWith("--")) {
            let parts=arg[2..arg.size].split("=",2)
            var exact: Option<CliSpec>=None; let matches=ArrayList<CliSpec>()
            for(spec in specs where !spec.name.startsWith("legacy-")) {
                if(spec.name==parts[0]) { exact=spec; break }
                if(spec.name.startsWith(parts[0])) { matches.add(spec) }
            }
            let spec=exact ?? if(matches.size==1) { matches[0] } else {
                throw IllegalArgumentException("unknown or ambiguous option ${arg}")
            }
            var value: Option<String>=None
            if(parts.size==2) {
                if(spec.arity==0) { throw IllegalArgumentException("option --${spec.name} takes no argument") }
                value=parts[1]
            } else if(spec.arity==1) {
                i++; if(i>=args.size) { throw IllegalArgumentException("missing argument for --${spec.name}") }
                value=args[i]
            }
            result.options.add(CliArg(spec.name,value))
        } else {
            var at: Int64=1
            while(at<arg.size) {
                let letter=arg[at..at+1]; var selected: Option<CliSpec>=None
                for(spec in specs where spec.abbrev==letter) { selected=spec; break }
                let spec=selected ?? throw IllegalArgumentException("unsupported option -${letter}")
                var value: Option<String>=None
                if(spec.arity!=0) {
                    if(at+1<arg.size) { value=arg[at+1..arg.size] }
                    else if(spec.arity==1) {
                        i++; if(i>=args.size) { throw IllegalArgumentException("missing argument for -${letter}") }
                        value=args[i]
                    }
                    at=arg.size
                } else { at++ }
                result.options.add(CliArg(spec.name,value))
            }
        }
        i++
    }
    return result
}
// The fixed strtol(...,10) accepts leading ASCII whitespace and +, rejects
// trailing junk/whitespace and signed-long overflow. These options need >0.
func cliPositive(text: String): UInt64 {
    let bytes=text.toArray(); var at: Int64=0
    while(at<bytes.size && (bytes[at]==32 || (bytes[at]>=9 && bytes[at]<=13))) { at++ }
    if(at<bytes.size && bytes[at]==43) { at++ }
    if(at==bytes.size) { throw IllegalArgumentException("invalid positive integer") }
    for(i in at..bytes.size where bytes[i]<48 || bytes[i]>57) { throw IllegalArgumentException("invalid positive integer") }
    let value=UInt64.parse(String.fromUtf8(bytes[at..bytes.size]))
    if(value==0 || value>UInt64(Int64.Max)) { throw IllegalArgumentException("positive integer outside signed long range") }
    return value
}
