// Direct API coverage of the exact Cangjie library linked by cjtrace-recover.
// This executable is a test artifact and is never installed or packaged.
import cjcj::mangle.*
import std.process.*

main(): Int64 {
    let args = Process.current.arguments
    if (args.isEmpty()) { return 1 }
    let name = args[args.size - 1]
    let info = DemangleType(name, ".")
    println("validation: " + (if (info.IsValid()) { "valid" } else { "invalid" }))
    println("demangled: " + info.GetFullName())
    return 0
}
