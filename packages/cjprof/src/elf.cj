// Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof
import std.collection.*
import std.fs.*
import std.sort.*
import std.convert.*
foreign func CJ_MRT_DemangleHandle(name: CString): CPointer<UInt8>
foreign func __cxa_demangle(name: CString, output: CPointer<UInt8>, length: CPointer<UIntNative>, status: CPointer<Int32>): CPointer<UInt8>

func nativeString(ptr: CPointer<UInt8>): String {
    let bytes = ArrayList<UInt8>(); var i: Int64 = 0
    while (true) { let b = unsafe { (ptr+i).read() }; if (b == 0) { break }; bytes.add(b); i++ }
    String.fromUtf8(bytes.toArray())
}
func demangleSymbol(name: String): String {
    let text = unsafe { LibC.mallocCString(name) }
    try {
        let cj = unsafe { CJ_MRT_DemangleHandle(text) }
        if (!cj.isNull()) {
            let result = nativeString(cj); unsafe { LibC.free(cj) }
            if (!result.isEmpty() && result != name) { return result }
        }
        let status: Array<Int32> = [-1]; let handle = unsafe { acquireArrayRawData(status) }
        let cpp = try { unsafe { __cxa_demangle(text,CPointer<UInt8>(),CPointer<UIntNative>(),handle.pointer) } }
                  finally { unsafe { releaseArrayRawData(handle) } }
        if (!cpp.isNull()) { try { if (status[0] == 0) { return nativeString(cpp) } } finally { unsafe { LibC.free(cpp) } } }
    } finally { unsafe { LibC.free(text) } }
    return name
}
class ElfSymbol {
    let address: UInt64
    let size: UInt64
    let name: String
    init(address: UInt64,size: UInt64,name: String) { this.address=address; this.size=size; this.name=name }
}
class ElfImage {
    let symbols = ArrayList<ElfSymbol>()
    var dynamic = false
    init(file: String) {
        let c = Cursor(File.readFrom(file))
        if (c.limit < 64 || c.number(4) != 0x7f454c46 || c.number(1) != 2 || c.number(1) != 1) { throw IllegalArgumentException("unsupported ELF image") }
        c.pos=16; dynamic = c.little(2)==3; c.pos=40; let sections=c.little(8)
        c.pos=58; let width=c.little(2); let count=c.little(2)
        if (width < 64 || sections > UInt64(c.limit) || count > (UInt64(c.limit)-sections)/width) { throw IllegalArgumentException("ELF section table outside file") }
        for (i in 0..Int64(count)) {
            c.pos=Int64(sections+UInt64(i)*width)+4; let kind=c.little(4)
            if (kind != 2 && kind != 11) { continue }
            c.pos+=16; let offset=c.little(8); let length=c.little(8); let link=c.little(4); c.pos+=12; let entry=c.little(8)
            if (entry < 24 || link >= count || offset > UInt64(c.limit) || length > UInt64(c.limit)-offset) { continue }
            c.pos=Int64(sections+link*width)+24; let strings=c.little(8); let stringSize=c.little(8)
            if (strings > UInt64(c.limit) || stringSize > UInt64(c.limit)-strings) { continue }
            for (j in 0..Int64(length/entry)) {
                c.pos=Int64(offset+UInt64(j)*entry)
                let name=c.little(4); let info=c.little(1); c.pos+=3; let value=c.little(8); let size=c.little(8)
                if ((info & 15) != 2 || value == 0 || size == 0 || name >= stringSize) { continue }
                c.pos=Int64(strings+name); let bytes=ArrayList<UInt8>(); var terminated=false
                while (c.pos < Int64(strings+stringSize)) { let b=UInt8(c.number(1)); if(b==0){terminated=true;break}; bytes.add(b) }
                if (terminated) { symbols.add(ElfSymbol(value,size,String.fromUtf8(bytes.toArray()))) }
            }
        }
        let sorted=symbols.toArray(); sort(sorted,by:{a,b => a.address.compare(b.address)},stable:true,descending:false)
        symbols.clear(); for(s in sorted){symbols.add(s)}
    }
    func symbol(address: UInt64): String {
        var lo: Int64=0; var hi=symbols.size
        while(lo<hi){let mid=lo+(hi-lo)/2;if(symbols[mid].address<=address){lo=mid+1}else{hi=mid}}
        if(lo>0){let s=symbols[lo-1];if(address-s.address<s.size){return demangleSymbol(s.name)}}
        return ""
    }
}
class ProcessMap {
    let start: UInt64
    let end: UInt64
    let base: UInt64
    let file: String
    let image: Option<ElfImage>
    init(start:UInt64,end:UInt64,base:UInt64,file:String,image:Option<ElfImage>){this.start=start;this.end=end;this.base=base;this.file=file;this.image=image}
}
class SymbolResolver {
    let maps=ArrayList<ProcessMap>()
    let images=HashMap<String,Option<ElfImage>>()
    let names=HashMap<UInt64,String>()
    func refresh(pid:Int32):Unit {
        let text=String.fromUtf8(File.readFrom("/proc/${pid}/maps"))
        let current=ArrayList<ProcessMap>();let bases=HashMap<String,UInt64>()
        for(line in text.split("\n")){
            let parts=ArrayList<String>();for(p in line.split(" ") where !p.isEmpty()){parts.add(p)}
            if(parts.size<6 || !parts[5].startsWith("/")){continue}
            let range=parts[0].split("-");if(range.size!=2){continue}
            let start=UInt64.parse(range[0],radix:16);let end=UInt64.parse(range[1],radix:16);let offset=UInt64.parse(parts[2],radix:16)
            let file=String.join(parts.toArray()[5..parts.size],delimiter:" ")
            if(!bases.contains(file)){bases[file]=if(start>=offset){start-offset}else{start}}
            if(parts[1]!="r-xp"){continue}
            if(!images.contains(file)){try{images[file]=ElfImage(file)}catch(_:Exception){images[file]=None}}
            current.add(ProcessMap(start,end,bases[file],file,images[file]))
        }
        maps.clear();for(m in current){maps.add(m)}
    }
    func resolve(address:UInt64):String {
        if(let Some(name)<-names.get(address)){return name}
        for(m in maps where address>=m.start && address<m.end){
            let dynamic=m.image?.dynamic ?? true; let relative=if(dynamic){address-m.base}else{address}
            var name=m.image?.symbol(relative) ?? ""
            if(name.isEmpty()){let parts=m.file.split("/");name="[${parts[parts.size-1]}+0x${hex(relative)}]"}
            names[address]=name;return name
        };return ""
    }
}
