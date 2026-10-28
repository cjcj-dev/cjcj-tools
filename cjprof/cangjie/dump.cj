// Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof
import std.fs.*
foreign func kill(pid: Int32, signal: Int32): Int32

func dumpHeap(pid: Int32, output: String): Int64 {
    if (pid <= 0) { throw IllegalArgumentException("Invalid pid") }
    let cwd = canonicalize("/proc/${pid}/cwd").toString()
    let data = cwd+"/item_data.dat"
    removeIfExists(data)
    if (unsafe { kill(pid,10) } != 0) { throw IllegalArgumentException("Invalid pid") }
    println("Dumping heap ...")
    while (!exists(data)) {
        if (unsafe { kill(pid,0) } != 0) { throw IllegalArgumentException("process exited before heap dump was produced") }
        sleep(100*Duration.millisecond)
    }
    try { rename(data,to:output,overwrite:true) }
    catch (_: Exception) { File.writeTo(output,File.readFrom(data)); remove(data) }
    println("Heap data is successfully dump to file '${output}'.")
    return 0
}
