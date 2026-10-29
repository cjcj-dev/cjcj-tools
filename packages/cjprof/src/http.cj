// Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof
import std.collection.*
import std.console.*
import std.convert.*
import std.fs.*
import std.net.*
import std.sort.*

let categoryNames = ["INSTANCE_OBJECT", "OBJECT_ARRAY", "STRUCT_ARRAY", "PRIMITIVE_ARRAY", "PINNED_OBJECT", "LARGE_OBJECT", "UNMOVABLE_OBJECT", "FREE_SPACE"]
func objectJson(fields: Array<(String, String)>): String {
    let pairs = ArrayList<String>()
    for ((key, value) in fields) { pairs.add(jsonString(key)+":"+value) }
    return "{"+String.join(pairs.toArray(), delimiter: ",")+"}"
}
func decodeUrl(s: String): String {
    let bytes = s.toArray(); let out = ArrayList<UInt8>(); var i: Int64 = 0
    while (i < bytes.size) {
        if (bytes[i] == 37) {
            if (i+2 >= bytes.size) { throw IllegalArgumentException("Invalid URL encoding") }
            let h = UInt8.parse(String.fromUtf8(bytes[i+1..i+3].toArray()), radix: 16)
            out.add(h); i += 3
        } else { out.add(if (bytes[i] == 43) { 32 } else { bytes[i] }); i++ }
    }
    return String.fromUtf8(out.toArray())
}
class TypeNode {
    let id: Int64
    let parent: Int64
    let name: String
    let parentName: String
    var shallow: UInt64 = 0
    var retained: UInt64 = 0
    var depth: Int64 = 0
    var cutoff = false
    let objects = ArrayList<Int64>()
    let children = ArrayList<Int64>()
    init(id: Int64, parent: Int64, name: String, parentName: String) {
        this.id = id; this.parent = parent; this.name = name; this.parentName = parentName
    }
}
class HttpView {
    let analysis: Analysis
    let domChildren = HashMap<Int64, ArrayList<Int64>>()
    let depths: Array<Int64>
    var used: UInt64 = 0
    var start: UInt64 = 0
    var end: UInt64 = 0
    let totals = Array<UInt64>(8, repeat: 0)
    let types = ArrayList<TypeNode>()
    let typeObjects = HashMap<Int64, TypeNode>()
    let visibleTypes = HashSet<Int64>()
    var cutoffCount: Int64 = 0
    init(analysis: Analysis) {
        this.analysis = analysis
        depths = Array<Int64>(analysis.nodes.size, repeat: 0)
        for (i in 0..analysis.nodes.size) {
            let obj = analysis.nodes[i]; used += obj.shallow; totals[obj.category] += obj.shallow
            if (i == 0 || obj.id < start) { start = obj.id }
            if (obj.id+obj.shallow > end) { end = obj.id+obj.shallow }
            let parent = analysis.idom[i+1]
            if (parent < 0) { continue }
            let children = domChildren.get(parent) ?? ArrayList<Int64>(); children.add(i); domChildren[parent] = children
            var d = parent
            while (d > 0) { depths[i]++; d = analysis.idom[d] }
        }
        totals[7] = if (used < 536870912) { 536870912-used } else { 0 }
        buildTypes()
    }
    func threshold(): UInt64 { if (used/1000 > 0) { used/1000 } else { 1 } }
    func domNode(i: Int64): String {
        let obj = analysis.nodes[i]; let parent = analysis.idom[i+1]
        return objectJson([
            ("id", obj.id.toString()), ("class_name", jsonString(obj.name)), ("retained_size", obj.retained.toString()),
            ("shallow_size", obj.shallow.toString()), ("depth", depths[i].toString()),
            ("parent_id", if (parent <= 0) { "0" } else { analysis.nodes[parent-1].id.toString() }),
            ("instance_count", "1"), ("is_clustered", "false"), ("is_cutoff", "false"),
            ("has_children", (!(domChildren.get(i+1) ?? ArrayList<Int64>()).isEmpty()).toString())
        ])
    }
    func snapshot(): String {
        return "{\"heap_total_size\":536870912,\"used_size\":${used},\"object_count\":${analysis.nodes.size},\"gc_root_count\":${analysis.profile.roots.size}}"
    }
    func children(parent: UInt64): String {
        let idx: Int64 = if (parent == 0) { 0 } else { (analysis.index.get(parent) ?? -2)+1 }
        let out = ArrayList<String>()
        for (i in domChildren.get(idx) ?? ArrayList<Int64>()) { out.add(domNode(i)) }
        return "{\"nodes\":${joinJson(out)}}"
    }
    func tree(): String {
        let out = ArrayList<String>(); let cut = HashMap<Int64, ArrayList<Int64>>(); var count: Int64 = 0
        for (i in 0..analysis.nodes.size where analysis.idom[i+1] >= 0 && depths[i] <= 5) {
            let parent = analysis.idom[i+1]; let obj = analysis.nodes[i]
            if (parent > 0 && analysis.nodes[parent-1].retained < threshold()) { count++; continue }
            if (obj.retained < threshold() || (parent > 0 && obj.retained < analysis.nodes[parent-1].retained/200)) {
                let list = cut.get(parent) ?? ArrayList<Int64>(); list.add(i); cut[parent] = list; count++
            } else { out.add(domNode(i)) }
        }
        for ((parent, list) in cut) {
            var shallow: UInt64 = 0; var retained: UInt64 = 0
            for (i in list) { shallow += analysis.nodes[i].shallow; retained += analysis.nodes[i].retained }
            let parentId: UInt64 = if (parent == 0) { 0 } else { analysis.nodes[parent-1].id }
            out.add("{\"id\":${parentId+1000000000},\"class_name\":${jsonString("... (${list.size} instances)")},\"retained_size\":${retained},\"shallow_size\":${shallow},\"depth\":0,\"parent_id\":${parentId},\"instance_count\":${list.size},\"is_clustered\":false,\"is_cutoff\":true}")
        }
        return "{\"nodes\":${joinJson(out)},\"cutoff_count\":${count}}"
    }
    func buildTypes(): Unit {
        let queue = ArrayList<Int64>()
        for (i in domChildren.get(0) ?? ArrayList<Int64>()) { queue.add(i) }
        let aggregates = HashMap<String, TypeNode>(); var head: Int64 = 0
        while (head < queue.size) {
            let i = queue[head]; head++
            let obj = analysis.nodes[i]; let p = analysis.idom[i+1]
            let parent: Option<TypeNode> = if (p <= 0) { None } else { typeObjects.get(p-1) }
            let parentId = parent?.id ?? 0
            let key = "${parentId}:"+obj.name
            let node = aggregates.get(key) ?? TypeNode(types.size+1, parentId, obj.name, parent?.name ?? "")
            if (!aggregates.contains(key)) { aggregates[key] = node; types.add(node) }
            node.objects.add(i); node.shallow += obj.shallow; node.retained += obj.retained
            if (depths[i] > node.depth) { node.depth = depths[i] }
            typeObjects[i] = node
            for (j in domChildren.get(i+1) ?? ArrayList<Int64>()) { queue.add(j) }
        }
        for (node in types where node.retained >= threshold()) { visibleTypes.add(node.id) }
        let cuts = HashMap<Int64, TypeNode>()
        for (node in types where !visibleTypes.contains(node.id)) {
            if (node.parent != 0 && !visibleTypes.contains(node.parent)) { continue }
            let cut = cuts.get(node.parent) ?? TypeNode(types.size+cuts.size+1, node.parent, "...", node.parentName)
            cut.cutoff = true; cut.shallow += node.shallow; cut.retained += node.retained
            for (i in node.objects) { cut.objects.add(i) }
            cuts[node.parent] = cut; cutoffCount += node.objects.size
        }
        for ((_, cut) in cuts) { types.add(cut); visibleTypes.add(cut.id) }
        for (node in types where visibleTypes.contains(node.id) && node.parent > 0) { types[node.parent-1].children.add(node.id) }
    }
    func typeNode(node: TypeNode): String {
        let ids = ArrayList<String>()
        if (node.objects.size <= 50 && !node.cutoff) { for (i in node.objects) { ids.add(analysis.nodes[i].id.toString()) } }
        let children = ArrayList<String>(); for (id in node.children) { children.add(jsonString(id.toString())) }
        let count = node.objects.size
        let name = node.name + if (count > 1 || node.cutoff) { " (${count} instances)" } else { "" }
        return objectJson([
            ("id", jsonString(node.id.toString())), ("type_name", jsonString(node.name)), ("class_name", jsonString(name)),
            ("retained_size", node.retained.toString()), ("shallow_size", node.shallow.toString()), ("depth", node.depth.toString()),
            ("parent_id", jsonString(if (node.parent == 0) { "" } else { node.parent.toString() })), ("parent_type", jsonString(node.parentName)),
            ("instance_count", count.toString()), ("object_ids", joinJson(ids)), ("is_clustered", (count > 1 && !node.cutoff).toString()),
            ("is_cutoff", node.cutoff.toString()), ("cutoff_count", "0"), ("child_types", joinJson(children))
        ])
    }
    func typeTree(parent: String, all: Bool): String {
        let out = ArrayList<String>()
        for (node in types where visibleTypes.contains(node.id)) {
            if (all || parent == (if (node.parent == 0) { "" } else { node.parent.toString() })) { out.add(typeNode(node)) }
        }
        return "{\"nodes\":${joinJson(out)},\"cutoff_count\":${cutoffCount},\"total_skipped\":0}"
    }
    func top(): String {
        let items = ArrayList<String>(); let ids = ArrayList<Int64>()
        for (i in 0..analysis.nodes.size where analysis.idom[i+1] >= 0) { ids.add(i) }
        let ordered = ids.toArray()
        sort(ordered, by: { a, b => analysis.nodes[b].retained.compare(analysis.nodes[a].retained) }, stable: true, descending: false)
        for (rank in 0..ordered.size where rank < 10) {
            let obj = analysis.nodes[ordered[rank]]
            items.add("{\"rank\":${rank+1},\"type\":${jsonString(obj.name)},\"object_id\":${obj.id},\"retained_size\":${obj.retained},\"percentage\":${percent(obj.retained, used)}}")
        }
        return "{\"items\":${joinJson(items)}}"
    }
    func layout(): String {
        let items = ArrayList<String>()
        for (i in 0..8) { items.add("{\"type\":${jsonString(categoryNames[i])},\"size\":${totals[i]}}") }
        return "{\"categories\":${joinJson(items)},\"fragments\":${joinJson(items)},\"regions\":${joinJson(items)}}"
    }
    func summary(): String {
        let fields = ArrayList<(String, String)>()
        fields.add(("free_total", "0")); fields.add(("free_max_continuous", "0")); fields.add(("top10", "[]"))
        let names = ["instance_object_total", "object_array_total", "struct_array_total", "primitive_array_total", "pinned_object_total", "large_object_total", "unmovable_object_total"]
        for (i in 0..7) { fields.add((names[i], totals[i].toString())) }
        return objectJson(fields.toArray())
    }
    func distribution(): String {
        if (analysis.nodes.isEmpty()) { return "{\"address_range_start\":\"0x0\",\"address_range_end\":\"0x0\",\"total_address_range\":0,\"rows\":[]}" }
        let total = end-start
        let bucketCount = Int64((total+65535)/65536)
        let buckets = Array<Array<UInt64>>(bucketCount, { _ => Array<UInt64>(7, repeat: 0) })
        for (obj in analysis.nodes where obj.id > 0 && obj.shallow > 0) { buckets[Int64((obj.id-start)/65536)][obj.category] += obj.shallow }
        let rows = ArrayList<String>(); var pos = start; var rowIndex: Int64 = 0
        while (pos < end) {
            let rowStart = pos; let rowEnd = if (end-pos > 67108864) { pos+67108864 } else { end }
            let segments = ArrayList<String>()
            while (pos < rowEnd) {
                let bucket = Int64((pos-start)/65536)
                let category = dominant(buckets[bucket])
                let segStart = pos
                pos = if (rowEnd-start < UInt64(bucket+1)*65536) { rowEnd } else { start+UInt64(bucket+1)*65536 }
                while (pos < rowEnd && dominant(buckets[Int64((pos-start)/65536)]) == category) {
                    pos = if (rowEnd-pos < 65536) { rowEnd } else { pos+65536 }
                }
                segments.add("{\"type\":${jsonString(categoryNames[category])},\"start_address\":\"0x${hex(segStart)}\",\"end_address\":\"0x${hex(pos)}\",\"size\":${pos-segStart},\"percentage\":${percent(pos-segStart, rowEnd-rowStart)}}")
            }
            rows.add("{\"row_index\":${rowIndex},\"start_address\":\"0x${hex(rowStart)}\",\"end_address\":\"0x${hex(rowEnd)}\",\"size\":${rowEnd-rowStart},\"segments\":${joinJson(segments)}}"); rowIndex++
        }
        return "{\"address_range_start\":\"0x${hex(start)}\",\"address_range_end\":\"0x${hex(end)}\",\"total_address_range\":${total},\"rows\":${joinJson(rows)}}"
    }
    func dominant(bucket: Array<UInt64>): Int64 {
        var winner: Int64 = 7; var max: UInt64 = 0
        for (i in 0..7 where bucket[i] > max) { winner = i; max = bucket[i] }
        return winner
    }
    func route(url: String): (Int64, String, String) {
        let parts = url.split("?", 2)
        let target = decodeUrl(parts[0]); let query = HashMap<String, String>()
        if (parts.size > 1) {
            for (pair in parts[1].split("&")) { let kv = pair.split("=", 2); query[decodeUrl(kv[0])] = if (kv.size > 1) { decodeUrl(kv[1]) } else { "" } }
        }
        let result = match (target) {
            case "/api/snapshot" => snapshot()
            case "/api/dominance/tree" => tree()
            case "/api/dominance/tree-by-type" => typeTree("", true)
            case "/api/dominance/children-by-type" => typeTree(query.get("node_id") ?? "", false)
            case "/api/dominance/children" =>
                try { children(UInt64.parse(query.get("parent_id") ?? "0")) }
                catch (_: Exception) { return (400, "application/json", "{\"error\":\"Invalid parent_id\"}") }
            case "/api/dominance/top10" => top()
            case "/api/dominance/cluster-expand" =>
                let out = ArrayList<String>()
                for (id in (query.get("instance_ids") ?? "").split(",")) {
                    try { if (let Some(i) <- analysis.index.get(UInt64.parse(id))) { out.add(domNode(i)) } } catch (_: Exception) { }
                }
                "{\"nodes\":${joinJson(out)}}"
            case "/api/fragment/overview" => "{\"heap_limit\":536870912,\"used_size\":${used},\"utilization\":${percent(used, 536870912)},\"address_range_start\":${start},\"address_range_end\":${end}}"
            case "/api/fragment/layout" => layout()
            case "/api/fragment/summary" => summary()
            case "/api/fragment/distribution" => distribution()
            case _ =>
                let file = if (target == "/") { "/html/index.html" } else if (target.startsWith("/static/")) { target[7..target.size] } else { return (404, "text/plain", "Not Found") }
                if (file.contains("..") || file.contains("\0") || file.contains("\\")) { return (400, "text/plain", "Bad Request") }
                let mime = if (file.endsWith(".html")) { "text/html" } else if (file.endsWith(".css")) { "text/css" } else if (file.endsWith(".js")) { "application/javascript" } else if (file.endsWith(".svg")) { "image/svg+xml" } else { "application/octet-stream" }
                try { return (200, mime, String.fromUtf8(File.readFrom(staticRoot()+file))) } catch (_: Exception) { return (404, "text/plain", "Not Found") }
        }
        return (200, "application/json", result)
    }
}
func serveHttp(client: TcpSocket, view: HttpView): Unit {
    try {
        let buffer = Array<UInt8>(4096, repeat: 0); var wire = ""
        while (!wire.contains("\r\n\r\n") && wire.size < 32768) {
            let n = client.read(buffer); if (n == 0) { return }
            wire += String.fromUtf8(buffer[0..n].toArray())
        }
        var response: (Int64, String, String) = (400, "text/plain", "Bad Request")
        let lines = wire.split("\r\n")
        let request = lines[0].split(" ")
        if (wire.contains("\r\n\r\n") && request.size == 3 && request[0] == "GET") {
            response = view.route(request[1])
            for (line in lines) {
                let header = line.toAsciiLower()
                if (header.startsWith("transfer-encoding:") && header != "transfer-encoding: chunked") { response = (501, "text/plain", "Not Implemented") }
            }
        }
        let reason = match (response[0]) { case 200 => "OK"; case 400 => "Bad Request"; case 404 => "Not Found"; case 501 => "Not Implemented"; case _ => "Internal Server Error" }
        let bytes = "HTTP/1.1 ${response[0]} ${reason}\r\nContent-Type: ${response[1]}\r\nContent-Length: ${response[2].size}\r\nConnection: close\r\n\r\n${response[2]}".toArray()
        client.write(bytes)
    } catch (_: Exception) { }
    finally { client.close() }
}
func startHttp(a: Analysis, requested: UInt16): Unit {
    let view = HttpView(a)
    var server: Option<TcpServerSocket> = None
    var port = UInt64(requested)
    while (port <= 65535 && port < UInt64(requested)+100) {
        let candidate = TcpServerSocket(bindAt: IPSocketAddress("127.0.0.1", UInt16(port)))
        try { candidate.bind(); server = candidate; break }
        catch (_: Exception) { candidate.close(); port++ }
    }
    let socket = server ?? throw IllegalArgumentException("No available report port")
    println("Access URL: http://localhost:${port}")
    Console.stdOut.flush()
    try {
        while (true) { let client = socket.accept(); spawn { => serveHttp(client, view) } }
    } finally { socket.close() }
}
