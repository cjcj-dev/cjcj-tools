package cjpm.watcher

import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*

// CJC creates and removes .cjo.flag during publication. Linux must retain the
// kernel event even when the file no longer exists. Register before dispatching
// compiler tasks, map exact paths, and join before releasing the event source.
public class CjoPublicationWatcher {
    private let paths: Array<String>
    private let publish: (String) -> Unit
    private let failed: () -> Unit
    private let events: CjoPublicationEvents
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
            if (!exists(directory)) { Directory.create(directory, recursive: true) }
            // A previous interrupted build's flag is not this build's event.
            // Preparation completes before any compiler task is dispatched.
            if (exists(path)) {
                if (!FileInfo(path).isRegular()) { throw IllegalArgumentException("Publication flag is not a file: "+path) }
                remove(path)
            }
        }
        events = CjoPublicationEvents(paths)
    }

    public func run(): Unit {
        let pending = HashSet<String>(paths)
        try {
            while (true) {
                synchronized(mutex) {
                    if (stopped) { return }
                    for (path in events.take()) {
                        if (pending.contains(path)) {
                            publish(path)
                            pending.remove(path)
                        }
                    }
                }
                // Linux queues events independently of this bounded wake-up interval.
                sleep(10 * Duration.millisecond)
            }
        } catch (error: Exception) {
            failed()
            throw error
        } finally { events.close() }
    }

    public func stop(): Unit { synchronized(mutex) { stopped = true } }

    // Caller joins run() before cleaning; no callback can race this removal.
    public func clean(): Unit {
        for (path in paths) { if (exists(path)) { remove(path) } }
    }
}
