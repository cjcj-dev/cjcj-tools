package cjpm.watcher

import std.collection.*
import std.fs.*

@When[os == "Linux"]
foreign {
    func inotify_init1(flags: Int32): Int32
    func inotify_add_watch(fd: Int32, path: CString, mask: UInt32): Int32
    func read(fd: Int32, buffer: CPointer<Unit>, count: UIntNative): IntNative
    func close(fd: Int32): Int32
    func __errno_location(): CPointer<Int32>
}

// Linux UAPI inotify_event: wd/mask/cookie/len, followed by len bytes of name.
// IN_CLOSE_WRITE follows the compiler's completed CJO write. It remains queued
// after unlink; file existence is deliberately not a second publication gate.
@When[os == "Linux"]
class CjoPublicationEvents {
    private var fd: Int32 = -1
    private let directories = HashMap<Int32, String>()

    init(paths: Array<String>) {
        fd = unsafe { inotify_init1(0x800 | 0x80000) } // NONBLOCK | CLOEXEC
        if (fd < 0) { throw Exception("Cannot create CJO notification queue") }
        try {
            let seen = HashSet<String>()
            for (path in paths) {
                let directory = Path(path).parent.toString()
                if (!seen.add(directory)) { continue }
                try (name = unsafe { LibC.mallocCString(directory) }.asResource()) {
                    if (name.value.isNull()) { throw Exception("Cannot allocate CJO watch path") }
                    let wd = unsafe { inotify_add_watch(fd, name.value, 0x8u32 | 0x01000000u32) }
                    if (wd < 0) { throw Exception("Cannot watch CJO directory: "+directory) }
                    directories.add(wd, directory)
                }
            }
        } catch (error: Exception) { close(); throw error }
    }

    func take(): Array<String> {
        let result = ArrayList<String>()
        try (buffer = LibC.malloc<UInt8>(count: 16384).asResource()) {
            if (buffer.value.isNull()) { throw Exception("Cannot allocate CJO event buffer") }
            let count = Int64(unsafe { read(fd, CPointer<Unit>(buffer.value), UIntNative(16384)) })
            if (count < 0) {
                let error = unsafe { __errno_location().read() }
                if (error == 11 || error == 4) { return result.toArray() } // EAGAIN/EINTR
                throw Exception("Cannot read CJO notification queue: ${error}")
            }
            if (count == 0) { throw Exception("CJO notification queue closed unexpectedly") }
            var offset: Int64 = 0
            while (offset < count) {
                if (count-offset < 16) { throw Exception("Truncated CJO event header") }
                let base = unsafe { buffer.value + offset }
                let wd = unsafe { CPointer<Int32>(base).read() }
                let mask = unsafe { CPointer<UInt32>(base+4).read() }
                let length = Int64(unsafe { CPointer<UInt32>(base+12).read() })
                if (length > count-offset-16) { throw Exception("Truncated CJO event name") }
                if ((mask & 0x0000E000u32) != 0) { // UNMOUNT/OVERFLOW/IGNORED
                    throw Exception("CJO notification queue lost events or its watched directory")
                }
                if ((mask & 0x8u32) != 0 && (mask & 0x40000000u32) == 0) {
                    let directory = directories.get(wd) ?? throw Exception("Unknown CJO watch descriptor")
                    var size: Int64 = 0
                    while (size < length && unsafe { base.read(16+size) } != 0) { size++ }
                    if (size == length) { throw Exception("Unterminated CJO event name") }
                    let bytes = Array<UInt8>(size, { i => unsafe { base.read(16+i) } })
                    result.add(Path(directory).join(String.fromUtf8(bytes)).toString())
                }
                offset += 16+length
            }
        }
        return result.toArray()
    }

    func close(): Unit {
        if (fd >= 0) {
            let descriptor = fd
            fd = -1
            let _ = unsafe { close(descriptor) }
        }
    }
}
