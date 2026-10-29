// Copyright (c) Huawei Technologies Co., Ltd. 2025-2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof
import std.collection.*
import std.sort.*

func align8(n: UInt64): UInt64 { (n + 7) / 8 * 8 }
func hex(n: UInt64): String {
    if (n == 0) { return "0" }
    let digits = "0123456789abcdef".toArray()
    let out = ArrayList<UInt8>()
    var x = n
    while (x > 0) { out.add(digits[Int64(x & 15)]); x = x >> 4 }
    let bytes = out.toArray()
    for (i in 0..bytes.size/2) { let b = bytes[i]; bytes[i] = bytes[bytes.size-1-i]; bytes[bytes.size-1-i] = b }
    return String.fromUtf8(bytes)
}
func pad(s: String, width: Int64): String {
    var out = s
    for (_ in s.size..width) { out += " " }
    return out
}
func padLeft(s: String, width: Int64): String { var out = ""; for (_ in s.size..width) { out += " " }; return out+s }
class ObjectGroup {
    let name: String
    let nodes = ArrayList<Int64>()
    var shallow: UInt64 = 0
    var retained: UInt64 = 0
    init(name: String) { this.name = name }
}
class Analysis {
    let profile: Profile
    let nodes = ArrayList<HeapObject>()
    let index = HashMap<UInt64, Int64>()
    let groups = HashMap<String, ObjectGroup>()
    var idom = Array<Int64>() // object index+1; 0 is synthetic root; -1 is unreachable
    init(profile: Profile, cached!: Bool = false) {
        this.profile = profile
        let ids = profile.objects.keys().toArray()
        sort(ids)
        for (id in ids) { index[id] = nodes.size; nodes.add(profile.objects[id]) }
        if (!cached) {
            prepare(); calculateDistances(); calculateRetained()
        } else {
            for (i in 0..nodes.size) {
                nodes[i].root = profile.roots.contains(nodes[i].id)
                for (id in nodes[i].fields) {
                    if (let Some(j) <- index.get(id)) { nodes[i].children.add(j); nodes[j].parents.add(i) }
                }
            }
            calculateDistances()
        }
        for (i in 0..nodes.size) {
            let node = nodes[i]
            let group = groups.get(node.name) ?? ObjectGroup(node.name)
            group.nodes.add(i); group.shallow += node.shallow
            group.retained += node.retained
            groups[node.name] = group
        }
    }
    func prepare(): Unit {
        let primitiveNames = ["RawArray<Byte>[]", "RawArray<Harf>[]", "RawArray<Word>[]", "RawArray<DWord>[]"]
        for (i in 0..nodes.size) {
            let obj = nodes[i]
            obj.root = profile.roots.contains(obj.id)
            if (obj.kind == 3) {
                let k: Int64 = if (obj.primitive == 4) { 0 } else { obj.primitive-8 }
                obj.name = primitiveNames[k]
                obj.shallow = 16 + align8((UInt64(1) << UInt64(k))*obj.count)
            } else {
                let cls = profile.classes.get(obj.cls) ?? throw IllegalArgumentException("missing class ${obj.cls}")
                obj.name = profile.text(cls.name).replace(":", "::")
                obj.shallow = if (obj.kind == 0) { align8(cls.size) } else {
                    16 + if (cls.size == 0) { 8*obj.count } else { align8(cls.size*(if (obj.kind == 2) { obj.components } else { obj.count })) }
                }
            }
            let unique = HashSet<UInt64>()
            for (id in obj.fields where id != 0) {
                if (unique.contains(id)) { continue }
                unique.add(id)
                if (let Some(child) <- index.get(id)) {
                    obj.children.add(child)
                    nodes[child].parents.add(i)
                }
            }
        }
    }
    func calculateDistances(): Unit {
        let queue = ArrayList<Int64>()
        for (i in 0..nodes.size where nodes[i].root) { nodes[i].distance = 1; queue.add(i) }
        var head: Int64 = 0
        while (head < queue.size) {
            let i = queue[head]; head++
            for (j in nodes[i].children where nodes[j].distance == 0) {
                nodes[j].distance = nodes[i].distance+1; queue.add(j)
            }
        }
    }
    // Cooper-Harvey-Kennedy immediate dominators in reverse postorder. Iterative
    // DFS and bottom-up accumulation keep long chains off the native call stack.
    func calculateRetained(): Unit {
        let n = nodes.size+1
        let graph = Array<ArrayList<Int64>>(n, { _ => ArrayList<Int64>() })
        let preds = Array<ArrayList<Int64>>(n, { _ => ArrayList<Int64>() })
        for (i in 0..nodes.size) {
            for (j in nodes[i].children) { graph[i+1].add(j+1); preds[j+1].add(i+1) }
            if (nodes[i].root || nodes[i].parents.isEmpty() || nodes[i].category == 4) {
                graph[0].add(i+1); preds[i+1].add(0)
            }
            nodes[i].retained = nodes[i].shallow
        }
        let visited = Array<Bool>(n, repeat: false)
        let next = Array<Int64>(n, repeat: 0)
        let stack = ArrayList<Int64>(); stack.add(0); visited[0] = true
        let order = ArrayList<Int64>()
        while (!stack.isEmpty()) {
            let v = stack[stack.size-1]
            if (next[v] < graph[v].size) {
                let child = graph[v][next[v]]; next[v]++
                if (!visited[child]) { visited[child] = true; stack.add(child) }
            } else { order.add(v); stack.remove(at: stack.size-1) }
        }
        let rank = Array<Int64>(n, repeat: -1)
        for (i in 0..order.size) { rank[order[i]] = i }
        idom = Array<Int64>(n, repeat: -1); idom[0] = 0
        var changed = true
        while (changed) {
            changed = false
            var k = order.size-2
            while (k >= 0) {
                let v = order[k]; k--
                var parent: Int64 = -1
                for (p in preds[v] where idom[p] != -1) {
                    if (parent == -1) { parent = p; continue }
                    var a = parent; var b = p
                    while (a != b) {
                        while (rank[a] < rank[b]) { a = idom[a] }
                        while (rank[b] < rank[a]) { b = idom[b] }
                    }
                    parent = a
                }
                if (parent != -1 && parent != idom[v]) { idom[v] = parent; changed = true }
            }
        }
        // Every strict dominator follows its dominated node in DFS postorder.
        for (v in order where v != 0 && idom[v] > 0) {
            nodes[idom[v]-1].retained += nodes[v-1].retained
        }
    }
    func sortedGroups(): Array<ObjectGroup> {
        let result = groups.values().toArray()
        sort(result, by: { a, b =>
            if (a.retained != b.retained) { b.retained.compare(a.retained) }
            else if (a.shallow != b.shallow) { b.shallow.compare(a.shallow) }
            else { a.name.compare(b.name) }
        }, stable: false, descending: false)
        return result
    }
    func showObjects(): Unit {
        println("Object Type                                                       Objects        Shallow Heap   Retained Heap")
        println("================================================================  =============  =============  =============")
        let rows = HashMap<String, ObjectGroup>()
        for (i in 0..nodes.size) {
            let node = nodes[i]; let row = rows.get(node.name) ?? ObjectGroup(node.name)
            rows[node.name] = row; row.nodes.add(i); row.shallow += node.shallow
            var parent = i; var sameClassAncestor = false; let visited = HashSet<Int64>()
            while (nodes[parent].parents.size == 1 && !visited.contains(parent)) {
                visited.add(parent); parent = nodes[parent].parents[0]
                if (nodes[parent].name == node.name) { sameClassAncestor = true; break }
            }
            if (!sameClassAncestor || row.retained == 0) { row.retained += node.retained }
        }
        let sorted = rows.values().toArray()
        sort(sorted, by: { a,b => if(a.retained!=b.retained){b.retained.compare(a.retained)}else if(a.shallow!=b.shallow){b.shallow.compare(a.shallow)}else{a.name.compare(b.name)} },stable:true,descending:false)
        for (g in sorted where !g.name.isEmpty()) {
            println("${pad(g.name, 64)}  ${padLeft(g.nodes.size.toString(),13)}  ${padLeft(g.shallow.toString(),13)}  ${padLeft(g.retained.toString(),13)}")
        }
    }
    func showThreads(): Unit {
        println("Object/Stack Frame                                                            Shallow Heap   Retained Heap")
        let ids = profile.threads.keys().toArray(); sort(ids)
        for (id in ids) {
            let thread = profile.threads[id]
            println(profile.text(thread.name))
            if (let Some(trace) <- profile.traces.get(thread.trace)) {
                for (i in 0..trace.frames.size) {
                    if (let Some(frame) <- profile.frames.get(trace.frames[i])) {
                        let file = profile.text(frame.file)
                        println("  at ${profile.text(frame.name)}" + if (file.isEmpty()) { "" } else { " (${file}:${frame.line})" })
                    }
                    for ((objId, local) in profile.locals where local[0] == thread.index && local[1] == UInt64(i)) {
                        if (let Some(node) <- profile.objects.get(objId)) {
                            println("    <local> ${node.name} @ 0x${hex(node.id)}  ${node.shallow}  ${node.retained}")
                        }
                    }
                }
            }
        }
    }
    func showReferences(names: String, depth: Int64, incoming: Bool): Unit {
        let selected = HashSet<String>()
        for (name in names.split(";") where !name.isEmpty()) { selected.add(name) }
        for (name in selected where !groups.contains(name)) { println("No objects found matching: ${name}") }
        println("Objects with " + if (incoming) { "incoming" } else { "outgoing" } + " references:")
        println("Object Type                                                       Shallow Heap   Retained Heap")
        for (i in 0..nodes.size where selected.isEmpty() || selected.contains(nodes[i].name)) {
            showOneReference(i, 0, depth, incoming, HashSet<Int64>())
        }
    }
    func showOneReference(i: Int64, level: Int64, maxDepth: Int64, incoming: Bool, path: HashSet<Int64>): Unit {
        let node = nodes[i]
        var indent = ""; for (_ in 0..level) { indent += "  " }
        println("${indent}${node.name} @ 0x${hex(node.id)}  ${node.shallow}  ${node.retained}")
        let edges = if (incoming) { node.parents } else { node.children }
        if (!edges.isEmpty() && (level >= maxDepth || path.contains(i))) { println(indent+"  ..."); return }
        path.add(i)
        for (j in edges) { showOneReference(j, level+1, maxDepth, incoming, path) }
        path.remove(i)
    }
}
