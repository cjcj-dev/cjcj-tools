package dumpTarget
import std.console.*
class Payload { let value: Int64; init(value: Int64) { this.value=value } }
main(): Unit {
    let objects = Array<Payload>(300,{i => Payload(i)})
    println("DUMP_TARGET_READY"); Console.stdOut.flush()
    sleep(20*Duration.second)
    println(objects[299].value)
}
