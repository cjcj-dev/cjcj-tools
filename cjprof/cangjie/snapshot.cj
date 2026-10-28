// Copyright (c) Huawei Technologies Co., Ltd. 2025-2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof
import std.collection.*
import std.fs.*
import std.sort.*

// Linux libstdc++ std::hash<string> used by the original opaque IDs.
@OverflowWrapping
func snapshotHash(text: String): UInt64 {
    let bytes = text.toArray(); let m: UInt64 = 0xc6a4a7935bd1e995
    var h = UInt64(0xc70f6907) ^ (UInt64(bytes.size)*m); var i: Int64 = 0
    while (i+8 <= bytes.size) {
        var k: UInt64 = 0
        for (j in 0..8) { k = k | (UInt64(bytes[i+j]) << UInt64(j*8)) }
        k *= m; k = k ^ (k >> 47); k *= m; h = h ^ k; h *= m; i += 8
    }
    if (i < bytes.size) {
        var tail: UInt64 = 0; var shift: UInt64 = 0
        while (i < bytes.size) { tail = tail | (UInt64(bytes[i]) << shift); shift += 8; i++ }
        h = h ^ tail; h *= m
    }
    h = h ^ (h >> 47); h *= m; h = h ^ (h >> 47)
    return h
}
class ApiNode {
    var className = ""
    var id: UInt64 = 0
    var totalSize: UInt64 = 0
    var nodeIndex: Int64 = 0
    var distance: Int64 = 0
    var shallowSize: UInt64 = 0
    var retainedSize: UInt64 = 0
    var shallowSizePercent: Float64 = 0.0
    var retainedSizePercent: Float64 = 0.0
    var totalInstanceCountPercent: Float64 = 0.0
    var childrenCount: Int64 = 0
    var retainerCount: Int64 = 0
    var startPosition: Int64 = 0
    var endPosition: Int64 = 0
    var arrayLength: UInt64 = 0
    var nodeType = ""
    var rootType = ""
    let children = ArrayList<ApiNode>()
    let retainers = ArrayList<ApiNode>()
    var addedCount: Int64 = 0
    var removedCount: Int64 = 0
    var addedSize: UInt64 = 0
    var removedSize: UInt64 = 0
    var baseTotalSize: UInt64 = 0
    var targetTotalSize: UInt64 = 0
    var added = false
    let childAddedStates = ArrayList<Bool>()
}
// RawHeapSnapshot / InsNode / ConNode expose uint32 byte counts. Keep those
// public bit patterns and percentages here; Analysis remains UInt64 for CLI/HTTP.
func snapshotBytes(value: UInt64): UInt64 { value & 0xffffffff }
class Snapshot {
    let id: UInt64
    let path: String
    let fileSize: Int64
    let analysis: Analysis
    var total: UInt64 = 0
    let constructors = HashMap<UInt64, ObjectGroup>()
    init(path: String) {
        this.path = canonicalize(path).toString(); id = snapshotHash(this.path)
        let bytes = File.readFrom(this.path); fileSize = bytes.size
        let p = Profile(); p.parse(bytes); analysis = Analysis(p)
        if (analysis.nodes.isEmpty()) { throw IllegalArgumentException("empty heap snapshot") }
        for (obj in analysis.nodes) {
            let bytes = snapshotBytes(obj.shallow)
            if (total >= 0xffffffff - bytes) { total = 0xffffffff }
            else { total += bytes }
        }
        for ((name, group) in analysis.groups) { constructors[snapshotHash(name)] = group }
    }
    func instance(i: Int64): ApiNode {
        let obj = analysis.nodes[i]; let node = ApiNode()
        node.id = obj.id; node.className = obj.name; node.nodeIndex = i; node.distance = obj.distance
        node.shallowSize = snapshotBytes(obj.shallow); node.retainedSize = snapshotBytes(obj.retained); node.totalSize = total
        if (total > 0) { node.shallowSizePercent = Float64(node.shallowSize)*100.0/Float64(total); node.retainedSizePercent = Float64(node.retainedSize)*100.0/Float64(total) }
        node.childrenCount = obj.children.size; node.retainerCount = obj.parents.size
        node.arrayLength = obj.count; node.nodeType = if (obj.kind == 0) { "[object]" } else { "[array]" }
        node.rootType = match (analysis.profile.rootKinds.get(obj.id) ?? 0) { case 1 => "[ROOT GLOBAL]"; case 2 => "[ROOT LOCAL]"; case 3 => "[ROOT UNKNOWN]"; case _ => "[-]" }
        return node
    }
    func constructor(id: UInt64, start: Int64, length: Int64): ApiNode {
        let g = constructors.get(id) ?? return ApiNode()
        let node = ApiNode(); node.className = g.name; node.id = id; node.childrenCount = g.nodes.size
        node.totalSize = total; node.shallowSize = snapshotBytes(g.shallow); node.retainedSize = snapshotBytes(g.retained)
        for (i in g.nodes) { let d = analysis.nodes[i].distance; if (node.distance == 0 || d < node.distance) { node.distance = d } }
        if (total > 0) { node.shallowSizePercent = Float64(node.shallowSize)*100.0/Float64(total); node.retainedSizePercent = Float64(node.retainedSize)*100.0/Float64(total) }
        node.totalInstanceCountPercent = Float64(g.nodes.size)*100.0/Float64(analysis.nodes.size)
        if (length > 0) {
            node.startPosition = start; node.endPosition = start+length-1
            for (i in start..start+length where i >= 0 && i < g.nodes.size) { node.children.add(instance(g.nodes[i])) }
        }
        return node
    }
    func expand(id: UInt64, start: Int64, length: Int64, children: Bool, references: Bool): ApiNode {
        let i = analysis.index.get(id) ?? return ApiNode()
        let node = instance(i); let obj = analysis.nodes[i]
        node.startPosition = start; node.endPosition = start+length-1
        for (offset in start..start+length where offset >= 0) {
            if (children && offset < obj.children.size) { node.children.add(instance(obj.children[offset])) }
            if (references && offset < obj.parents.size) { node.retainers.add(instance(obj.parents[offset])) }
        }
        return node
    }
    func allConstructors(): ArrayList<ApiNode> {
        let out = ArrayList<ApiNode>()
        for (g in analysis.sortedGroups()) { out.add(constructor(snapshotHash(g.name), 0, 0)) }
        return out
    }
    func roots(kinds: HashSet<Int64>): ArrayList<ApiNode> {
        let out = ArrayList<ApiNode>()
        for (con in allConstructors()) {
            let g = constructors[con.id]
            for (i in g.nodes) {
                let kind = analysis.profile.rootKinds.get(analysis.nodes[i].id) ?? 0
                if (kinds.contains(kind) || (kind == 3 && kinds.contains(255))) { con.children.add(instance(i)) }
            }
            con.childrenCount = con.children.size
            if (con.childrenCount > 0) { out.add(con) }
        }
        return out
    }
    func paths(id: UInt64, limit: Int64): ArrayList<ArrayList<ApiNode>> {
        let out = ArrayList<ArrayList<ApiNode>>()
        let start = analysis.index.get(id) ?? return out
        if (limit < -1 || limit == 0) { return out }
        let todo = ArrayList<ArrayList<Int64>>(); let initial = ArrayList<Int64>(); initial.add(start); todo.add(initial)
        let paths = ArrayList<ArrayList<Int64>>()
        while (!todo.isEmpty()) {
            let path = todo.remove(at: todo.size-1); let i = path[path.size-1]
            if (analysis.nodes[i].root) { paths.add(path) }
            for (parent in analysis.nodes[i].parents where !path.contains(parent)) {
                let next = ArrayList<Int64>(); for (j in path) { next.add(j) }; next.add(parent); todo.add(next)
            }
        }
        let sorted = paths.toArray()
        sort(sorted, by: { a, b =>
            let aRet = snapshotBytes(analysis.nodes[a[a.size-1]].retained); let bRet = snapshotBytes(analysis.nodes[b[b.size-1]].retained)
            if (aRet != bRet) { bRet.compare(aRet) } else { a.size.compare(b.size) }
        }, stable: true, descending: false)
        for (i in 0..sorted.size where limit == -1 || i < limit) {
            let path = ArrayList<ApiNode>(); for (j in sorted[i]) { path.add(instance(j)) }; out.add(path)
        }
        return out
    }
}
class SnapshotStore {
    let snapshots = HashMap<UInt64, Snapshot>()
    let comparisons = HashMap<String, ArrayList<ApiNode>>()
    func load(paths: ArrayList<String>): Bool {
        for (path in paths) {
            try { let snapshot = Snapshot(path); snapshots[snapshot.id] = snapshot; comparisons.clear() }
            catch (_: Exception) { return false }
        }
        return true
    }
    func clean(ids: ArrayList<UInt64>): Unit { comparisons.clear(); for (id in ids) { snapshots.remove(id) } }
    func get(id: UInt64): Snapshot { snapshots.get(id) ?? throw IllegalArgumentException("Invalid snapshot ID") }
    func snapshotId(path: String): UInt64 { try { return snapshotHash(canonicalize(path).toString()) } catch (_: Exception) { return 0 } }
    func compare(baseId: UInt64, targetId: UInt64): ArrayList<ApiNode> {
        let key = "${baseId}:${targetId}"
        if (let Some(cached) <- comparisons.get(key)) { return cached }
        let out = ArrayList<ApiNode>()
        let base = snapshots.get(baseId) ?? return out; let target = snapshots.get(targetId) ?? return out
        let ids = HashSet<UInt64>(); for ((id, _) in base.constructors) { ids.add(id) }; for ((id, _) in target.constructors) { ids.add(id) }
        for (id in ids) {
            let b = base.constructors.get(id); let t = target.constructors.get(id)
            if (b.isSome() && t.isSome()) {
                let bg = b.getOrThrow(); let tg = t.getOrThrow()
                var same = bg.nodes.size == tg.nodes.size && snapshotBytes(bg.shallow) == snapshotBytes(tg.shallow) && snapshotBytes(bg.retained) == snapshotBytes(tg.retained)
                let bIds = HashSet<UInt64>(); for (i in bg.nodes) { bIds.add(base.analysis.nodes[i].id) }
                for (i in tg.nodes where !bIds.contains(target.analysis.nodes[i].id)) { same = false }
                if (same) { continue }
            }
            let node = if (b.isSome()) { base.constructor(id, 0, 0) } else { target.constructor(id, 0, 0) }
            node.addedCount = b?.nodes.size ?? 0; node.removedCount = t?.nodes.size ?? 0
            node.addedSize = snapshotBytes(b?.shallow ?? 0); node.removedSize = snapshotBytes(t?.shallow ?? 0)
            node.baseTotalSize = base.total; node.targetTotalSize = target.total; out.add(node)
        }
        comparisons[key] = out; return out
    }
    func constructorDiff(baseId: UInt64, targetId: UInt64, id: UInt64, start: Int64, length: Int64): ApiNode {
        let base = snapshots.get(baseId) ?? return ApiNode(); let target = snapshots.get(targetId) ?? return ApiNode()
        let bg = base.constructors.get(id); let tg = target.constructors.get(id)
        let diffs = compare(baseId, targetId)
        var node = ApiNode()
        for (diff in diffs where diff.id == id) { node = diff }
        // Return a fresh node so pagination cannot mutate the cached comparison.
        let result = if (bg.isSome()) { base.constructor(id, 0, 0) } else { target.constructor(id, 0, 0) }
        result.addedCount = node.addedCount; result.removedCount = node.removedCount
        result.addedSize = node.addedSize; result.removedSize = node.removedSize
        result.baseTotalSize = base.total; result.targetTotalSize = target.total
        let bIds = HashSet<UInt64>(); let tIds = HashSet<UInt64>()
        if (let Some(g) <- bg) { for (i in g.nodes) { bIds.add(base.analysis.nodes[i].id) } }
        if (let Some(g) <- tg) { for (i in g.nodes) { tIds.add(target.analysis.nodes[i].id) } }
        let changed = ArrayList<ApiNode>(); let states = ArrayList<Bool>()
        if (let Some(g) <- bg) { for (i in g.nodes where !tIds.contains(base.analysis.nodes[i].id)) { changed.add(base.instance(i)); states.add(true) } }
        if (let Some(g) <- tg) { for (i in g.nodes where !bIds.contains(target.analysis.nodes[i].id)) { changed.add(target.instance(i)); states.add(false) } }
        result.childrenCount = changed.size; result.startPosition = start; result.endPosition = start+length-1
        for (i in start..start+length where i >= 0 && i < changed.size) { result.children.add(changed[i]); result.childAddedStates.add(states[i]) }
        return result
    }
    func instanceDiff(baseId: UInt64, targetId: UInt64, id: UInt64, start: Int64, length: Int64, children: Bool, references: Bool): ApiNode {
        let base = snapshots.get(baseId) ?? return ApiNode(); let target = snapshots.get(targetId) ?? return ApiNode()
        let added = !target.analysis.index.contains(id)
        let source = if (added) { base } else { target }
        let node = source.expand(id, start, length, children, references); node.added = added
        for (diff in compare(baseId, targetId) where diff.className == node.className) {
            node.addedCount = diff.addedCount; node.removedCount = diff.removedCount; node.addedSize = diff.addedSize; node.removedSize = diff.removedSize
        }
        return node
    }
    func rootDiff(baseId: UInt64, targetId: UInt64, kinds: HashSet<Int64>): ArrayList<ApiNode> {
        let out = ArrayList<ApiNode>(); let base = snapshots.get(baseId) ?? return out; let target = snapshots.get(targetId) ?? return out
        let bRoots = HashMap<UInt64, ApiNode>(); let tRoots = HashMap<UInt64, ApiNode>()
        for (n in base.roots(kinds)) { bRoots[n.id] = n }; for (n in target.roots(kinds)) { tRoots[n.id] = n }
        for (diff in compare(baseId,targetId)) {
            let b = bRoots.get(diff.id); let t = tRoots.get(diff.id)
            if (b.isNone() && t.isNone()) { continue }
            let result = constructorDiff(baseId,targetId,diff.id,0,0)
            if (let Some(n) <- b) { for (child in n.children) { result.children.add(child) } }
            if (let Some(n) <- t) { for (child in n.children) { result.children.add(child) } }
            result.childrenCount = diff.childrenCount+result.children.size; out.add(result)
        }; out
    }
    func matches(name: String, keyword: String, ignoreCase: Bool): Bool {
        if (ignoreCase) { name.toAsciiLower().contains(keyword.toAsciiLower()) } else { name.contains(keyword) }
    }
    func count(keyword: String, ignoreCase: Bool, id: UInt64): Int64 {
        var count: Int64 = 0
        for (node in (snapshots.get(id)?.allConstructors() ?? ArrayList<ApiNode>()) where matches(node.className, keyword, ignoreCase)) { count += node.childrenCount }
        return count
    }
    func query(keyword: String, ignoreCase: Bool, id: UInt64, length: Int64, index: Int64): ApiNode {
        if (index <= 0) { return ApiNode() }
        var offset = index-1
        for (node in (snapshots.get(id)?.allConstructors() ?? ArrayList<ApiNode>()) where matches(node.className, keyword, ignoreCase)) {
            if (offset < node.childrenCount) { return snapshots.get(id)?.constructor(node.id, offset, length) ?? ApiNode() }
            offset -= node.childrenCount
        }
        return ApiNode()
    }
    func compareCount(keyword: String, ignoreCase: Bool, base: UInt64, target: UInt64): Int64 {
        var count: Int64 = 0
        for (node in compare(base, target) where matches(node.className, keyword, ignoreCase)) { count += constructorDiff(base, target, node.id, 0, 0).childrenCount }
        return count
    }
    func compareQuery(keyword: String, ignoreCase: Bool, base: UInt64, target: UInt64, length: Int64, index: Int64): ApiNode {
        if (index <= 0) { return ApiNode() }
        var offset = index-1
        for (node in compare(base, target) where matches(node.className, keyword, ignoreCase)) {
            let n = constructorDiff(base, target, node.id, 0, 0).childrenCount
            if (offset < n) { return constructorDiff(base, target, node.id, offset, length) }
            offset -= n
        }
        return ApiNode()
    }
}
