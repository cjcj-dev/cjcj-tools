package cjpm_watcher_contract
import cjpm.watcher.CjoPublicationWatcher
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*

class Observation {
    let mutex=Mutex()
    let seen=HashSet<String>()
    var failed=false
    var notifications: Int64=0
}

func check(value: Bool, name: String): Unit {
    if (!value) { throw Exception("WATCHER_TARGET_FAIL "+name) }
    println("WATCHER_TARGET_PASS "+name)
}
main(args: Array<String>): Int64 {
    try {
        let root = args[0]
        if (args.size > 1 && args[1] == "control") {
            var bad=false
            try { CjoPublicationWatcher([root+"/invalid"],{ _ => },{ => }) } catch (_: Exception) { bad=true }
            check(bad,"invalid-publication-path-independent-control")
            return 0
        }
        let left=root+"/left/same.cjo.flag"; let right=root+"/right/same.cjo.flag"
        Directory.create(root+"/left", recursive: true)
        File.writeTo(left,"stale".toArray())
        let observed=Observation()
        let watcher=CjoPublicationWatcher([left,right],{ path => synchronized(observed.mutex) { observed.seen.add(path); observed.notifications++; () } },{ => synchronized(observed.mutex) { observed.failed=true } })
        check(!exists(left),"stale-before-dispatch")
        let worker=spawn { => watcher.run() }
        try {
            File.writeTo(root+"/left/unrelated.cjo.flag","noise".toArray())
            File.writeTo(left,"published".toArray())
            File.writeTo(right,"published".toArray())
            var both=false
            for (_ in 0..200) {
                synchronized(observed.mutex) { both=observed.seen.contains(left)&&observed.seen.contains(right) }
                if (both) { break }
                sleep(5*Duration.millisecond)
            }
            check(both,"same-basename-distinct-task-paths")
            synchronized(observed.mutex) { check(observed.seen.size==2,"only-registered-paths") }
            for (_ in 0..60) {
                var duplicate=false
                synchronized(observed.mutex) { duplicate=observed.notifications>2 }
                if (duplicate) { break }
                sleep(5*Duration.millisecond)
            }
            synchronized(observed.mutex) { check(observed.notifications==2,"exactly-once-publication") }
            check(!observed.failed,"normal-no-failure")
        } finally { watcher.stop(); let _=worker.get(); watcher.clean() }
        check(!exists(left)&&!exists(right),"joined-cleanup")
        check(exists(root+"/left/unrelated.cjo.flag"),"unrelated-control-retained")
        // A callback failure must leave the worker with a real error and wake
        // the build's Failed monitors, not silently hang waiting for a flag.
        let broken=root+"/broken/result.cjo.flag"
        let errors=CjoPublicationWatcher([broken],{ _ => throw Exception("expected-publication-error") },{ => observed.failed=true })
        File.writeTo(broken,"published".toArray())
        let errorWorker=spawn { => errors.run() }; var rejected=false
        try { errorWorker.get() } catch (_: Exception) { rejected=true }
        errors.stop(); errors.clean()
        check(rejected&&observed.failed,"worker-error-propagates")
        var bad=false
        try { CjoPublicationWatcher([root+"/invalid"],{ _ => },{ => }) } catch (_: Exception) { bad=true }
        check(bad,"invalid-publication-path-refused")
        return 0
    } catch (error: Exception) { eprintln(error.message); return 41 }
}
