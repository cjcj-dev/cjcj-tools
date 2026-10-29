package recordTarget
import std.time.*
import std.convert.*
import std.console.*
foreign func getpid():Int32
@OverflowWrapping
func workload(seed: UInt64): UInt64 {
    var x=seed
    for(_ in 0..100000){x=x*1664525+1013904223}
    return x
}
func worker(seed:UInt64,milliseconds:Int64):UInt64 {
    let deadline=DateTime.now()+milliseconds*Duration.millisecond
    var x=seed
    while(DateTime.now()<deadline){x=workload(x)}
    return x
}
main(args:Array<String>):Unit {
    let milliseconds=if(args.isEmpty()){1500}else{Int64.parse(args[0])}
    println("TARGET_PID ${unsafe{getpid()}}");Console.stdOut.flush()
    let a=spawn{=>worker(1,milliseconds)};let b=spawn{=>worker(2,milliseconds)}
    println(worker(3,milliseconds));println(a.get());println(b.get())
}
