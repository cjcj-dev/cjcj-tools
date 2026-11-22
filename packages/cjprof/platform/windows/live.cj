// The target runtime has no Linux perf or SIGUSR1 heap-dump protocol.
package cjprof

func record(args: Array<String>): Int64 {
    throw IllegalArgumentException("live CPU recording requires Linux perf events")
}

func dumpHeap(pid: Int32, output: String): Int64 {
    throw IllegalArgumentException("live heap dump requires the Linux runtime signal protocol")
}
