// Copyright (c) Huawei Technologies Co., Ltd. 2025-2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof

import std.collection.*
import std.fs.*

class Cursor {
    let bytes: Array<UInt8>
    var pos: Int64 = 0
    var limit: Int64
    init(bytes: Array<UInt8>) { this.bytes = bytes; limit = bytes.size }
    func take(n: Int64): Array<UInt8> {
        if (n < 0 || n > limit - pos) {
            throw IllegalArgumentException("truncated profile at offset ${pos}, need ${n}")
        }
        let result = bytes[pos..pos+n].toArray()
        pos += n
        return result
    }
    func number(n: Int64): UInt64 {
        var value: UInt64 = 0
        for (b in take(n)) { value = (value << 8) | UInt64(b) }
        return value
    }
    func count(): Int64 { Int64(number(4)) }
    func recordEnd(width: Int64): Int64 {
        let length = number(width)
        if (length > UInt64(limit - pos)) {
            throw IllegalArgumentException("invalid record length at offset ${pos}")
        }
        return pos + Int64(length)
    }
}

class HeapClass {
    var name: UInt64 = 0
    var size: UInt64 = 0
}
class HeapObject {
    let id: UInt64
    var cls: UInt64 = 0
    var kind: Int64 = 0 // 0 instance, 1 object array, 2 struct array, 3 primitive array
    var category: Int64 = 0
    var count: UInt64 = 0
    var components: UInt64 = 0
    var primitive: Int64 = 0
    let fields = ArrayList<UInt64>()
    var name = ""
    var shallow: UInt64 = 0
    var retained: UInt64 = 0
    var distance: Int64 = 0
    var root = false
    let children = ArrayList<Int64>()
    let parents = ArrayList<Int64>()
    init(id: UInt64) { this.id = id }
}
class StackFrame {
    let name: UInt64
    let file: UInt64
    let line: UInt64
    init(name: UInt64, file: UInt64, line: UInt64) {
        this.name = name; this.file = file; this.line = line
    }
}
class StackTrace {
    let thread: UInt64
    let frames = ArrayList<UInt64>()
    init(thread: UInt64) { this.thread = thread }
}
class HeapThread {
    let index: UInt64
    let trace: UInt64
    let name: UInt64
    init(index: UInt64, trace: UInt64, name: UInt64) {
        this.index = index; this.trace = trace; this.name = name
    }
}
class Profile {
    let strings = HashMap<UInt64, String>()
    let classes = HashMap<UInt64, HeapClass>()
    let objects = HashMap<UInt64, HeapObject>()
    let roots = HashSet<UInt64>()
    let rootKinds = HashMap<UInt64, Int64>()
    let locals = HashMap<UInt64, (UInt64, UInt64)>()
    let frames = HashMap<UInt64, StackFrame>()
    let traces = HashMap<UInt64, StackTrace>()
    let threads = HashMap<UInt64, HeapThread>()
    let samples = HashMap<UInt64, HashMap<UInt64, UInt64>>()
    var version: Int64 = 0
    var idSize: Int64 = 8
    var fileTime: UInt64 = 0
    func getClass(id: UInt64): HeapClass {
        if (let Some(c) <- classes.get(id)) { return c }
        let c = HeapClass(); classes[id] = c; return c
    }
    func text(id: UInt64): String { strings.get(id) ?? "" }
    func metadataSize(): Int64 { if (version == 1) { 8 } else { 4 } }
    static func load(path: String): Profile {
        let p = Profile()
        p.parse(File.readFrom(path))
        return p
    }
    func parse(bytes: Array<UInt8>): Unit {
        let c = Cursor(bytes)
        let header = c.take(22)
        let magic = String.fromUtf8(header[0..21].toArray())
        if (magic == "CANGJIE PROFILE 1.0.1") { version = 1 }
        else if (magic == "CANGJIE PROFILE 1.0.2") { version = 2 }
        else { throw IllegalArgumentException("invalid profile magic") }
        let declared = c.count()
        if (declared != 4 && declared != 8) { throw IllegalArgumentException("invalid ID size ${declared}") }
        idSize = if (version == 1) { 8 } else { declared }
        fileTime = c.number(8)
        while (c.pos < c.limit) {
            let tag = c.number(1)
            if (tag == 1) {
                let end = c.recordEnd(metadataSize())
                let id = c.number(metadataSize())
                if (c.pos > end) { throw IllegalArgumentException("short string record") }
                strings[id] = String.fromUtf8(c.take(end - c.pos))
                continue
            }
            if (tag == 2 && version == 2) {
                let id = c.number(4); let name = c.number(4); let size = c.number(4)
                let cls = getClass(id); cls.name = name; cls.size = size
                continue
            }
            let end = c.recordEnd(8)
            let outerLimit = c.limit
            c.limit = end
            match (tag) {
                case 2 =>
                    let id = c.number(8)
                    getClass(id).name = c.number(8)
                case 4 =>
                    let id = c.number(metadataSize()); let name = c.number(metadataSize())
                    let file = c.number(metadataSize()); let line = c.number(4)
                    frames[id] = StackFrame(name, file, line)
                case 5 =>
                    let id = c.number(4); let thread = c.number(4); let count = c.count()
                    let trace = StackTrace(thread)
                    if (count > (c.limit-c.pos)/metadataSize()) { throw IllegalArgumentException("truncated frames") }
                    for (_ in 0..count) { trace.frames.add(c.number(metadataSize())) }
                    traces[id] = trace
                case 10 =>
                    let index = c.number(4); let id = c.number(idSize)
                    let trace = c.number(4); let name = c.number(idSize)
                    threads[id] = HeapThread(index, trace, name)
                case 12 => parseHeap(c)
                case 13 =>
                    let period = c.number(4); let count = c.count()
                    let entries = samples.get(period) ?? HashMap<UInt64, UInt64>()
                    if (count > (c.limit-c.pos)/8) { throw IllegalArgumentException("truncated samples") }
                    for (_ in 0..count) {
                        let n = c.number(4); let trace = c.number(4)
                        entries[trace] = n
                    }
                    samples[period] = entries
                case _ => c.pos = end
            }
            if (c.pos != end) { throw IllegalArgumentException("record length mismatch at offset ${c.pos}, expected ${end}") }
            c.limit = outerLimit
        }
    }
    func references(c: Cursor, obj: HeapObject, count: Int64): Unit {
        if (count > (c.limit-c.pos)/idSize) { throw IllegalArgumentException("truncated object references") }
        for (_ in 0..count) { obj.fields.add(c.number(idSize)) }
    }
    func parseHeap(c: Cursor): Unit {
        while (c.pos < c.limit) {
            let tag = Int64(c.number(1))
            if (tag == 1 || tag == 2 || tag == 255) {
                let id = c.number(idSize); roots.add(id); rootKinds[id] = if (tag == 255) { 3 } else { tag }
                if (tag == 2) { let thread = c.number(4); let frame = c.number(4); locals[id] = (thread, frame) }
                continue
            }
            if (tag == 32) {
                let id = c.number(metadataSize()); let cls = getClass(id)
                if (version == 2) { cls.name = c.number(4) }
                cls.size = c.number(4)
                continue
            }
            if (tag < 33 || tag > 45) { throw IllegalArgumentException("unknown heap subtag ${tag} at ${c.pos-1}") }
            let id = c.number(idSize)
            if (objects.contains(id)) { throw IllegalArgumentException("duplicate object ID ${id}") }
            let obj = HeapObject(id)
            // Wire 0x23 is primitive, 0x24 is struct; public category IDs have
            // STRUCT_ARRAY=2 and PRIMITIVE_ARRAY=3 (not wire-tag order).
            obj.category = match(tag) {
                case 33 => 0
                case 34 => 1
                case 35 => 3
                case 36 => 2
                case 37 => 4
                case 38 | 39 | 40 | 41 => 5
                case _ => 6
            }
            let shape = if (tag == 37) { 33 } else if (tag >= 38 && tag <= 41) { tag-5 } else if (tag >= 42) { tag-9 } else { tag }
            match (shape) {
                case 33 =>
                    obj.cls = c.number(metadataSize())
                    references(c, obj, c.count())
                case 34 | 36 =>
                    obj.kind = if (shape == 34) { 1 } else { 2 }
                    if (shape == 36) { obj.components = c.number(4) }
                    let count = c.count(); obj.count = UInt64(count)
                    obj.cls = c.number(metadataSize())
                    references(c, obj, count)
                case 35 =>
                    obj.kind = 3; obj.count = c.number(4); obj.primitive = Int64(c.number(1))
                    if (obj.primitive != 4 && obj.primitive != 9 && obj.primitive != 10 && obj.primitive != 11) {
                        throw IllegalArgumentException("unknown primitive array type ${obj.primitive}")
                    }
                case _ => throw IllegalArgumentException("unknown object shape ${shape}")
            }
            objects[id] = obj
        }
    }
}
