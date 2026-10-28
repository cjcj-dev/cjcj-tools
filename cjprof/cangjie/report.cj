// Copyright (c) Huawei Technologies Co., Ltd. 2025-2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof
import std.collection.*
import std.convert.*
import std.fs.*
import std.sort.*

func percent(part: UInt64, total: UInt64): String {
    let p: UInt64 = if (total == 0) { 0 } else { (part*10000 + total/2)/total }
    return "${p/100}." + if (p%100 < 10) { "0" } else { "" } + (p%100).toString()
}
func xml(s: String): String {
    s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&#39;")
}
func staticRoot(): String {
    let parts = canonicalize(Path("/proc/self/exe")).toString().split("/")
    return String.join(parts[0..parts.size-2], delimiter: "/") + "/config/static"
}
class SampleStack {
    let names: Array<String> // leaf first as stored by the recorder
    let count: UInt64
    init(names: Array<String>, count: UInt64) { this.names = names; this.count = count }
}
class FlatCount {
    var children: UInt64 = 0
    var self: UInt64 = 0
}
class FlameNode {
    let name: String
    let children = HashMap<String, FlameNode>()
    var count: UInt64 = 0
    init(name: String) { this.name = name }
}
class SampleReport {
    let stacks = ArrayList<SampleStack>()
    var total: UInt64 = 0
    init(profile: Profile) {
        for ((_, entries) in profile.samples) {
            for ((id, count) in entries) {
                let trace = profile.traces.get(id) ?? throw IllegalArgumentException("missing sample trace ${id}")
                if (trace.frames.isEmpty()) { throw IllegalArgumentException("empty sample trace ${id}") }
                let names = ArrayList<String>()
                for (frameId in trace.frames) {
                    let frame = profile.frames.get(frameId) ?? throw IllegalArgumentException("missing sample frame ${frameId}")
                    names.add(profile.text(frame.name))
                }
                stacks.add(SampleStack(names.toArray(), count)); total += count
            }
        }
        if (stacks.isEmpty() || total == 0) { throw IllegalArgumentException("No sampling data is available.") }
    }
    func flat(): Unit {
        let funcs = HashMap<String, FlatCount>()
        for (stack in stacks) {
            for (name in stack.names) {
                let count = funcs.get(name) ?? FlatCount(); count.children += stack.count; funcs[name] = count
            }
            funcs[stack.names[0]].self += stack.count
            if (stack.names.size == 1) { funcs[stack.names[0]].children -= stack.count }
        }
        let names = funcs.keys().toArray()
        sort(names, by: { a, b =>
            let x = funcs[a]; let y = funcs[b]
            if (x.children != y.children) { y.children.compare(x.children) }
            else if (x.self != y.self) { y.self.compare(x.self) }
            else { a.compare(b) }
        }, stable: true, descending: false)
        println("Children        Self    Symbol\n========    ========    ========")
        for (name in names) {
            let count = funcs[name]
            println(" ${percent(count.children, total)}%     ${percent(count.self, total)}%    ${name}")
        }
    }
    func flame(path: String): Unit {
        let root = FlameNode("all")
        var maxDepth: Int64 = 0
        for (stack in stacks) {
            var node = root; node.count += stack.count
            var i = stack.names.size-1
            while (i >= 0) {
                let name = stack.names[i]; i--
                let child = node.children.get(name) ?? FlameNode(name)
                node.children[name] = child; child.count += stack.count; node = child
            }
            if (stack.names.size+1 > maxDepth) { maxDepth = stack.names.size+1 }
        }
        let height = maxDepth*16+70
        let frames = flameFrames(root, 0, 0, height)
        var template = String.fromUtf8(File.readFrom(staticRoot()+"/flamegraph.svg"))
        let values: Array<(String, String)> = [
            ("width", "1200"), ("height", height.toString()), ("fontsize", "12"),
            ("fontwidth", "0.59"), ("titlesize", "17"), ("xpad", "10"), ("xtitle", "600"),
            ("xdetails", "10"), ("xunzoom", "10"), ("xsearch", "1090"), ("xignorecase", "1174"),
            ("xmatched", "1090"), ("ytoptext", "24"), ("ybottomtext", (height-17).toString()), ("frames", frames)
        ]
        // Build placeholder spellings without Cangjie string interpolation.
        for ((key, value) in values) { template = template.replace("$"+"{"+key+"}", value) }
        File.writeTo(path, template.toArray())
    }
    func flameFrames(node: FlameNode, depth: Int64, start: UInt64, height: Int64): String {
        let width = Float64(node.count)*1180.0/Float64(total)
        let x = 10.0+Float64(start)*1180.0/Float64(total)
        let y = height-34-depth*16-15
        var out = ""
        if (width >= 0.1) {
            out = "<g><title>${xml(node.name)} (${node.count} samples, ${percent(node.count, total)}%)</title><rect x=\"${x}\" y=\"${y}\" width=\"${width}\" height=\"15\" fill=\"rgb(240,${60+depth%8*20},30)\" rx=\"2\" ry=\"2\"/><text x=\"${x+3.0}\" y=\"${y+12}\">${if (width > Float64(node.name.size)*7.08) { xml(node.name) } else { "" }}</text></g>\n"
        }
        let names = node.children.keys().toArray(); sort(names)
        var offset = start
        for (name in names) {
            let child = node.children[name]
            out += flameFrames(child, depth+1, offset, height); offset += child.count
        }
        return out
    }
}
func report(args: Array<String>): Int64 {
    var input = "cjprof.data"; var output = "FlameGraph.svg"; var flame = false
    let parsed=parseCli(args,[CliSpec("flame-graph","F",0),CliSpec("help","h",0),CliSpec("input","i",1),CliSpec("output","o",1)])
    if(!parsed.operands.isEmpty()) { throw IllegalArgumentException("unexpected report operand ${parsed.operands[0]}") }
    for(option in parsed.options) {
        match(option.name) {
            case "help" => println("Usage: cjprof report [-i FILE] [-F] [-o FlameGraph.svg]"); return 1
            case "flame-graph" => flame=true
            case "input" => input=option.value.getOrThrow()
            case "output" => output=option.value.getOrThrow()
            case _ => throw IllegalArgumentException("unsupported report option ${option.name}")
        }
    }
    let r = SampleReport(Profile.load(input))
    if (flame) { r.flame(output) } else { r.flat() }
    return 0
}
