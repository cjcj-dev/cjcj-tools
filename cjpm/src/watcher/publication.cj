package cjpm.watcher

import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*

// Compiler publication is a persistent .cjo.flag, removed only after the
// build's watcher has joined. Observe exact task paths, not basename events:
// unrelated files and same-name packages in different directories cannot wake
// the wrong monitor. No native watcher or compiler-process token is owned here.
public class CjoPublicationWatcher {
    private let paths: Array<String>
    private let publish: (String) -> Unit
    private let failed: () -> Unit
    private let mutex = Mutex()
    private var stopped = false

    public init(paths: Array<String>, publish: (String) -> Unit, failed: () -> Unit) {
        this.paths = paths
        this.publish = publish
        this.failed = failed
        let seen = HashSet<String>()
        for (path in paths) {
            if (!path.endsWith(".cjo.flag") || !seen.add(path)) {
                throw IllegalArgumentException("Invalid or duplicate CJO publication path: "+path)
            }
            let directory = Path(path).parent.toString()
            if (directory.isEmpty()) { throw IllegalArgumentException("Missing publication directory") }
            if (!exists(directory)) { createDirectory(directory, recursive: true) }
            // A previous interrupted build's flag is not this build's event.
            // Preparation completes before any compiler task is dispatched.
            if (exists(path)) { remove(path) }
        }
    }

    public func run(): Unit {
        let pending = HashSet<String>(paths)
        try {
            while (true) {
                synchronized(mutex) {
                    if (stopped) { return }
                    let published = ArrayList<String>()
                    for (path in pending) { if (exists(path)) { published.add(path) } }
                    for (path in published) {
                        publish(path)
                        pending.remove(path)
                    }
                }
                // std.fs performs the platform system calls. Flags persist,
                // so the bounded scan does not depend on lossy/coalesced events.
                sleep(10 * Duration.millisecond)
            }
        } catch (error: Exception) {
            failed()
            throw error
        }
    }

    public func stop(): Unit { synchronized(mutex) { stopped = true } }

    // Caller joins run() before cleaning; no callback can race this removal.
    public func clean(): Unit {
        for (path in paths) { if (exists(path)) { remove(path) } }
    }
}
