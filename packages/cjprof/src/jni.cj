// Copyright (c) Huawei Technologies Co., Ltd. 2025-2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cjprof
import std.collection.*
import std.sync.*

type JObject = CPointer<Unit>
type JEnv = CPointer<CPointer<JObject>>
let snapshotStore = SnapshotStore()
let jniMutex = Mutex()
let nodeHandles = HashMap<UInt64, Int32>()
var nextNodeHandle: Int32 = 1
@OverflowWrapping
func javaLong(value: UInt64): Int64 { Int64(value) }
@OverflowWrapping
func unsignedLong(value: Int64): UInt64 { UInt64(value) }
@OverflowWrapping
func javaInt(value: UInt64): Int32 { Int32(value) }
@OverflowWrapping
func javaInt(value: Int64): Int32 { Int32(value) }

// JNI table indices are defined by JDK jni.h, not by a C adapter.
class Jni {
    let env: JEnv
    init(env: JEnv) { this.env = env }
    func slot(index: Int64): JObject { unsafe { (env.read()+index).read() } }
    func pending(): Bool { unsafe { CFunc<(JEnv)->UInt8>(slot(228))(env) != 0 } }
    func checked(value: JObject): JObject {
        if (value.isNull() || pending()) { throw IllegalArgumentException("JNI call failed") }; value
    }
    func find(name: String): JObject {
        let c = unsafe { LibC.mallocCString(name) }
        try { checked(unsafe { CFunc<(JEnv,CString)->JObject>(slot(6))(env,c) }) }
        finally { unsafe { LibC.free(c) } }
    }
    func method(cls: JObject, name: String, signature: String): JObject {
        let n = unsafe { LibC.mallocCString(name) }; let s = unsafe { LibC.mallocCString(signature) }
        try { checked(unsafe { CFunc<(JEnv,JObject,CString,CString)->JObject>(slot(33))(env,cls,n,s) }) }
        finally { unsafe { LibC.free(n) }; unsafe { LibC.free(s) } }
    }
    func field(cls: JObject, name: String, signature: String): JObject {
        let n = unsafe { LibC.mallocCString(name) }; let s = unsafe { LibC.mallocCString(signature) }
        try { checked(unsafe { CFunc<(JEnv,JObject,CString,CString)->JObject>(slot(94))(env,cls,n,s) }) }
        finally { unsafe { LibC.free(n) }; unsafe { LibC.free(s) } }
    }
    func drop(obj: JObject): Unit { if (!obj.isNull()) { unsafe { CFunc<(JEnv,JObject)->Unit>(slot(23))(env,obj) } } }
    func allocate(name: String): JObject {
        let cls = find(name)
        try { checked(unsafe { CFunc<(JEnv,JObject)->JObject>(slot(27))(env,cls) }) }
        finally { drop(cls) }
    }
    func klass(obj: JObject): JObject { checked(unsafe { CFunc<(JEnv,JObject)->JObject>(slot(31))(env,obj) }) }
    func setObject(obj: JObject, name: String, signature: String, value: JObject): Unit {
        let cls = klass(obj)
        try { unsafe { CFunc<(JEnv,JObject,JObject,JObject)->Unit>(slot(104))(env,obj,field(cls,name,signature),value) } }
        finally { drop(cls) }
    }
    func setInt(obj: JObject, name: String, value: Int32): Unit {
        let cls = klass(obj)
        try { unsafe { CFunc<(JEnv,JObject,JObject,Int32)->Unit>(slot(109))(env,obj,field(cls,name,"I"),value) } }
        finally { drop(cls) }
    }
    func setLong(obj: JObject, name: String, value: Int64): Unit {
        let cls = klass(obj)
        try { unsafe { CFunc<(JEnv,JObject,JObject,Int64)->Unit>(slot(110))(env,obj,field(cls,name,"J"),value) } }
        finally { drop(cls) }
    }
    func setDouble(obj: JObject, name: String, value: Float64): Unit {
        let cls = klass(obj)
        try { unsafe { CFunc<(JEnv,JObject,JObject,Float64)->Unit>(slot(112))(env,obj,field(cls,name,"D"),value) } }
        finally { drop(cls) }
    }
    func setBool(obj: JObject, name: String, value: Bool): Unit {
        let cls = klass(obj)
        try { unsafe { CFunc<(JEnv,JObject,JObject,UInt8)->Unit>(slot(105))(env,obj,field(cls,name,"Z"),if(value){1}else{0}) } }
        finally { drop(cls) }
    }
    func string(value: String): JObject {
        // Decode ordinary UTF-8 into JNI UTF-16; NewStringUTF uses modified UTF-8.
        let bytes = value.toArray(); let units = ArrayList<UInt16>(); var i: Int64 = 0
        while (i < bytes.size) {
            let first = UInt32(bytes[i]); i++
            var cp = first; var following: Int64 = 0
            if (first >= 0xf0) { cp = first & 7; following = 3 }
            else if (first >= 0xe0) { cp = first & 15; following = 2 }
            else if (first >= 0xc0) { cp = first & 31; following = 1 }
            for (_ in 0..following) { cp = (cp << 6) | (UInt32(bytes[i]) & 63); i++ }
            if (cp < 0x10000) { units.add(UInt16(cp)) }
            else { let v = cp-0x10000; units.add(UInt16(0xd800+(v >> 10))); units.add(UInt16(0xdc00+(v & 1023))) }
        }
        let data = units.toArray(); let handle = unsafe { acquireArrayRawData(data) }
        try { checked(unsafe { CFunc<(JEnv,CPointer<UInt16>,Int32)->JObject>(slot(163))(env,handle.pointer,Int32(data.size)) }) }
        finally { unsafe { releaseArrayRawData(handle) } }
    }
    func text(obj: JObject): String {
        if (obj.isNull()) { throw IllegalArgumentException("null Java string") }
        let length = unsafe { CFunc<(JEnv,JObject)->Int32>(slot(164))(env,obj) }
        let chars = unsafe { CFunc<(JEnv,JObject,CPointer<UInt8>)->CPointer<UInt16>>(slot(165))(env,obj,CPointer<UInt8>()) }
        if (chars.isNull()) { throw IllegalArgumentException("cannot read Java string") }
        try {
            var out = ""; var i: Int64 = 0
            while (i < Int64(length)) {
                var cp = UInt32(unsafe { (chars+i).read() }); i++
                if (cp >= 0xd800 && cp <= 0xdbff && i < Int64(length)) {
                    let low = UInt32(unsafe { (chars+i).read() })
                    if (low >= 0xdc00 && low <= 0xdfff) { cp = 0x10000+((cp-0xd800)<<10)+(low-0xdc00); i++ }
                }
                if (cp >= 0xd800 && cp <= 0xdfff) { cp = 0xfffd }
                out += Rune(cp).toString()
            }
            return out
        } finally { unsafe { CFunc<(JEnv,JObject,CPointer<UInt16>)->Unit>(slot(166))(env,obj,chars) } }
    }
    func setString(obj: JObject, name: String, text: String): Unit {
        let value = string(text); try { setObject(obj,name,"Ljava/lang/String;",value) } finally { drop(value) }
    }
    func list(): JObject {
        let cls = find("java/util/ArrayList")
        try { checked(unsafe { CFunc<(JEnv,JObject,JObject,CPointer<UInt64>)->JObject>(slot(30))(env,cls,method(cls,"<init>","()V"),CPointer<UInt64>()) }) }
        finally { drop(cls) }
    }
    func add(list: JObject, value: JObject): Unit {
        let cls = klass(list); let data: Array<UInt64> = [UInt64(value.toUIntNative())]
        let handle = unsafe { acquireArrayRawData(data) }
        try {
            unsafe { CFunc<(JEnv,JObject,JObject,CPointer<UInt64>)->UInt8>(slot(39))(env,list,method(cls,"add","(Ljava/lang/Object;)Z"),handle.pointer) }
            if (pending()) { throw IllegalArgumentException("cannot append Java list") }
        } finally { unsafe { releaseArrayRawData(handle) }; drop(cls) }
    }
    func listSize(obj: JObject): Int32 {
        let cls = klass(obj)
        try { let result = unsafe { CFunc<(JEnv,JObject,JObject,CPointer<UInt64>)->Int32>(slot(51))(env,obj,method(cls,"size","()I"),CPointer<UInt64>()) }; if (pending()) { throw IllegalArgumentException("cannot read list size") }; result }
        finally { drop(cls) }
    }
    func listGet(obj: JObject, index: Int32): JObject {
        let cls = klass(obj); let data: Array<UInt64> = [UInt64(index)]; let handle = unsafe { acquireArrayRawData(data) }
        try { checked(unsafe { CFunc<(JEnv,JObject,JObject,CPointer<UInt64>)->JObject>(slot(36))(env,obj,method(cls,"get","(I)Ljava/lang/Object;"),handle.pointer) }) }
        finally { unsafe { releaseArrayRawData(handle) }; drop(cls) }
    }
    func longValue(obj: JObject): UInt64 {
        let cls = klass(obj)
        try { let result = unsafe { CFunc<(JEnv,JObject,JObject,CPointer<UInt64>)->Int64>(slot(54))(env,obj,method(cls,"longValue","()J"),CPointer<UInt64>()) }; if (pending()) { throw IllegalArgumentException("cannot read boxed long") }; unsignedLong(result) }
        finally { drop(cls) }
    }
    func strings(list: JObject): ArrayList<String> {
        let out = ArrayList<String>()
        for (i in 0..Int64(listSize(list))) { let item = listGet(list,Int32(i)); try { out.add(text(item)) } finally { drop(item) } }; out
    }
    func ids(list: JObject): ArrayList<UInt64> {
        let out = ArrayList<UInt64>()
        for (i in 0..Int64(listSize(list))) { let item = listGet(list,Int32(i)); try { out.add(longValue(item)) } finally { drop(item) } }; out
    }
    func rootTypes(set: JObject): HashSet<Int64> {
        let cls = klass(set)
        let array = checked(unsafe { CFunc<(JEnv,JObject,JObject,CPointer<UInt64>)->JObject>(slot(36))(env,set,method(cls,"toArray","()[Ljava/lang/Object;"),CPointer<UInt64>()) }); drop(cls)
        let out = HashSet<Int64>()
        try {
            let size = unsafe { CFunc<(JEnv,JObject)->Int32>(slot(171))(env,array) }
            for (i in 0..Int64(size)) {
                let item = unsafe { CFunc<(JEnv,JObject,Int32)->JObject>(slot(173))(env,array,Int32(i)) }; let itemClass = klass(item)
                let value = unsafe { CFunc<(JEnv,JObject,JObject,CPointer<UInt64>)->Int8>(slot(42))(env,item,method(itemClass,"byteValue","()B"),CPointer<UInt64>()) }
                if (pending()) { throw IllegalArgumentException("cannot read boxed byte") }; out.add(Int64(value) & 255); drop(itemClass); drop(item)
            }
        } finally { drop(array) }; out
    }
    func nodes(nodes: ArrayList<ApiNode>, constructor: Bool, diff: Bool): JObject {
        let out = list()
        for (n in nodes) { let obj = node(n,constructor,diff); try { add(out,obj) } finally { drop(obj) } }; out
    }
    func node(n: ApiNode, constructor: Bool, diff: Bool): JObject {
        let name = if (constructor) { if(diff){"ConstructorDiffNode"}else{"ConstructorNode"} } else { if(diff){"InstanceDiffNode"}else{"InstanceNode"} }
        let out = allocate("com/cjprof/jni/model/"+name)
        setString(out,"className",n.className); setLong(out,"id",javaLong(n.id))
        if (!nodeHandles.contains(n.id)) { if (nextNodeHandle == Int32.Max) { throw IllegalArgumentException("Cannot allocate new node index") }; nextNodeHandle++; nodeHandles[n.id] = nextNodeHandle }
        setInt(out,"nodeIndex",nodeHandles[n.id]); setInt(out,"totalSize",javaInt(n.totalSize))
        setInt(out,"distance",javaInt(n.distance)); setInt(out,"shallowSize",javaInt(n.shallowSize)); setInt(out,"retainedSize",javaInt(n.retainedSize))
        setDouble(out,"shallowSizePercent",n.shallowSizePercent); setDouble(out,"retainedSizePercent",n.retainedSizePercent)
        setInt(out,"childrenCount",javaInt(n.childrenCount)); setInt(out,"startPosition",javaInt(n.startPosition)); setInt(out,"endPosition",javaInt(n.endPosition))
        let children = nodes(n.children,false,false); setObject(out,"children","Ljava/util/List;",children); drop(children)
        if (constructor) { setDouble(out,"totalInstanceCountPercent",n.totalInstanceCountPercent) }
        else {
            setString(out,"type",n.nodeType); setString(out,"rootType",n.rootType)
            setInt(out,"retainerCount",javaInt(n.retainerCount)); setInt(out,"arrayLength",javaInt(n.arrayLength))
            let retainers = nodes(n.retainers,false,false); setObject(out,"retainerNodes","Ljava/util/List;",retainers); drop(retainers)
        }
        if (diff) {
            setInt(out,"addedCount",javaInt(n.addedCount)); setInt(out,"removedCount",javaInt(n.removedCount))
            setInt(out,"addedSize",javaInt(n.addedSize)); setInt(out,"removedSize",javaInt(n.removedSize))
            setLong(out,"countDelta",n.addedCount-n.removedCount); setLong(out,"sizeDelta",javaLong(n.addedSize)-javaLong(n.removedSize))
            if (constructor) {
                setInt(out,"baseTotalSize",javaInt(n.baseTotalSize)); setInt(out,"targetTotalSize",javaInt(n.targetTotalSize))
                let states = list()
                for (state in n.childAddedStates) {
                    let boxed = allocate("java/lang/Boolean"); setBool(boxed,"value",state); add(states,boxed); drop(boxed)
                }
                setObject(out,"childAddedStates","Ljava/util/List;",states); drop(states)
            } else { setBool(out,"added",n.added) }
        }
        return out
    }
    func snapshots(): JObject {
        let out = list()
        for ((_, s) in snapshotStore.snapshots) {
            let obj = allocate("com/cjprof/jni/model/HeapSnapshot"); setLong(obj,"id",javaLong(s.id)); setLong(obj,"fileSize",s.fileSize); setString(obj,"filePath",s.path)
            add(out,obj); drop(obj)
        }; out
    }
    func threads(snapshot: Snapshot): JObject {
        let out = list(); let p = snapshot.analysis.profile
        for ((_, thread) in p.threads) {
            let obj = allocate("com/cjprof/jni/model/ThreadInfo"); let name = p.text(thread.name)
            setString(obj,"name",name); setLong(obj,"id",javaLong(snapshotHash(name))); let frames = list()
            if (let Some(trace) <- p.traces.get(thread.trace)) {
                for (depth in 0..trace.frames.size) {
                    let frame = p.frames.get(trace.frames[depth]) ?? continue
                    let fr = allocate("com/cjprof/jni/model/Frame"); let funcName = p.text(frame.name)
                    setString(fr,"funcName",funcName); setString(fr,"fileName",p.text(frame.file)); setInt(fr,"line",javaInt(frame.line)); setLong(fr,"id",javaLong(snapshotHash(funcName)))
                    let locals = list()
                    for ((id, location) in p.locals where location[0] == thread.index && location[1] == UInt64(depth)) {
                        if (let Some(index) <- snapshot.analysis.index.get(id)) { let local = node(snapshot.instance(index),false,false); add(locals,local); drop(local) }
                    }
                    setObject(fr,"locals","Ljava/util/List;",locals); drop(locals); add(frames,fr); drop(fr)
                }
            }
            setObject(obj,"frames","Ljava/util/List;",frames); drop(frames); add(out,obj); drop(obj)
        }; out
    }
}
func jniObject(env: JEnv, body: (Jni)->JObject): JObject {
    synchronized(jniMutex) {
        let j = Jni(env)
        let rc = unsafe { CFunc<(JEnv,Int32)->Int32>(j.slot(19))(env,128) }
        if (rc < 0) { return JObject() }
        var out = JObject()
        try { out = body(j) }
        catch (e: Exception) {
            if (!j.pending()) {
                let cls = j.find("com/cjprof/jni/CjprofException"); let text = unsafe { LibC.mallocCString(e.message) }
                try { unsafe { CFunc<(JEnv,JObject,CString)->Int32>(j.slot(14))(env,cls,text) } }
                finally { unsafe { LibC.free(text) }; j.drop(cls) }
            }
        }
        return unsafe { CFunc<(JEnv,JObject)->JObject>(j.slot(20))(env,out) }
    }
}

@C
public func Java_com_cjprof_jni_Cjprof_initialize(env: JEnv, cls: JObject): Unit {
    jniObject(env,{ j => j.find("com/cjprof/jni/model/InstanceNode"); JObject() });
}

@C
public func Java_com_cjprof_jni_Cjprof_parseHeapSnapshotFiles(env: JEnv, cls: JObject, paths: JObject): UInt8 {
    let result: Array<UInt8> = [0]; jniObject(env,{ j => if(snapshotStore.load(j.strings(paths))){result[0]=1}; JObject() }); return result[0]
}

@C
public func Java_com_cjprof_jni_Cjprof_cleanHeapSnapshotFiles(env: JEnv, cls: JObject, ids: JObject): Unit {
    jniObject(env,{ j => snapshotStore.clean(j.ids(ids)); nodeHandles.clear(); nextNodeHandle=1; JObject() });
}

@C
public func Java_com_cjprof_jni_Cjprof_queryAllHeapSnapshot(env: JEnv, cls: JObject): JObject {
    return jniObject(env,{ j => j.snapshots() })
}

@C
public func Java_com_cjprof_jni_Cjprof_getSnapshotIDByFilePath(env: JEnv, cls: JObject, path: JObject): Int64 {
    let result: Array<Int64> = [0]; jniObject(env,{ j => result[0]=javaLong(snapshotStore.snapshotId(j.text(path))); JObject() }); return result[0]
}

@C
public func Java_com_cjprof_jni_Cjprof_getConstructorNodesBySnapshotID(env: JEnv, cls: JObject, id: Int64): JObject {
    return jniObject(env,{ j => j.nodes((snapshotStore.snapshots.get(unsignedLong(id))?.allConstructors() ?? ArrayList<ApiNode>()),true,false) })
}

@C
public func Java_com_cjprof_jni_Cjprof_getRootNodesBySnapshotID(env: JEnv, cls: JObject, id: Int64, types: JObject): JObject {
    return jniObject(env,{ j => j.nodes((snapshotStore.snapshots.get(unsignedLong(id))?.roots(j.rootTypes(types)) ?? ArrayList<ApiNode>()),true,false) })
}

@C
public func Java_com_cjprof_jni_Cjprof_getRootDiffNodesBySnapshotID(env: JEnv, cls: JObject, base: Int64, target: Int64, types: JObject): JObject {
    return jniObject(env,{ j => j.nodes(snapshotStore.rootDiff(unsignedLong(base),unsignedLong(target),j.rootTypes(types)),true,true) })
}

@C
public func Java_com_cjprof_jni_Cjprof_expandConstructorNode(env: JEnv, cls: JObject, snapshot: Int64, id: Int64, start: Int32, length: Int32): JObject {
    return jniObject(env,{ j => j.node((snapshotStore.snapshots.get(unsignedLong(snapshot))?.constructor(unsignedLong(id),Int64(start),Int64(length)) ?? ApiNode()),true,false) })
}

@C
public func Java_com_cjprof_jni_Cjprof_expandConstructorDiffNode(env: JEnv, cls: JObject, base: Int64, target: Int64, id: Int64, start: Int32, length: Int32): JObject {
    return jniObject(env,{ j => j.node(snapshotStore.constructorDiff(unsignedLong(base),unsignedLong(target),unsignedLong(id),Int64(start),Int64(length)),true,true) })
}

@C
public func Java_com_cjprof_jni_Cjprof_expandInstanceNode(env: JEnv, cls: JObject, snapshot: Int64, id: Int64, start: Int32, length: Int32): JObject {
    return jniObject(env,{ j => j.node((snapshotStore.snapshots.get(unsignedLong(snapshot))?.expand(unsignedLong(id),Int64(start),Int64(length),true,true) ?? ApiNode()),false,false) })
}

@C
public func Java_com_cjprof_jni_Cjprof_expandInstanceDiffNode(env: JEnv, cls: JObject, base: Int64, target: Int64, id: Int64, start: Int32, length: Int32): JObject {
    return jniObject(env,{ j => j.node(snapshotStore.instanceDiff(unsignedLong(base),unsignedLong(target),unsignedLong(id),Int64(start),Int64(length),true,true),false,true) })
}

@C
public func Java_com_cjprof_jni_Cjprof_expandDetailNode(env: JEnv, cls: JObject, snapshot: Int64, id: Int64, reference: UInt8, start: Int32, length: Int32): JObject {
    return jniObject(env,{ j => j.node((snapshotStore.snapshots.get(unsignedLong(snapshot))?.expand(unsignedLong(id),Int64(start),Int64(length),reference==0,reference!=0) ?? ApiNode()),false,false) })
}

@C
public func Java_com_cjprof_jni_Cjprof_expandDetailDiffNode(env: JEnv, cls: JObject, base: Int64, target: Int64, id: Int64, reference: UInt8, start: Int32, length: Int32): JObject {
    return jniObject(env,{ j => j.node(snapshotStore.instanceDiff(unsignedLong(base),unsignedLong(target),unsignedLong(id),Int64(start),Int64(length),reference==0,reference!=0),false,true) })
}

@C
public func Java_com_cjprof_jni_Cjprof_querySnapshotComparison(env: JEnv, cls: JObject, base: Int64, target: Int64): JObject {
    return jniObject(env,{ j => j.nodes(snapshotStore.compare(unsignedLong(base),unsignedLong(target)),true,true) })
}

@C
public func Java_com_cjprof_jni_Cjprof_getNodeRootpaths(env: JEnv, cls: JObject, snapshot: Int64, id: Int64, count: Int32): JObject {
    return jniObject(env,{ j => let out=j.list(); for(path in (snapshotStore.snapshots.get(unsignedLong(snapshot))?.paths(unsignedLong(id),Int64(count)) ?? ArrayList<ArrayList<ApiNode>>())){let list=j.nodes(path,false,false); j.add(out,list); j.drop(list)}; out })
}

@C
public func Java_com_cjprof_jni_Cjprof_getThreadInfos(env: JEnv, cls: JObject, snapshot: Int64): JObject {
    return jniObject(env,{ j => if(let Some(s)<-snapshotStore.snapshots.get(unsignedLong(snapshot))){j.threads(s)}else{j.list()} })
}

@C
public func Java_com_cjprof_jni_Cjprof_querySnapshotCountOfResults(env: JEnv, cls: JObject, keyword: JObject, ignoreCase: UInt8, snapshot: Int64): Int32 {
    let result: Array<Int32> = [0]; jniObject(env,{ j => result[0]=javaInt(snapshotStore.count(j.text(keyword),ignoreCase!=0,unsignedLong(snapshot))); JObject() }); return result[0]
}

@C
public func Java_com_cjprof_jni_Cjprof_querySnapshotNodeByIndex(env: JEnv, cls: JObject, keyword: JObject, ignoreCase: UInt8, snapshot: Int64, length: Int32, index: Int32): JObject {
    return jniObject(env,{ j => j.node(snapshotStore.query(j.text(keyword),ignoreCase!=0,unsignedLong(snapshot),Int64(length),Int64(index)),true,false) })
}

@C
public func Java_com_cjprof_jni_Cjprof_queryComparisonCountOfResults(env: JEnv, cls: JObject, keyword: JObject, ignoreCase: UInt8, base: Int64, target: Int64): Int32 {
    let result: Array<Int32> = [0]; jniObject(env,{ j => result[0]=javaInt(snapshotStore.compareCount(j.text(keyword),ignoreCase!=0,unsignedLong(base),unsignedLong(target))); JObject() }); return result[0]
}

@C
public func Java_com_cjprof_jni_Cjprof_queryComparisonNodeByIndex(env: JEnv, cls: JObject, keyword: JObject, ignoreCase: UInt8, base: Int64, target: Int64, length: Int32, index: Int32): JObject {
    return jniObject(env,{ j => j.node(snapshotStore.compareQuery(j.text(keyword),ignoreCase!=0,unsignedLong(base),unsignedLong(target),Int64(length),Int64(index)),true,true) })
}
