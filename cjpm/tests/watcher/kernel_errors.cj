package cjpm_watcher_kernel_errors

import cjpm.watcher.CjoPublicationWatcher
import std.fs.*
import std.collection.*
import std.sync.*
import std.time.*

foreign {
    func readlink(path: CString, buffer: CPointer<UInt8>, size: UIntNative): IntNative
    func close(fd: Int32): Int32
}

func queues(): Array<Int32> {
    let result = ArrayList<Int32>()
    for (fd in 3..1024) {
        try (name = unsafe { LibC.mallocCString("/proc/self/fd/${fd}") }.asResource(),
             buffer = LibC.malloc<UInt8>(count: 128).asResource()) {
            let count = Int64(unsafe { readlink(name.value, buffer.value, UIntNative(128)) })
            if (count > 0) {
                let bytes = Array<UInt8>(count, { i => unsafe { buffer.value.read(i) } })
                if (String.fromUtf8(bytes) == "anon_inode:inotify") { result.add(Int32(fd)) }
            }
        }
    }
    result.toArray()
}

main(args: Array<String>): Int64 {
    try {
        let root = args[0]; let mode = args[1]
        if (!queues().isEmpty()) { throw Exception("unexpected pre-existing queue") }
        let mutex = Mutex(); var failed = false; var published: Int64 = 0
        let watcher = CjoPublicationWatcher([root+"/target.cjo.flag"],
            { _ => synchronized(mutex) { published++ } },
            { => synchronized(mutex) { failed=true } })
        let descriptors = queues()
        if (descriptors.size != 1) { throw Exception("expected one product queue") }
        if (mode == "read-error") {
            if (unsafe { close(descriptors[0]) } != 0) { throw Exception("cannot cut actual queue descriptor") }
        } else if (mode == "overflow") {
            let capacity = Int64.parse(args[2])
            if (capacity < 1 || capacity > 262144) { throw Exception("unexpected kernel queue capacity") }
            // Alternate names prevent adjacent-event coalescing. Only two real
            // files exist; neither is a registered target, and no CJO is faked.
            for (_ in 0..(capacity+1)) {
                File.writeTo(root+"/noise-a",[1u8])
                File.writeTo(root+"/noise-b",[2u8])
            }
        } else { throw Exception("unknown mode") }
        let worker = spawn { => watcher.run() }
        for (_ in 0..1000) {
            var done = false
            synchronized(mutex) { done=failed }
            if (done) { break }
            sleep(5*Duration.millisecond)
        }
        watcher.stop()
        var rejected=false
        try { worker.get() } catch (error: Exception) { rejected=true; println("KERNEL_ERROR ${error.message}") }
        watcher.clean()
        if (!failed || !rejected || published != 0 || !queues().isEmpty()) {
            throw Exception("kernel error did not propagate and release its queue")
        }
        println("KERNEL_ERROR_PASS ${mode} failed=1 rejected=1 published=0 queues=0")
        return 0
    } catch(error: Exception) { eprintln(error.message); return 41 }
}
