// Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof
import std.collection.*
import std.fs.*
import std.time.*
class ProfileWriter {
    let strings=HashMap<String,UInt64>()
    let traces=HashMap<String,UInt64>()
    let stacks=ArrayList<Array<String>>()
    let counts=ArrayList<UInt64>()
    func sample(names:Array<String>):Unit {
        if(names.isEmpty()){return}
        // Length-prefixed key preserves arbitrary symbol delimiters and NULs.
        var key="";for(n in names){key+="${n.size}:${n}";if(!strings.contains(n)){strings[n]=UInt64(strings.size+1)}}
        let index=traces.get(key) ?? UInt64(stacks.size)
        if(!traces.contains(key)){traces[key]=index;stacks.add(names);counts.add(0)}
        counts[Int64(index)]++
    }
    func write(file:String,frequency:UInt64):Unit {
        let out=BinaryWriter();out.raw("CANGJIE PROFILE 1.0.2".toArray());out.number(0,1);out.big(4,4)
        out.big(UInt64(DateTime.now().toUnixTimeStamp().toMicroseconds()),8)
        for((name,id) in strings){out.number(1,1);out.big(UInt64(name.size+4),4);out.big(id,4);out.raw(name.toArray())}
        for((_,id) in strings){out.number(4,1);out.big(16,8);out.big(id,4);out.big(id,4);out.big(0,4);out.big(0,4)}
        var total:UInt64=0
        for(i in 0..stacks.size){
            out.number(5,1);out.big(UInt64(12+stacks[i].size*4),8);out.big(UInt64(i+1),4);out.big(0,4);out.big(UInt64(stacks[i].size),4)
            for(name in stacks[i]){out.big(strings[name],4)};total+=counts[i]
        }
        out.number(13,1);out.big(UInt64(8+stacks.size*8),8);out.big(1000000/frequency,4);out.big(UInt64(stacks.size),4)
        for(i in 0..stacks.size){out.big(counts[i],4);out.big(UInt64(i+1),4)}
        File.writeTo(file,out.bytes.toArray());println("Recorded ${total} samples in ${stacks.size} stacks to '${file}'.")
    }
}
extend BinaryWriter {
    func big(value:UInt64,n:Int64):Unit {var i=n;while(i>0){i--;bytes.add(UInt8((value >> UInt64(i*8)) & 255))}}
}
