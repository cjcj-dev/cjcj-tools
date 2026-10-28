package cjprof
import std.collection.*
func jsonString(s: String): String {
    let out = ArrayList<UInt8>(); out.add(34)
    for (b in s.toArray()) {
        if (b == 34 || b == 92) { out.add(92); out.add(b) }
        else if (b < 32) {
            let escaped = "\\u00" + if (b < 16) { "0" } else { "" } + hex(UInt64(b))
            for (c in escaped.toArray()) { out.add(c) }
        } else { out.add(b) }
    }
    out.add(34)
    return String.fromUtf8(out.toArray())
}

func joinJson(items: ArrayList<String>): String { "[" + String.join(items.toArray(), delimiter: ",") + "]" }
extend Analysis {
    func nodeJson(i: Int64): String {
        let node = nodes[i]
        let children = ArrayList<String>(); for (j in node.children) { children.add(nodes[j].id.toString()) }
        let parents = ArrayList<String>(); for (j in node.parents) { parents.add(nodes[j].id.toString()) }
        let dom = idom[i+1]
        return "{\"id\":${node.id},\"name\":${jsonString(node.name)},\"shallowSize\":${node.shallow},\"retainedSize\":${node.retained},\"distance\":${node.distance},\"root\":${node.root},\"category\":${node.category},\"dominator\":${if (dom <= 0) { "null" } else { nodes[dom-1].id.toString() }},\"children\":${joinJson(children)},\"references\":${joinJson(parents)}}"
    }
    func json(): String {
        let objects = ArrayList<String>()
        for (i in 0..nodes.size) { objects.add(nodeJson(i)) }
        let constructors = ArrayList<String>()
        for (g in sortedGroups()) {
            constructors.add("{\"name\":${jsonString(g.name)},\"count\":${g.nodes.size},\"shallowSize\":${g.shallow},\"retainedSize\":${g.retained}}")
        }
        return "{\"version\":${profile.version},\"idSize\":${profile.idSize},\"objects\":${joinJson(objects)},\"constructors\":${joinJson(constructors)}}"
    }
}
