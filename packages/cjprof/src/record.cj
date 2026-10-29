// Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import std.runtime.*

// Linux x86-64 system interfaces; no profiling algorithms are delegated to C.
foreign func syscall(number:Int64,attr:CPointer<UInt8>,pid:Int32,cpu:Int32,group:Int32,flags:UInt64):Int64
foreign func mmap(address:CPointer<Unit>,size:UIntNative,prot:Int32,flags:Int32,fd:Int32,offset:Int64):CPointer<UInt8>
foreign func munmap(address:CPointer<UInt8>,size:UIntNative):Int32
foreign func ioctl(fd:Int32,request:UInt64,value:UInt64):Int32
foreign func close(fd:Int32):Int32
foreign func __errno_location():CPointer<Int32>
foreign func __atomic_load_8(address:CPointer<UInt64>,order:Int32):UInt64
foreign func __atomic_store_8(address:CPointer<UInt64>,value:UInt64,order:Int32):Unit
foreign func ptrace(request:Int32,pid:Int32,address:CPointer<Unit>,data:UIntNative):Int64
foreign func waitpid(pid:Int32,status:CPointer<Int32>,options:Int32):Int32
foreign func fork():Int32
foreign func getpid():Int32
foreign func execvp(file:CString,argv:CPointer<CPointer<UInt8>>):Int32
foreign func _exit(code:Int32):Unit
foreign func usleep(microseconds:UInt32):Int32
foreign func pthread_create(thread:CPointer<UIntNative>,attr:CPointer<Unit>,entry:CFunc<(CPointer<Unit>)->CPointer<Unit>>,arg:CPointer<Unit>):Int32
foreign func pthread_join(thread:UIntNative,result:CPointer<CPointer<Unit>>):Int32
func systemError():Int32 { unsafe { __errno_location().read() } }

class RecordConfig {
    var pid:Int32=0
    var command:Array<String>=[]
    var frequency:UInt64=5000
    var output="cjprof.data"
}
class PerfRing {
    let fd:Int32
    let pid:Int32
    let memory:CPointer<UInt8>
    var tail:UInt64=0
    var closed=false
    init(pid:Int32,frequency:UInt64){
        this.pid=pid
        let attr=BinaryWriter();attr.number(1,4);attr.number(128,4);attr.number(0,8);attr.number(frequency,8)
        attr.number(32,8);attr.number(0,8);attr.number(1 | 32 | 256 | 1024,8)
        while(attr.bytes.size<128){attr.number(0,1)}
        let data=attr.bytes.toArray();let handle=unsafe{acquireArrayRawData(data)}
        let result=try{unsafe{syscall(298,handle.pointer,pid,-1,-1,8)}}finally{unsafe{releaseArrayRawData(handle)}}
        if(result<0){throw IllegalArgumentException("perf_event_open pid=${pid} errno=${systemError()}")}
        fd=Int32(result)
        let ptr=unsafe{mmap(CPointer<Unit>(),1052672,3,1,fd,0)}
        if(ptr.toUIntNative()==UIntNative.Max){unsafe{close(fd)};throw IllegalArgumentException("perf mmap errno=${systemError()}")}
        memory=ptr
        if(unsafe{ioctl(fd,0x2403,0)}<0 || unsafe{ioctl(fd,0x2400,0)}<0){unsafe{munmap(memory,1052672);close(fd)};throw IllegalArgumentException("perf enable errno=${systemError()}")}
    }
    func drain(session:RecordSession):Unit {
        let head=unsafe{__atomic_load_8(CPointer<UInt64>(memory+1024),2)}
        let size:UInt64=1048576
        if(head<tail || head-tail>size){throw IllegalArgumentException("perf ring overrun: head=${head} tail=${tail}")}
        let bytes=Array<UInt8>(Int64(head-tail),{i=>unsafe{(memory+4096+Int64((tail+UInt64(i))%size)).read()}})
        let c=Cursor(bytes)
        while(c.pos<c.limit){
            let start=c.pos;let kind=c.little(4);c.little(2);let length=c.little(2)
            if(length<8 || length>UInt64(c.limit-start)){throw IllegalArgumentException("invalid perf record length")}
            let end=start+Int64(length)
            if(kind==9){
                let count=c.little(8)
                if(count>UInt64(end-c.pos)/8){throw IllegalArgumentException("truncated perf callchain")}
                let names=ArrayList<String>()
                for(_ in 0..Int64(count)){
                    let address=c.little(8);if(address==0){break}
                    let name=session.resolver.resolve(address);if(!name.isEmpty()){names.add(name)}
                }
                if(!names.isEmpty()){session.writer.sample(names.toArray());session.sampledThreads.add(pid)}
            }else if(kind==2 && length>=24){c.little(8);session.lost+=c.little(8)}
            else if(kind==1){session.mapsChanged=true}
            c.pos=end
        }
        tail=head;unsafe{__atomic_store_8(CPointer<UInt64>(memory+1032),tail,3)}
    }
    func shutdown():Unit {if(!closed){closed=true;unsafe{ioctl(fd,0x2401,0);munmap(memory,1052672);close(fd)}}}
}
class RecordSession {
    var config=RecordConfig()
    var error=""
    let stop=AtomicBool(false)
    let rings=HashMap<Int32,PerfRing>()
    let traced=HashSet<Int32>()
    let stopped=HashSet<Int32>()
    let resolver=SymbolResolver()
    let writer=ProfileWriter()
    var rootPid:Int32=0
    var lost:UInt64=0
    var mapsChanged=false
    var threadsStarted:Int64=0
    let sampledThreads=HashSet<Int32>()
    func trace(request:Int32,pid:Int32,data:UIntNative):Int64 {
        let rc=unsafe{ptrace(request,pid,CPointer<Unit>(),data)}
        if(rc<0){throw IllegalArgumentException("ptrace request=${request} pid=${pid} errno=${systemError()}")};rc
    }
    func status(pid:Int32,options:Int32):Option<Int32>{
        let data:Array<Int32>=[0];let handle=unsafe{acquireArrayRawData(data)}
        let rc=try{unsafe{waitpid(pid,handle.pointer,options)}}finally{unsafe{releaseArrayRawData(handle)}}
        if(rc==0){return None};if(rc<0){if(systemError()==4){return None};throw IllegalArgumentException("waitpid pid=${pid} errno=${systemError()}")};return data[0]
    }
    func launch():Int32 {
        let texts=ArrayList<CString>();for(arg in config.command){texts.add(unsafe{LibC.mallocCString(arg)})}
        let pointers=Array<CPointer<UInt8>>(texts.size+1,{i=>if(i<texts.size){texts[i].getChars()}else{CPointer<UInt8>()}})
        let raw=unsafe{acquireArrayRawData(pointers)}
        try{
            let pid=unsafe{fork()}
            if(pid==0){
                // Only async-safe native calls between fork and exec, no heap work.
                let rc=unsafe{kill(getpid(),19)}
                if(rc<0){unsafe{_exit(126)}}
                unsafe{execvp(texts[0],raw.pointer);_exit(127)}
            }
            if(pid<0){throw IllegalArgumentException("fork errno=${systemError()}")};return pid
        }finally{unsafe{releaseArrayRawData(raw)};for(text in texts){unsafe{LibC.free(text)}}}
    }
    func start(pid:Int32):Unit {
        traced.add(pid);trace(0x4200,pid,UIntNative(8|64))
        rings[pid]=PerfRing(pid,config.frequency);threadsStarted++
        trace(7,pid,0);stopped.remove(pid)
    }
    func run():Unit {
        rootPid=if(config.command.isEmpty()){config.pid}else{launch()}
        var completed=false
        try{
            if(!config.command.isEmpty()){
                let initial=status(rootPid,2).getOrThrow()
                if((initial & 255)!=127){throw IllegalArgumentException("target launch stop failed")}
            }
            trace(0x4206,rootPid,UIntNative(8|64));traced.add(rootPid)
            trace(0x4207,rootPid,0)
            let first=status(rootPid,0x40000000).getOrThrow();stopped.add(rootPid)
            if(!config.command.isEmpty()){unsafe{kill(rootPid,18)}}
            if((first & 255)!=127){throw IllegalArgumentException("target exited before profiling, wait status=${first}")}
            resolver.refresh(rootPid)
            if(config.command.isEmpty()){
                for(info in Directory.readFrom("/proc/${rootPid}/task")){
                    let tid=Int32.parse(info.name);if(tid==rootPid){continue}
                    trace(0x4206,tid,UIntNative(8|64));traced.add(tid);trace(0x4207,tid,0);status(tid,0x40000000);stopped.add(tid);start(tid)
                }
            }
            start(rootPid)
            while(!rings.isEmpty() && !stop.load()){
                for(pid in rings.keys().toArray()){
                    rings[pid].drain(this)
                    let state=status(pid,0x40000001) ?? continue
                    if((state & 255)==127){
                        stopped.add(pid)
                        let event=state >> 16
                        if(event==3){
                            let data:Array<UInt64>=[0];let handle=unsafe{acquireArrayRawData(data)}
                            try{trace(0x4201,pid,handle.pointer.toUIntNative())}finally{unsafe{releaseArrayRawData(handle)}}
                            let child=Int32(data[0]);traced.add(child);status(child,0x40000000);stopped.add(child);start(child);trace(7,pid,0);stopped.remove(pid)
                        }else if(event==6){
                            try{resolver.refresh(rootPid)}catch(_:Exception){}
                            rings[pid].drain(this);rings[pid].shutdown();rings.remove(pid);trace(17,pid,0);traced.remove(pid);stopped.remove(pid)
                        }else{let signal=state >> 8 & 255;trace(7,pid,UIntNative(if(signal==5 || signal==19){Int32(0)}else{signal}));stopped.remove(pid)}
                    }else{rings[pid].shutdown();rings.remove(pid);traced.remove(pid)}
                }
                if(mapsChanged){mapsChanged=false;try{resolver.refresh(rootPid)}catch(_:Exception){}}
                unsafe{usleep(1000)}
            }
            completed=true
        }finally{
            for((_,ring) in rings){try{ring.drain(this)}catch(_:Exception){};ring.shutdown()};rings.clear()
            if(!traced.isEmpty()){
                // SEIZE/INTERRUPT stops each tracee without introducing a
                // process-wide SIGSTOP or changing an attached target's signals.
                let pending=ArrayList<Int32>()
                for(pid in traced){pending.add(pid);if(!stopped.contains(pid)){unsafe{ptrace(0x4207,pid,CPointer<Unit>(),0)}}}
                var index:Int64=0
                while(index<pending.size){
                    let pid=pending[index];index++
                    try{
                        if(!stopped.contains(pid)){
                            let state=status(pid,0x40000000) ?? continue
                            if((state & 255)!=127){continue}
                            if(state >> 16 == 3){
                                let data:Array<UInt64>=[0];let raw=unsafe{acquireArrayRawData(data)}
                                try{trace(0x4201,pid,raw.pointer.toUIntNative())}finally{unsafe{releaseArrayRawData(raw)}}
                                let child=Int32(data[0]);if(!traced.contains(child)){traced.add(child);pending.add(child)}
                            }
                        }
                        trace(17,pid,0)
                    }catch(_:Exception){}
                }
            }
            traced.clear();stopped.clear()
            if(!config.command.isEmpty()){
                if(stop.load() || !completed){unsafe{kill(rootPid,15)}}
                try{status(rootPid,0)}catch(_:Exception){}
            }
        }
        writer.write(config.output,config.frequency)
        println("Sampled ${sampledThreads.size} of ${threadsStarted} traced threads.")
        if(lost>0){println("warning: ${lost} perf samples lost")}
    }
}
let recordSession=RecordSession()
@C
func runRecordNative(arg:CPointer<Unit>):CPointer<Unit>{
    try{recordSession.run()}catch(e:Exception){recordSession.error=e.message};CPointer<Unit>()
}
func recordHelp():Unit {println("Usage: cjprof record [options] [--] command [args]\n  -f, --freq FREQ  sample frequency or max (default 5000)\n  -p, --pid PID    attach to existing process\n  -o, --output FILE (default cjprof.data)")}
func record(args:Array<String>):Int64 {
    let cfg=RecordConfig();var maximum:UInt64=5000
    try{maximum=UInt64.parse(String.fromUtf8(File.readFrom("/proc/sys/kernel/perf_event_max_sample_rate")).trimAscii())}catch(_:Exception){}
    let parsed=parseCli(args,[CliSpec("freq","f",1),CliSpec("help","h",0),CliSpec("output","o",1),CliSpec("pid","p",1)])
    cfg.command=parsed.operands.toArray()
    for(option in parsed.options){
        let value=option.value ?? ""
        match(option.name){
            case "help" => recordHelp();return 1
            case "output" => cfg.output=value
            case "pid" =>
                try{let id=cliPositive(value);if(id>2147483647){throw IllegalArgumentException("Invalid pid")};cfg.pid=Int32(id)}
                catch(_:Exception){cfg.pid=0;println("error: Invalid pid '${value}'.")}
            case "freq" =>
                if(value=="max"){cfg.frequency=maximum;println("info: Using a maximum frequency rate of ${maximum} Hz.")}
                else{
                    try{let f=cliPositive(value);cfg.frequency=if(f>maximum){println("warning: Maximum frequency rate (${maximum} Hz) exceeded, throttling from ${f} Hz to ${maximum} Hz.");maximum}else{f}}
                    catch(_:Exception){println("warning: Invalid frequency value, use the default value (${cfg.frequency} Hz).")}
                }
            case _ => throw IllegalArgumentException("unsupported record option ${option.name}")
        }
    }
    if(cfg.command.isEmpty() && cfg.pid<=0){recordHelp();return 1}
    recordSession.config=cfg
    let handler:SignalHandlerFunc={_=>recordSession.stop.store(true);true}
    registerSignalHandler(Signal.SIGINT,handler)
    let thread:Array<UIntNative>=[0];let raw=unsafe{acquireArrayRawData(thread)}
    let rc=try{unsafe{pthread_create(raw.pointer,CPointer<Unit>(),runRecordNative,CPointer<Unit>())}}finally{unsafe{releaseArrayRawData(raw)}}
    if(rc!=0){throw IllegalArgumentException("pthread_create rc=${rc}")}
    let joined=unsafe{pthread_join(thread[0],CPointer<CPointer<Unit>>())}
    unregisterSignalHandler(Signal.SIGINT,handler)
    if(joined!=0){throw IllegalArgumentException("pthread_join rc=${joined}")}
    if(!recordSession.error.isEmpty()){throw IllegalArgumentException(recordSession.error)}
    return 0
}
