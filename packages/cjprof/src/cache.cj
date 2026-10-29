// Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof
import std.collection.*
import std.fs.*

class BinaryWriter {
    let bytes = ArrayList<UInt8>()
    func raw(data: Array<UInt8>): Unit { for (b in data) { bytes.add(b) } }
    func number(value: UInt64, n: Int64): Unit {
        var x = value
        for (_ in 0..n) { bytes.add(UInt8(x & 255)); x = x >> 8 }
    }
}
extend Cursor {
    func little(n: Int64): UInt64 {
        var value: UInt64 = 0; var shift: UInt64 = 0
        for (b in take(n)) { value = value | (UInt64(b) << shift); shift += 8 }
        return value
    }
}
class ProfileCache {
    // Binary layout is the existing packed cjprofdb version 2, little endian.
    // This cache is only an HTTP snapshot acceleration artifact.
    static func save(input: String, a: Analysis): Unit {
        let view = HttpView(a)
        let strings = BinaryWriter(); let stringIndex = HashMap<String, UInt64>()
        for (obj in a.nodes where !stringIndex.contains(obj.name)) {
            stringIndex[obj.name] = UInt64(strings.bytes.size); strings.raw(obj.name.toArray()); strings.number(0, 1)
        }
        let sections = Array<BinaryWriter>(8, { _ => BinaryWriter() })
        for (value in [UInt64(536870912), UInt64(a.nodes.size), UInt64(a.profile.roots.size), view.used, view.start, view.end]) { sections[0].number(value, 8) }
        // Class entries are optional for HTTP: object entries contain names/sizes.
        var refs: UInt64 = 0; var children: UInt64 = 0; var domCount: UInt64 = 0
        for (i in 0..a.nodes.size) {
            let obj = a.nodes[i]; let out = sections[2]
            for (value in [obj.id, obj.cls, obj.shallow, obj.id]) { out.number(value, 8) }
            out.number(UInt64(obj.category), 1); out.number(stringIndex[obj.name], 4)
            out.number(if (obj.category == 4) { 1 } else { 0 }, 1); out.number(if (obj.category == 5) { 1 } else { 0 }, 1)
            out.number(refs, 8); out.number(UInt64(obj.children.size), 4)
            for (j in obj.children) { sections[3].number(a.nodes[j].id, 8); refs++ }
            if (a.idom[i+1] < 0) { continue }
            domCount++
            let dom = sections[5]; let parent = a.idom[i+1]
            dom.number(obj.id, 8); dom.number(if (parent <= 0) { 0 } else { a.nodes[parent-1].id }, 8)
            dom.number(obj.retained, 8); dom.number(obj.shallow, 8); dom.number(UInt64(view.depths[i]), 4)
            let kids = view.domChildren.get(i+1) ?? ArrayList<Int64>()
            dom.number(children, 8); dom.number(UInt64(kids.size), 4)
            for (j in kids) { sections[6].number(a.nodes[j].id, 8); children++ }
        }
        for (id in a.profile.roots) {
            let local = a.profile.locals.get(id)
            let kind = a.profile.rootKinds.get(id) ?? 1
            sections[4].number(UInt64(if(kind==3){255}else{kind}), 1); sections[4].number(id, 8)
            sections[4].number(local?[0] ?? 0, 4); sections[4].number(local?[1] ?? 0, 4)
        }
        sections[7].raw(strings.bytes.toArray())
        let counts: Array<UInt64> = [48, 0, UInt64(a.nodes.size), refs, UInt64(a.profile.roots.size), domCount, children, UInt64(strings.bytes.size)]
        let out = BinaryWriter(); out.raw("cjprofdb".toArray()); out.number(2, 4); out.number(144, 4)
        var offset: UInt64 = 144
        for (i in 0..8) { out.number(offset, 8); out.number(counts[i], 8); offset += UInt64(sections[i].bytes.size) }
        for (section in sections) { out.raw(section.bytes.toArray()) }
        let temp = input+".cjprof.db.tmp"
        File.writeTo(temp, out.bytes.toArray())
        rename(temp, to: input+".cjprof.db", overwrite: true)
    }
    static func load(input: String): Analysis {
        let bytes = File.readFrom(input+".cjprof.db"); let c = Cursor(bytes)
        if (String.fromUtf8(c.take(8)) != "cjprofdb" || c.little(4) != 2 || c.little(4) != 144) { throw IllegalArgumentException("invalid cache header") }
        let offsets = Array<Int64>(8, repeat: 0); let counts = Array<Int64>(8, repeat: 0)
        let widths: Array<Int64> = [1, 21, 51, 8, 17, 48, 8, 1]
        for (i in 0..8) {
            let offset = c.little(8); let count = c.little(8)
            if (offset > UInt64(bytes.size) || count > UInt64(bytes.size)/UInt64(widths[i]) || count*UInt64(widths[i]) > UInt64(bytes.size)-offset) { throw IllegalArgumentException("cache section outside file") }
            offsets[i] = Int64(offset); counts[i] = Int64(count)
        }
        let p = Profile()
        let names = HashMap<UInt64, String>()
        let objectRefs = HashMap<UInt64, (Int64, Int64)>()
        let domParents = HashMap<UInt64, UInt64>()
        c.pos = offsets[2]
        for (_ in 0..counts[2]) {
            let id = c.little(8); let obj = HeapObject(id); obj.cls = c.little(8); obj.shallow = c.little(8); obj.retained = obj.shallow
            c.little(8); obj.category = Int64(c.little(1)); let name = c.little(4); c.little(1); c.little(1)
            let start = c.little(8); let count = c.little(4)
            if (obj.category > 6 || start > UInt64(counts[3]) || count > UInt64(counts[3])-start || name >= UInt64(counts[7])) { throw IllegalArgumentException("invalid cache object") }
            objectRefs[id] = (Int64(start), Int64(count))
            let saved = c.pos; c.pos = offsets[7]+Int64(name)
            let data = ArrayList<UInt8>()
            while (c.pos < offsets[7]+counts[7]) { let b = UInt8(c.number(1)); if (b == 0) { break }; data.add(b) }
            obj.name = String.fromUtf8(data.toArray()); c.pos = saved
            p.objects[id] = obj
        }
        for ((id, refs) in objectRefs) {
            c.pos = offsets[3]+refs[0]*8
            for (_ in 0..refs[1]) { p.objects[id].fields.add(c.little(8)) }
        }
        c.pos = offsets[4]
        for (_ in 0..counts[4]) {
            let rootKind = c.little(1); let id = c.little(8); let thread = c.little(4); let frame = c.little(4)
            p.roots.add(id); p.rootKinds[id] = if(rootKind==255){3}else{Int64(rootKind)}; if (rootKind == 2) { p.locals[id] = (thread, frame) }
        }
        c.pos = offsets[5]
        for (_ in 0..counts[5]) {
            let id = c.little(8); let parent = c.little(8); let retained = c.little(8); c.little(8); c.little(4); c.little(8); c.little(4)
            let obj = p.objects.get(id) ?? throw IllegalArgumentException("cache dominance object missing")
            obj.retained = retained; domParents[id] = parent
        }
        let a = Analysis(p, cached: true); a.idom = Array<Int64>(a.nodes.size+1, repeat: -1); a.idom[0] = 0
        for ((id, parent) in domParents) {
            let i = a.index[id]
            a.idom[i+1] = if (parent == 0) { 0 } else { (a.index.get(parent) ?? throw IllegalArgumentException("cache dominance parent missing"))+1 }
        }
        // Reject malformed dominance cycles before HttpView follows parent links.
        for (i in 1..a.idom.size) {
            var j = i; var hops: Int64 = 0
            while (j > 0) { j = a.idom[j]; hops++; if (hops > a.nodes.size) { throw IllegalArgumentException("cyclic cached dominance") } }
        }
        return a
    }
}
