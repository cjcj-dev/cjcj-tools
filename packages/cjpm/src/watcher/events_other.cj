package cjpm.watcher

import std.collection.*
import std.fs.*

// Existing non-Linux behavior retained pending each platform's native event
// implementation and actual producer validation. Linux results do not qualify it.
@When[os != "Linux"]
class CjoPublicationEvents {
    private let paths: Array<String>
    init(paths: Array<String>) { this.paths = paths }
    func take(): Array<String> {
        let result = ArrayList<String>()
        for (path in paths) {
            if (exists(path)) {
                if (!FileInfo(path).isRegular()) { throw IllegalStateException("Publication flag is not a file: "+path) }
                result.add(path)
            }
        }
        result.toArray()
    }
    func close(): Unit {}
}
