#!/usr/bin/env zx
// Product tests run an independently installed executable. No AST mocks.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
const {values:v}=parseArgs({options:{prefix:{type:'string'},work:{type:'string'},case:{type:'string'},rules:{type:'string'},'import-path':{type:'string'},'keep-going':{type:'boolean'},'cli-only':{type:'boolean'}}});
for(const key of ['prefix','work'])assert.ok(v[key],`--${key} required`);
const prefix=path.resolve(v.prefix),work=path.resolve(v.work),exe=path.join(prefix,'bin/cjlint');
fs.mkdirSync(work,{recursive:false});
const commands=[],assertions=[];
const env={...process.env};
for(const key of ['CANGJIE_HOME','CANGJIE_PATH','LD_LIBRARY_PATH','LD_PRELOAD','LD_AUDIT'])delete env[key];
function run(name,args){
  const r=spawnSync(exe,args,{cwd:work,env,encoding:'utf8',maxBuffer:1024*1024});
  fs.writeFileSync(path.join(work,name+'.stdout'),r.stdout??'');
  fs.writeFileSync(path.join(work,name+'.stderr'),r.stderr??'');
  commands.push({name,argv:[exe,...args],cwd:work,rc:r.status,signal:r.signal,error:r.error?.message??null});
  fs.writeFileSync(path.join(work,'commands.json'),JSON.stringify(commands,null,2)+'\n');
  return r;
}
function check(name,fn){
  try{fn();assertions.push({name,pass:true});}
  catch(e){assertions.push({name,pass:false,error:e.message});if(!v['keep-going'])throw e;}
  finally{fs.writeFileSync(path.join(work,'assertions.json'),JSON.stringify(assertions,null,2)+'\n');}
}
const cases=[
 {"name": "subpackage-import-positive", "rule": "G.VAR.01", "source": "package example\nimport example.inner.read\nfunc api(): Int64 { read() }\n", "files": {"inner/value.cj": "package example.inner\nvar value = 1\npublic func read(): Int64 { value }\n"}, "reportFile": "inner/value.cj", "kinds": ["G_VAR_01_prefer_immutable_var"]},
 {"name": "subpackage-import-control", "rule": "G.VAR.01", "source": "package example\nimport example.inner.read\nfunc api(): Int64 { read() }\n", "files": {"inner/value.cj": "package example.inner\npublic func read(): Int64 { 1 }\n"}, "reportFile": "inner/value.cj", "kinds": []},

 {"name": "spawn-mutex-capture-different-positive", "rule": "P.02", "source": "import std.sync.ReentrantMutex\nclass Box { var value = 0 }\nfunc api(): Unit { let box = Box()\n let first = ReentrantMutex()\n let second = ReentrantMutex()\n let task = spawn { synchronized(first) { box.value = 1 } }\n let other = spawn { synchronized(second) { box.value = 2 } } }\n", "kinds": ["P_02_diff_mutex"]},
 {"name": "spawn-mutex-capture-same-control", "rule": "P.02", "source": "import std.sync.ReentrantMutex\nclass Box { var value = 0 }\nfunc api(): Unit { let box = Box()\n let first = ReentrantMutex()\n let second = ReentrantMutex()\n let task = spawn { synchronized(first) { box.value = 1 } }\n let other = spawn { synchronized(first) { box.value = 2 } } }\n", "kinds": []},
 {"name": "spawn-mutex-capture-unlocked-positive", "rule": "P.02", "source": "class Box { var value = 0 }\nfunc api(): Unit { let box = Box()\n let task = spawn { box.value = 1 } }\n", "kinds": ["P_02_no_mutex"]},
 {"name": "immutable-captured-write-control", "rule": "G.VAR.01", "source": "func api(): Int64 { var value = 1\n let task = { => value = 2 }\n task()\n value }\n", "kinds": []},
 {"name": "immutable-captured-read-positive", "rule": "G.VAR.01", "source": "func api(): Int64 { var value = 1\n let task = { => value }\n task() }\n", "kinds": ["G_VAR_01_prefer_immutable_var"]},
 {"name": "immutable-property-positive", "rule": "G.VAR.01", "source": "class Box { mut prop number: Int64 { get() { 1 } set(value) {} } }\n", "kinds": ["G_VAR_01_prefer_immutable_prop"]},
 {"name": "immutable-property-control", "rule": "G.VAR.01", "source": "class Box { mut prop number: Int64 { get() { 1 } set(value) {} } }\nfunc api(box: Box): Unit { box.number = 2 }\n", "kinds": []},
 {"name": "immutable-generic-static-positive", "rule": "G.VAR.01", "source": "class Box<T> { static var count: Int64 = 0 }\nfunc api(): Int64 { Box<Int64>.count }\n", "kinds": ["G_VAR_01_prefer_immutable_var"]},
 {"name": "immutable-generic-static-control", "rule": "G.VAR.01", "source": "class Box<T> { static var count: Int64 = 0 }\nfunc api(): Unit { Box<Int64>.count = 1 }\n", "kinds": []},

 {"name": "spawn-mutex-global-positive", "rule": "P.02", "source": "var shared = 0\nfunc api(): Unit { let task = spawn { shared = 1 } }\n", "kinds": ["P_02_no_mutex"]},
 {"name": "spawn-mutex-read-control", "rule": "P.02", "source": "var shared = 0\nfunc api(): Unit { let task = spawn { println(shared) } }\n", "kinds": []},
 {"name": "spawn-mutex-local-control", "rule": "P.02", "source": "func api(): Unit { let task = spawn { var value = 0\n value = 1 } }\n", "kinds": []},
 {"name": "spawn-mutex-same-control", "rule": "P.02", "source": "import std.sync.ReentrantMutex\nlet first = ReentrantMutex()\nlet second = ReentrantMutex()\nvar shared = 0\nfunc api(): Unit { let task = spawn { synchronized(first) { shared = 1 } }\n let other = spawn { synchronized(first) { shared = 2 } } }\n", "kinds": []},
 {"name": "spawn-mutex-different-positive", "rule": "P.02", "source": "import std.sync.ReentrantMutex\nlet first = ReentrantMutex()\nlet second = ReentrantMutex()\nvar shared = 0\nfunc api(): Unit { let task = spawn { synchronized(first) { shared = 1 } }\n let other = spawn { synchronized(second) { shared = 2 } } }\n", "kinds": ["P_02_diff_mutex"]},
 {"name": "spawn-mutex-branch-positive", "rule": "P.02", "source": "import std.sync.ReentrantMutex\nlet first = ReentrantMutex()\nlet second = ReentrantMutex()\nvar shared = 0\nfunc api(flag: Bool): Unit { let task = spawn { if (flag) { synchronized(first) { shared = 1 } } else { shared = 2 } } }\n", "kinds": ["P_02_no_mutex"]},
 {"name": "spawn-mutex-member-positive", "rule": "P.02", "source": "class Box { var value = 0 }\nlet box = Box()\nfunc api(): Unit { let task = spawn { box.value = 1 } }\n", "kinds": ["P_02_no_mutex"]},
 {"name": "spawn-mutex-outside-control", "rule": "P.02", "source": "var shared = 0\nfunc api(): Unit { shared = 1 }\n", "kinds": []},

 {"name": "serial-flow-type-positive", "rule": "G.SER.03", "dependencies": true, "source": "import stdx.serialization.serialization.*\nclass Box <: Serializable<Box> {\n let value: Int64\n init(v: Int64) { value = v }\n public func serialize(): DataModel { DataModelStruct().add(Field(\"value\", value.serialize())) }\n public static func deserialize(dm: DataModel): Box { let text = String.deserialize((dm as DataModelStruct).getOrThrow().get(\"value\"))\n Box(0) }\n}\n", "kinds": ["G_SER_03_type_error"]},
 {"name": "serial-flow-control", "rule": "G.SER.03", "dependencies": true, "source": "import stdx.serialization.serialization.*\nclass Box <: Serializable<Box> {\n let value: Int64\n init(v: Int64) { value = v }\n public func serialize(): DataModel { DataModelStruct().add(Field(\"value\", value.serialize())) }\n public static func deserialize(dm: DataModel): Box { Box(Int64.deserialize((dm as DataModelStruct).getOrThrow().get(\"value\"))) }\n}\n", "kinds": []},
 {"name": "serial-flow-key-positive", "rule": "G.SER.03", "dependencies": true, "source": "import stdx.serialization.serialization.*\nclass Box <: Serializable<Box> {\n let value: Int64\n init(v: Int64) { value = v }\n public func serialize(): DataModel { DataModelStruct().add(Field(\"value\", value.serialize())) }\n public static func deserialize(dm: DataModel): Box { Box(Int64.deserialize((dm as DataModelStruct).getOrThrow().get(\"missing\"))) }\n}\n", "kinds": ["G_SER_03_key_lack"]},
 {"name": "serial-flow-direct-type-positive", "rule": "G.SER.03", "dependencies": true, "source": "import stdx.serialization.serialization.*\nclass Box <: Serializable<Box> {\n let value: Int64\n init(v: Int64) { value = v }\n public func serialize(): DataModel { value.serialize() }\n public static func deserialize(dm: DataModel): Box { let text = String.deserialize(dm)\n Box(0) }\n}\n", "kinds": ["G_SER_03_type_lack"]},
 {"name": "serial-flow-direct-control", "rule": "G.SER.03", "dependencies": true, "source": "import stdx.serialization.serialization.*\nclass Box <: Serializable<Box> {\n let value: Int64\n init(v: Int64) { value = v }\n public func serialize(): DataModel { value.serialize() }\n public static func deserialize(dm: DataModel): Box { Box(Int64.deserialize(dm)) }\n}\n", "kinds": []},
 {"name": "serial-flow-return-positive", "rule": "G.SER.03", "dependencies": true, "source": "import stdx.serialization.serialization.*\nclass Box <: Serializable<Box> {\n let value: Int64\n init(v: Int64) { value = v }\n public func serialize(): DataModel { value.serialize() }\n public static func deserialize(dm: DataModel): Box { Box(Int64.deserialize((dm as DataModelStruct).getOrThrow().get(\"value\"))) }\n}\n", "kinds": ["G_SER_03_return_error"]},

 {"name": "immutable-local-positive", "rule": "G.VAR.01", "source": "func api(): Int64 { var value = 1\n value }\n", "kinds": ["G_VAR_01_prefer_immutable_var"]},
 {"name": "immutable-local-control", "rule": "G.VAR.01", "source": "func api(): Int64 { var value = 1\n value++\n value }\n", "kinds": []},
 {"name": "immutable-let-control", "rule": "G.VAR.01", "source": "func api(): Int64 { let value = 1\n value }\n", "kinds": []},
 {"name": "immutable-global-positive", "rule": "G.VAR.01", "source": "var value = 1\nfunc api(): Int64 { value }\n", "kinds": ["G_VAR_01_prefer_immutable_var"]},
 {"name": "immutable-global-control", "rule": "G.VAR.01", "source": "var value = 1\nfunc api(): Unit { value = 2 }\n", "kinds": []},
 {"name": "immutable-public-control", "rule": "G.VAR.01", "source": "public var value: Int64 = 1\n", "kinds": []},
 {"name": "immutable-member-positive", "rule": "G.VAR.01", "source": "class Box { var value = 1 }\nfunc api(box: Box): Int64 { box.value }\n", "kinds": ["G_VAR_01_prefer_immutable_member"]},
 {"name": "immutable-member-control", "rule": "G.VAR.01", "source": "class Box { var value = 1 }\nfunc api(box: Box): Unit { box.value = 2 }\n", "kinds": []},
 {"name": "immutable-unsafe-control", "rule": "G.VAR.01", "source": "func api(): Int64 { unsafe { var value = 1\n return value } }\n", "kinds": []},
 {"name": "immutable-lambda-positive", "rule": "G.VAR.01", "source": "func api(): Int64 { let task = { => var value = 1\n value }; task() }\n", "kinds": ["G_VAR_01_prefer_immutable_var"]},
 {"name": "immutable-nested-member-control", "rule": "G.VAR.01", "source": "struct Box { var value = 1 }\nfunc api(): Int64 { var box = Box()\n box.value = 2\n box.value }\n", "kinds": []},

 {"name": "sensitive-log-positive", "rule": "G.OTH.01", "source": "import stdx.log.*\nfunc api(log: Logger): Unit { log.info(\"password\", []) }\n", "dependencies": true, "kinds": ["G_OTH_01_log_sensitive_information"]},
 {"name": "sensitive-log-control", "rule": "G.OTH.01", "source": "import stdx.log.*\nfunc api(log: Logger): Unit { log.info(\"ordinary\", []) }\n", "dependencies": true, "kinds": []},
 {"name": "sensitive-log-concat-positive", "rule": "G.OTH.01", "source": "import stdx.log.*\nfunc api(log: Logger): Unit { let message = \"pass\" + \"word\"\n log.info(message, []) }\n", "dependencies": true, "kinds": ["G_OTH_01_log_sensitive_information"]},
 {"name": "sensitive-log-off-control", "rule": "G.OTH.01", "source": "import stdx.log.*\nfunc api(log: Logger): Unit { log.log(LogLevel.OFF, \"password\", []) }\n", "dependencies": true, "kinds": []},
 {"name": "sensitive-log-level-positive", "rule": "G.OTH.01", "source": "import stdx.log.*\nfunc api(log: Logger): Unit { log.log(LogLevel.INFO, \"password\", []) }\n", "dependencies": true, "kinds": ["G_OTH_01_log_sensitive_information"]},

 {"name": "taint-concat-positive", "rule": "G.CHK.01", "source": "import std.posix.gethostname\nfunc api(): String { let value = gethostname()\n value + \"suffix\" }\n", "kinds": ["G_CHK_01_illegal_return"]},
 {"name": "taint-return-positive", "rule": "G.CHK.01", "source": "import std.posix.gethostname\nfunc api(): String { gethostname() }\n", "kinds": ["G_CHK_01_illegal_return"]},
 {"name": "taint-return-control", "rule": "G.CHK.01", "source": "func api(): String { \"local\" }\n", "kinds": []},
 {"name": "taint-argument-positive", "rule": "G.CHK.01", "source": "import std.posix.gethostname\nfunc consume(value: String): Unit {}\nfunc api(): Unit { consume(gethostname()) }\n", "kinds": ["G_CHK_01_illegal_func_arg"]},
 {"name": "taint-argument-control", "rule": "G.CHK.01", "source": "func consume(value: String): Unit {}\nfunc api(): Unit { consume(\"local\") }\n", "kinds": []},
 {"name": "taint-alias-positive", "rule": "G.CHK.01", "source": "import std.posix.gethostname\nfunc consume(value: String): Unit {}\nfunc api(): Unit { let value = gethostname()\n consume(value) }\n", "kinds": ["G_CHK_01_illegal_func_arg"]},
 {"name": "taint-guard-control", "rule": "G.CHK.01", "source": "import std.posix.gethostname\nfunc consume(value: String): Unit {}\nfunc api(): Unit { let value = gethostname()\n if (value.isEmpty()) { return }\n consume(value) }\n", "kinds": []},

 {"name": "path-verify-positive", "rule": "G.CHK.03", "source": "package example\nimport std.fs.Path\nfunc external(): Path { Path(\"input\") }\nfunc canonical(path: Path): Path { path }\nfunc verify(path: Path): Unit {}\nfunc consume(path: Path): Unit {}\nfunc api(path: Path): Unit { let local = path\n consume(local) }\nfunc caller(): Unit { let path = external()\n api(path) }\n", "config": {"dataflow_rule_G_CHK_03.json": {"ExternalDateFunc": [{"name": "external", "parent": "", "lib": "example"}], "CanonicalizeFunc": [{"name": "canonical", "parent": "", "lib": "example"}], "VerifyFunc": [{"name": "verify", "parent": "", "lib": "example"}]}}, "kinds": ["G_CHK_03_without_verify"]},
 {"name": "path-canonical-positive", "rule": "G.CHK.03", "source": "package example\nimport std.fs.Path\nfunc external(): Path { Path(\"input\") }\nfunc canonical(path: Path): Path { path }\nfunc verify(path: Path): Unit {}\nfunc consume(path: Path): Unit {}\nfunc api(path: Path): Unit { let local = path\n verify(local)\n consume(local) }\nfunc caller(): Unit { let path = external()\n api(path) }\n", "config": {"dataflow_rule_G_CHK_03.json": {"ExternalDateFunc": [{"name": "external", "parent": "", "lib": "example"}], "CanonicalizeFunc": [{"name": "canonical", "parent": "", "lib": "example"}], "VerifyFunc": [{"name": "verify", "parent": "", "lib": "example"}]}}, "kinds": ["G_CHK_03_without_canonicalize"]},
 {"name": "path-validated-control", "rule": "G.CHK.03", "source": "package example\nimport std.fs.Path\nfunc external(): Path { Path(\"input\") }\nfunc canonical(path: Path): Path { path }\nfunc verify(path: Path): Unit {}\nfunc consume(path: Path): Unit {}\nfunc api(path: Path): Unit { let local = canonical(path)\n verify(local)\n consume(local) }\nfunc caller(): Unit { let path = external()\n api(path) }\n", "config": {"dataflow_rule_G_CHK_03.json": {"ExternalDateFunc": [{"name": "external", "parent": "", "lib": "example"}], "CanonicalizeFunc": [{"name": "canonical", "parent": "", "lib": "example"}], "VerifyFunc": [{"name": "verify", "parent": "", "lib": "example"}]}}, "kinds": []},
 {"name": "path-no-external-control", "rule": "G.CHK.03", "source": "package example\nimport std.fs.Path\nfunc external(): Path { Path(\"input\") }\nfunc canonical(path: Path): Path { path }\nfunc verify(path: Path): Unit {}\nfunc consume(path: Path): Unit {}\nfunc api(path: Path): Unit { let local = path\n consume(local) }\n", "config": {"dataflow_rule_G_CHK_03.json": {"ExternalDateFunc": [{"name": "external", "parent": "", "lib": "example"}], "CanonicalizeFunc": [{"name": "canonical", "parent": "", "lib": "example"}], "VerifyFunc": [{"name": "verify", "parent": "", "lib": "example"}]}}, "kinds": []},

 {"name": "temp-file-positive", "rule": "G.FIO.01", "source": "import std.fs.*\nfunc api(): Unit { let file = File(\"/tmp/cjlint-data\", OpenMode.ReadWrite) }\n", "kinds": ["G_FIO_01"]},
 {"name": "temp-file-control", "rule": "G.FIO.01", "source": "import std.fs.*\nfunc api(): Unit { let file = File(\"/tmp/cjlint-data\", OpenMode.ReadWrite)\n remove(\"/tmp/cjlint-data\") }\n", "kinds": []},
 {"name": "temp-normal-control", "rule": "G.FIO.01", "source": "import std.fs.*\nfunc api(): Unit { let file = File(\"/data/cjlint-data\", OpenMode.ReadWrite) }\n", "kinds": []},
 {"name": "temp-branch-positive", "rule": "G.FIO.01", "source": "import std.fs.*\nfunc api(flag: Bool): Unit { let file = File(\"/tmp/cjlint-data\", OpenMode.ReadWrite)\n if (flag) { remove(\"/tmp/cjlint-data\") } }\n", "kinds": ["G_FIO_01"]},
 {"name": "temp-branches-control", "rule": "G.FIO.01", "source": "import std.fs.*\nfunc api(flag: Bool): Unit { let file = File(\"/tmp/cjlint-data\", OpenMode.ReadWrite)\n if (flag) { remove(\"/tmp/cjlint-data\") } else { remove(\"/tmp/cjlint-data\") } }\n", "kinds": []},

 {"name": "log-external-positive", "rule": "G.CHK.02", "source": "package example\nclass Logger { public func info(text: String): Unit {} }\nfunc input(): String { \"external\" }\nfunc api(log: Logger): Unit { log.info(input()) }\n", "config": {"structural_rule_G_CHK_02.json": {"ExternalDateFunc": [{"name": "input", "parent": "", "lib": "example"}], "ExternalDateFuncPassToVar": [{"name": "fill", "parent": "Reader", "lib": "example"}]}}, "kinds": ["G_CHK_02_external_data_record_logs"]},
 {"name": "log-alias-positive", "rule": "G.CHK.02", "source": "package example\nclass Logger { public func info(text: String): Unit {} }\nfunc input(): String { \"external\" }\nfunc api(log: Logger): Unit { let data = input()\n log.info(data) }\n", "config": {"structural_rule_G_CHK_02.json": {"ExternalDateFunc": [{"name": "input", "parent": "", "lib": "example"}], "ExternalDateFuncPassToVar": [{"name": "fill", "parent": "Reader", "lib": "example"}]}}, "kinds": ["G_CHK_02_external_data_record_logs"]},
 {"name": "log-literal-control", "rule": "G.CHK.02", "source": "package example\nclass Logger { public func info(text: String): Unit {} }\nfunc input(): String { \"external\" }\nfunc api(log: Logger): Unit { log.info(\"literal\") }\n", "config": {"structural_rule_G_CHK_02.json": {"ExternalDateFunc": [{"name": "input", "parent": "", "lib": "example"}], "ExternalDateFuncPassToVar": [{"name": "fill", "parent": "Reader", "lib": "example"}]}}, "kinds": []},
 {"name": "log-purified-control", "rule": "G.CHK.02", "source": "package example\nclass Logger { public func info(text: String): Unit {} }\nfunc input(): String { \"external\" }\nfunc api(log: Logger): Unit { var data = input()\n data = \"safe\"\n log.info(data) }\n", "config": {"structural_rule_G_CHK_02.json": {"ExternalDateFunc": [{"name": "input", "parent": "", "lib": "example"}], "ExternalDateFuncPassToVar": [{"name": "fill", "parent": "Reader", "lib": "example"}]}}, "kinds": []},
 {"name": "log-retainted-positive", "rule": "G.CHK.02", "source": "package example\nclass Logger { public func info(text: String): Unit {} }\nfunc input(): String { \"external\" }\nfunc api(log: Logger): Unit { var data = input()\n data = \"safe\"\n data = input()\n log.info(data) }\n", "config": {"structural_rule_G_CHK_02.json": {"ExternalDateFunc": [{"name": "input", "parent": "", "lib": "example"}], "ExternalDateFuncPassToVar": [{"name": "fill", "parent": "Reader", "lib": "example"}]}}, "kinds": ["G_CHK_02_external_data_record_logs"]},
 {"name": "log-other-control", "rule": "G.CHK.02", "source": "package example\nclass Logger { public func info(text: String): Unit {} }\nfunc input(): String { \"external\" }\nclass Other { public func info(text: String): Unit {} }\nfunc api(log: Other): Unit { log.info(input()) }\n", "config": {"structural_rule_G_CHK_02.json": {"ExternalDateFunc": [{"name": "input", "parent": "", "lib": "example"}], "ExternalDateFuncPassToVar": [{"name": "fill", "parent": "Reader", "lib": "example"}]}}, "kinds": []},
 {"name": "log-after-control", "rule": "G.CHK.02", "source": "package example\nclass Logger { public func info(text: String): Unit {} }\nfunc input(): String { \"external\" }\nfunc api(log: Logger): Unit { var data = \"safe\"\n log.info(data)\n data = input() }\n", "config": {"structural_rule_G_CHK_02.json": {"ExternalDateFunc": [{"name": "input", "parent": "", "lib": "example"}], "ExternalDateFuncPassToVar": [{"name": "fill", "parent": "Reader", "lib": "example"}]}}, "kinds": []},
 {"name": "log-output-positive", "rule": "G.CHK.02", "source": "package example\nclass Logger { public func info(text: String): Unit {} }\nfunc input(): String { \"external\" }\nclass Reader { public func fill(data: Array<UInt8>): Unit {} }\nfunc api(log: Logger, reader: Reader): Unit { let data = Array<UInt8>(8, repeat: 0)\n reader.fill(data)\n log.info(data.toString()) }\n", "config": {"structural_rule_G_CHK_02.json": {"ExternalDateFunc": [{"name": "input", "parent": "", "lib": "example"}], "ExternalDateFuncPassToVar": [{"name": "fill", "parent": "Reader", "lib": "example"}]}}, "kinds": ["G_CHK_02_external_data_record_logs"]},

 {"name": "lock-cross-file-positive", "rule": "P.01", "source": "package example\nimport std.sync.ReentrantMutex\nlet first = ReentrantMutex()\nlet second = ReentrantMutex()\n\n\n\n\nfunc two(): Unit { synchronized(second) { synchronized(first) {} } }\n", "files": {"other.cj": "package example\nfunc one(): Unit { synchronized(first) { synchronized(second) {} } }\n"}, "kinds": ["P_01_dead_lock"]},
 {"name": "lock-order-positive", "rule": "P.01", "source": "package example\nimport std.sync.ReentrantMutex\nlet first = ReentrantMutex()\nlet second = ReentrantMutex()\nfunc one(): Unit { synchronized(first) { synchronized(second) {} } }\nfunc two(): Unit { synchronized(second) { synchronized(first) {} } }\n", "kinds": ["P_01_dead_lock"]},
 {"name": "lock-order-control", "rule": "P.01", "source": "package example\nimport std.sync.ReentrantMutex\nlet first = ReentrantMutex()\nlet second = ReentrantMutex()\nfunc one(): Unit { synchronized(first) { synchronized(second) {} } }\nfunc two(): Unit { synchronized(first) { synchronized(second) {} } }\n", "kinds": []},
 {"name": "lock-single-control", "rule": "P.01", "source": "package example\nimport std.sync.ReentrantMutex\nlet first = ReentrantMutex()\nlet second = ReentrantMutex()\nfunc one(): Unit { synchronized(first) {} }\nfunc two(): Unit { synchronized(second) {} }\n", "kinds": []},
 {"name": "lock-lambda-positive", "rule": "P.01", "source": "package example\nimport std.sync.ReentrantMutex\nlet first = ReentrantMutex()\nlet second = ReentrantMutex()\nfunc one(): Unit { synchronized(first) { synchronized(second) {} } }\nfunc two(): Unit { let action = { => synchronized(second) { synchronized(first) {} } } }\n", "kinds": ["P_01_dead_lock"]},

 {"name": "short-global-positive", "rule": "G.EXP.03", "source": "var state: Bool = false\nfunc update(): Bool { state = true\n state }\nfunc api(flag: Bool): Bool { flag && update() }\n", "kinds": ["G_EXP_03_side_effect_information"]},
 {"name": "short-pure-control", "rule": "G.EXP.03", "source": "func pure(): Bool { true }\nfunc api(flag: Bool): Bool { flag && pure() }\n", "kinds": []},
 {"name": "short-or-positive", "rule": "G.EXP.03", "source": "var state: Bool = false\nfunc update(): Bool { state = true\n state }\nfunc api(flag: Bool): Bool { flag || update() }\n", "kinds": ["G_EXP_03_side_effect_information"]},
 {"name": "short-left-control", "rule": "G.EXP.03", "source": "var state: Bool = false\nfunc update(): Bool { state = true\n state }\nfunc api(flag: Bool): Bool { update() && flag }\n", "kinds": []},
 {"name": "short-helper-positive", "rule": "G.EXP.03", "source": "var state: Bool = false\nfunc update(): Bool { state = true\n state }\nfunc helper(): Bool { update() }\nfunc api(flag: Bool): Bool { flag && helper() }\n", "kinds": ["G_EXP_03_side_effect_information"]},
 {"name": "short-recursive-control", "rule": "G.EXP.03", "source": "func loop(): Bool { loop() }\nfunc api(flag: Bool): Bool { flag && loop() }\n", "kinds": []},

 {"name": "regex-dynamic-positive", "rule": "G.CHK.04", "source": "import std.regex.Regex\nfunc api(pattern: String): Unit { let regex = Regex(pattern) }\n", "kinds": ["G_CHK_04_untrusted_regular_expressions_dynamical_regex"]},
 {"name": "regex-literal-control", "rule": "G.CHK.04", "source": "import std.regex.Regex\nfunc api(): Unit { let regex = Regex(\"abc\") }\n", "kinds": []},
 {"name": "regex-nested-positive", "rule": "G.CHK.04", "source": "import std.regex.Regex\nfunc api(): Unit { let regex = Regex(\"(a+)+\") }\n", "kinds": ["G_CHK_04_untrusted_regular_expressions_itselfRepeated"]},
 {"name": "regex-group-positive", "rule": "G.CHK.04", "source": "import std.regex.Regex\nfunc api(): Unit { let regex = Regex(\"([a-z])\") }\n", "kinds": ["G_CHK_04_untrusted_regular_expressions_redundantGroup"]},
 {"name": "regex-overlap-positive", "rule": "G.CHK.04", "source": "import std.regex.Regex\nfunc api(): Unit { let regex = Regex(\"(a|aa)+\") }\n", "kinds": ["G_CHK_04_untrusted_regular_expressions_subexpressionsOverlap"]},
 {"name": "regex-alias-positive", "rule": "G.CHK.04", "source": "import std.regex.Regex\nfunc api(pattern: String): Unit { let alias = pattern\n let regex = Regex(alias) }\n", "kinds": ["G_CHK_04_untrusted_regular_expressions_dynamical_regex"]},

 {"name": "defensive-direct-positive", "rule": "P.03", "source": "package example\nopen class Data { public open func value(): Int64 { 1 } }\nfunc securityCheck(value: Int64): Unit {}\nfunc api(data: Data): Unit { securityCheck(data.value()) }\n", "kinds": ["P_03_func_could_be_overridden"]},
 {"name": "defensive-local-positive", "rule": "P.03", "source": "package example\nopen class Data { public open func value(): Int64 { 1 } }\nfunc securityCheck(value: Int64): Unit {}\nfunc api(data: Data): Unit { let value = data.value()\n securityCheck(value) }\n", "kinds": ["P_03_func_could_be_overridden"]},
 {"name": "defensive-copy-control", "rule": "P.03", "source": "package example\nopen class Data { public open func value(): Int64 { 1 } }\nfunc securityCheck(value: Int64): Unit {}\nfunc api(): Unit { let data = Data()\n securityCheck(data.value()) }\n", "kinds": []},
 {"name": "defensive-function-control", "rule": "P.03", "source": "package example\nopen class Data { public open func value(): Int64 { 1 } }\nfunc securityCheck(value: Int64): Unit {}\nfunc check(value: Int64): Unit {}\nfunc api(data: Data): Unit { check(data.value()) }\n", "kinds": []},

 {"name": "lock-finally-positive", "rule": "G.CON.02", "source": "import std.sync.ReentrantMutex\nfunc api(): Unit { let lock = ReentrantMutex()\n try { lock.lock() } finally {} }\n", "kinds": ["G_CON_02_lock"]},
 {"name": "lock-finally-control", "rule": "G.CON.02", "source": "import std.sync.ReentrantMutex\nfunc api(): Unit { let lock = ReentrantMutex()\n try { lock.lock() } finally { lock.unlock() } }\n", "kinds": []},
 {"name": "lock-outside-control", "rule": "G.CON.02", "source": "import std.sync.ReentrantMutex\nfunc api(): Unit { let lock = ReentrantMutex()\n lock.lock()\n try {} finally { lock.unlock() } }\n", "kinds": []},
 {"name": "lock-wrong-release-positive", "rule": "G.CON.02", "source": "import std.sync.ReentrantMutex\nfunc api(): Unit { let lock = ReentrantMutex()\n let other = ReentrantMutex()\n try { lock.lock() } finally { other.unlock() } }\n", "kinds": ["G_CON_02_lock"]},
 {"name": "thread-override-positive", "rule": "G.CON.03", "source": "var shared: Int64 = 0\nopen class Parent { public open func act(): Unit {} }\nclass Child <: Parent { public override func act(): Unit { shared = 1 } }\n", "kinds": ["G_CON_03_override_func_thread_safe"]},
 {"name": "thread-override-control", "rule": "G.CON.03", "source": "var shared: Int64 = 0\nopen class Parent { public open func act(): Unit {} }\nclass Child <: Parent { public override func act(): Unit { let local = 1 } }\n", "kinds": []},
 {"name": "thread-parent-unsafe-control", "rule": "G.CON.03", "source": "var shared: Int64 = 0\nopen class Parent { public open func act(): Unit { shared = 1 } }\nclass Child <: Parent { public override func act(): Unit { shared = 2 } }\n", "kinds": []},
 {"name": "thread-helper-positive", "rule": "G.CON.03", "source": "var shared: Int64 = 0\nopen class Parent { public open func act(): Unit {} }\nfunc update(): Unit { shared = 1 }\nclass Child <: Parent { public override func act(): Unit { update() } }\n", "kinds": ["G_CON_03_override_func_thread_safe"]},

 {"name": "shadow-global-positive", "rule": "G.DCL.01", "source": "let value = 1\nfunc api(): Unit { let value = 2 }\n", "kinds": ["G_DCL_01_avoid_shadow"]},
 {"name": "shadow-global-control", "rule": "G.DCL.01", "source": "let value = 1\nfunc api(): Unit { let other = 2 }\n", "kinds": []},
 {"name": "shadow-function-positive", "rule": "G.DCL.01", "source": "func act(value: Int64): Unit {}\nfunc api(): Unit { func act(value: Int64): Unit {} }\n", "kinds": ["G_DCL_01_avoid_shadow"]},
 {"name": "shadow-overload-control", "rule": "G.DCL.01", "source": "func act(value: Int64): Unit {}\nfunc api(): Unit { func act(value: Bool): Unit {} }\n", "kinds": []},
 {"name": "shadow-sibling-control", "rule": "G.DCL.01", "source": "func api(): Unit { let value = 1 }\nfunc next(): Unit { let value = 2 }\n", "kinds": []},
 {"name": "shadow-generic-positive", "rule": "G.DCL.01", "source": "class Item<T> { public func act<T>(value: T): Unit {} }\n", "kinds": ["G_DCL_01_avoid_shadow"]},

 {"name": "float-compare-positive", "rule": "G.EXP.02", "source": "func api(a: Float64, b: Float64): Bool { a == b }\n", "kinds": ["G_EXP_02_not_accurate_float_operation_02"]},
 {"name": "float-compare-control", "rule": "G.EXP.02", "source": "func api(a: Int64, b: Int64): Bool { a == b }\n", "kinds": []},
 {"name": "float-order-control", "rule": "G.EXP.02", "source": "func api(a: Float64, b: Float64): Bool { a < b }\n", "kinds": []},
 {"name": "float-half-positive", "rule": "G.EXP.02", "source": "let value: Float16 = 1.234\n", "kinds": ["G_EXP_02_not_accurate_float_operation_01"]},
 {"name": "float-half-control", "rule": "G.EXP.02", "source": "let value: Float16 = 1.5\n", "kinds": []},
 {"name": "float-digits-positive", "rule": "G.EXP.02", "source": "let value: Float32 = 1.23456789\n", "kinds": ["G_EXP_02_not_accurate_float_operation_01"]},
 {"name": "float-digits-control", "rule": "G.EXP.02", "source": "let value: Float32 = 1.25\n", "kinds": []},
 {"name": "float-double-digits-positive", "rule": "G.EXP.02", "source": "let value: Float64 = 1.23456789012345678\n", "kinds": ["G_EXP_02_not_accurate_float_operation_01"]},

 {"name": "scope-narrow-positive", "rule": "G.VAR.02", "source": "func api(flag: Bool): Unit { let value = 1\n if (flag) { println(value) } }\n", "kinds": ["G_VAR_02_min_scope"]},
 {"name": "scope-direct-control", "rule": "G.VAR.02", "source": "func api(): Unit { let value = 1\n println(value) }\n", "kinds": []},
 {"name": "scope-siblings-control", "rule": "G.VAR.02", "source": "func api(flag: Bool): Unit { let value = 1\n if (flag) { println(value) } else { println(value) } }\n", "kinds": []},
 {"name": "scope-public-control", "rule": "G.VAR.02", "source": "public var VALUE: Int64 = 1\nfunc api(): Unit { println(VALUE) }\n", "kinds": []},
 {"name": "evaluation-order-positive", "rule": "G.EXP.04", "source": "var counter: Int64 = 0\nfunc bump(): Int64 { counter += 1\n return counter }\nfunc use(first!: Int64, second!: Int64): Unit {}\nfunc api(): Unit { use(second: bump(), first: 1) }\n", "kinds": ["G_EXP_04_side_effect_depend_on_order"]},
 {"name": "evaluation-order-control", "rule": "G.EXP.04", "source": "var counter: Int64 = 0\nfunc bump(): Int64 { counter += 1\n return counter }\nfunc use(first!: Int64, second!: Int64): Unit {}\nfunc api(): Unit { use(first: bump(), second: 1) }\n", "kinds": []},
 {"name": "evaluation-pure-control", "rule": "G.EXP.04", "source": "func pure(): Int64 { 1 }\nfunc use(first!: Int64, second!: Int64): Unit {}\nfunc api(): Unit { use(second: pure(), first: 1) }\n", "kinds": []},

 {"name": "syntax-let-positive", "rule": "G.SYN.01", "source": "let value: Int64 = 1\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Let"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-let-control", "rule": "G.SYN.01", "source": "var value: Int64 = 1\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Let"]}}, "kinds": []},
 {"name": "syntax-class-positive", "rule": "G.SYN.01", "source": "class Item {}\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Class"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-class-control", "rule": "G.SYN.01", "source": "struct Item {}\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Class"]}}, "kinds": []},
 {"name": "syntax-struct-positive", "rule": "G.SYN.01", "source": "struct Item {}\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Struct"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-enum-positive", "rule": "G.SYN.01", "source": "enum Choice { One | Two }\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Enum"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-interface-positive", "rule": "G.SYN.01", "source": "interface Action {}\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Interface"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-while-positive", "rule": "G.SYN.01", "source": "func api(): Unit { while (false) {} }\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["While"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-do-while-positive", "rule": "G.SYN.01", "source": "func api(): Unit { do {} while (false) }\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["While"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-type-positive", "rule": "G.SYN.01", "source": "type Number = Int64\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Type"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-main-positive", "rule": "G.SYN.01", "source": "main(): Int64 { 0 }\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Main"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-foreign-positive", "rule": "G.SYN.01", "source": "func api(): Unit { unsafe {} }\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Foreign"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-operator-positive", "rule": "G.SYN.01", "source": "class Item { operator func ()(): Unit {} }\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Operator"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-generic-positive", "rule": "G.SYN.01", "source": "func api<T>(value: T): Unit {}\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Generic"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-higher-positive", "rule": "G.SYN.01", "source": "func api(action: () -> Unit): Unit {}\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["HigherOrderFunc"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-higher-control", "rule": "G.SYN.01", "source": "func api(value: Int64): Unit {}\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["HigherOrderFunc"]}}, "kinds": []},
 {"name": "syntax-try-positive", "rule": "G.SYN.01", "source": "func api(): Unit { try {} catch (_: Exception) {} }\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["TryCatch"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-match-positive", "rule": "G.SYN.01", "source": "func api(value: Int64): Unit { match (value) { case _ => () } }\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["Match"]}}, "kinds": ["G_SYN_01_disable_syntax_information_01"]},
 {"name": "syntax-primitive-positive", "rule": "G.SYN.01", "source": "func api(value: Int32): Unit {}\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["PrimitiveType"]}}, "kinds": ["G_SYN_01_disable_syntax_information_02", "G_SYN_01_disable_syntax_information_02"]},
 {"name": "syntax-primitive-control", "rule": "G.SYN.01", "source": "func api(value: Int64): Unit {}\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["PrimitiveType"]}}, "kinds": []},
 {"name": "syntax-container-positive", "rule": "G.SYN.01", "source": "import std.collection.ArrayList\nlet values = ArrayList<Int64>()\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["ContainerType"]}}, "kinds": ["G_SYN_01_disable_syntax_information_03"]},
 {"name": "syntax-container-control", "rule": "G.SYN.01", "source": "let values = Array<Int64>()\n", "config": {"structural_rule_G_SYN_01.json": {"SyntaxKeyword": ["ContainerType"]}}, "kinds": []},

 {"name": "serialize-data-positive", "rule": "G.SER.01", "source": "extend String { public func serialize(): Unit {} }\nfunc api(): Unit { \"password\".serialize() }\n", "kinds": ["G_SER_01_serialize_sensitive_data"]},
 {"name": "serialize-reference-positive", "rule": "G.SER.01", "source": "extend String { public func serialize(): Unit {} }\nfunc api(): Unit { let secret = \"passwd\"\n secret.serialize() }\n", "kinds": ["G_SER_01_serialize_sensitive_data"]},
 {"name": "serialize-data-control", "rule": "G.SER.01", "source": "extend String { public func serialize(): Unit {} }\nfunc api(): Unit { \"ordinary\".serialize() }\n", "kinds": []},
 {"name": "serialize-config-control", "rule": "G.SER.01", "source": "extend String { public func serialize(): Unit {} }\nfunc api(): Unit { \"password\".serialize() }\n", "kinds": [], "config": {"structural_rule_G_SER_01.json": {"SensitiveKeyword": ["secret"]}}},
 {"name": "serialize-field-positive", "rule": "G.SER.01", "source": "interface Serializable<T> { func serialize(): Unit }\nclass DataModelStruct { public func add(value: Int64): Unit {} }\nfunc field(name: String, value: String): Int64 { 0 }\nclass Record <: Serializable<Record> { public func serialize(): Unit { let data = DataModelStruct()\n data.add(field(\"password\", \"ordinary\")) } }\n", "kinds": ["G_SER_01_serialize_sensitive_field"]},
 {"name": "serialize-field-value-positive", "rule": "G.SER.01", "source": "interface Serializable<T> { func serialize(): Unit }\nclass DataModelStruct { public func add(value: Int64): Unit {} }\nfunc field(name: String, value: String): Int64 { 0 }\nclass Record <: Serializable<Record> { public func serialize(): Unit { let data = DataModelStruct()\n let password = \"ordinary\"\n data.add(field(\"ordinary\", password)) } }\n", "kinds": ["G_SER_01_serialize_sensitive_field"]},
 {"name": "serialize-field-control", "rule": "G.SER.01", "source": "interface Serializable<T> { func serialize(): Unit }\nclass DataModelStruct { public func add(value: Int64): Unit {} }\nfunc field(name: String, value: String): Int64 { 0 }\nclass Record <: Serializable<Record> { public func serialize(): Unit { let data = DataModelStruct()\n data.add(field(\"ordinary\", \"ordinary\")) } }\n", "kinds": []},
 {"name": "deserialize-constructor-positive", "rule": "G.SER.02", "source": "interface Serializable<T> {}\nclass Decoder { public func deserialize(): Int64 { 1 } }\nclass Record <: Serializable<Record> { var value: Int64\n init(input: Decoder) { value = input.deserialize() } }\n", "kinds": ["G_SER_02_Deserialization_Bypass"]},
 {"name": "deserialize-bypass-positive", "rule": "G.SER.02", "source": "interface Serializable<T> {}\nclass Decoder { public func deserialize(): Int64 { 1 } }\nclass Record <: Serializable<Record> { var value: Int64\n init() { value = 1 }\n public func deserialize(input: Decoder): Unit { value = input.deserialize() } }\n", "kinds": ["G_SER_02_Deserialization_Bypass"]},
 {"name": "deserialize-interface-control", "rule": "G.SER.02", "source": "interface Serializable<T> {}\nclass Decoder { public func deserialize(): Int64 { 1 } }\nclass Record { var value: Int64\n init(input: Decoder) { value = input.deserialize() } }\n", "kinds": []},
 {"name": "deserialize-initializer-control", "rule": "G.SER.02", "source": "interface Serializable<T> {}\nclass Decoder { public func deserialize(): Int64 { 1 } }\nclass Record <: Serializable<Record> { var value: Int64 = 1\n public func deserialize(input: Decoder): Unit { value = input.deserialize() } }\n", "kinds": []},

 {name:'class-access-positive',rule:'G.CLS.01',source:'open class Parent { protected open func act(): Unit {} }\nclass Child <: Parent { public override func act(): Unit {} }\n',kinds:['G_CLS_01_increase_the_accessibility_of_the_function_01']},
 {name:'class-access-control',rule:'G.CLS.01',source:'open class Parent { protected open func act(): Unit {} }\nclass Child <: Parent { protected override func act(): Unit {} }\n',kinds:[]},
 {name:'class-wrapper-positive',rule:'G.CLS.01',source:'open class Parent { protected open func act(): Unit {} }\nclass Child <: Parent { public func expose(): Unit { super.act() } }\n',kinds:['G_CLS_01_increase_the_accessibility_of_the_function_02']},
 {name:'class-wrapper-control',rule:'G.CLS.01',source:'open class Parent { protected open func act(): Unit {} }\nclass Child <: Parent { protected func expose(): Unit { super.act() } }\n',kinds:[]},
 {name:'class-overload-control',rule:'G.CLS.01',source:'open class Parent { protected open func act(value: Int64): Unit {} }\nclass Child <: Parent { public func act(value: Bool): Unit {} }\n',kinds:[]},
 {name:'operator-convention-positive',rule:'G.OPR.01',source:'class Value { operator func +(other: Value): Int64 { 1 - 2 } }\n',kinds:['G_OPR_01_avoid_operator_overloading_that_violates_conventions_02']},
 {name:'operator-convention-control',rule:'G.OPR.01',source:'class Value { operator func +(other: Value): Int64 { 1 + 2 } }\n',kinds:[]},
 {name:'operator-call-positive',rule:'G.OPR.01',source:'class Value { operator func ()(): Int64 { 1 } }\n',kinds:['G_OPR_01_avoid_operator_overloading_that_violates_conventions_02']},

 {name:'interface-mutation-positive',rule:'G.ITF.01',rc:1,error:'immutable',source:'interface Counter { func increase(): Unit }\nstruct CounterValue <: Counter { var value: Int64 = 0\n public func increase(): Unit { value += 1 } }\n',kinds:['G_ITF_01_should_use_mut_modifier']},
 {name:'interface-mut-mismatch-error',rule:'G.ITF.01',source:'interface Counter { func increase(): Unit }\nstruct CounterValue <: Counter { var value: Int64 = 0\n public mut func increase(): Unit { value += 1 } }\n',rc:1,error:'incompatible with that in interface',kinds:['G_ITF_01_should_use_mut_modifier']},
 {name:'interface-mutation-control',rule:'G.ITF.01',source:'interface Counter { mut func increase(): Unit }\nstruct CounterValue <: Counter { var value: Int64 = 0\n public mut func increase(): Unit { value += 1 } }\n',kinds:[]},
 {name:'interface-mutation-suppressed',rule:'G.ITF.01',source:'interface Counter { func increase(): Unit } // cjlint-ignore !G.ITF.01\nstruct CounterValue <: Counter { var value: Int64 = 0\n public func increase(): Unit { value += 1 } }\n',rc:1,error:'immutable',kinds:[]},
 {name:'interface-parse-error',rule:'G.ITF.01',source:'interface Counter { func increase(: Unit }\n',rc:1,error:'Frontend parse failed',noReport:true},
 {name:'interface-import-error',rule:'G.ITF.01',source:'import missing_lint_fixture.Counter\n',rc:1,error:'Frontend package import failed',noReport:true},
 {name:'interface-extension-positive',rule:'G.ITF.02',source:'interface Action { func act(): Unit }\nstruct Item {}\nextend Item <: Action { public func act(): Unit {} }\n',kinds:['G_ITF_02_prefer_implement_interfaces_at_type_definition']},
 {name:'interface-extension-control',rule:'G.ITF.02',source:'interface Action { func act(): Unit }\nstruct Item <: Action { public func act(): Unit {} }\n',kinds:[]},
 {name:'interface-redundant-positive',rule:'G.ITF.03',source:'interface Parent {}\ninterface Child <: Parent {}\nclass Item <: Child & Parent {}\n',kinds:['G_ITF_03_avoid_declaring_both_parent_interface_and_sub_interface']},
 {name:'interface-redundant-control',rule:'G.ITF.03',source:'interface Parent {}\ninterface Child <: Parent {}\nclass Item <: Child {}\n',kinds:[]},
 {name:'sensitive-storage-positive',rule:'G.OTH.04',source:'let PASSWORD = "safe"\n',kinds:['G_OTH_04_avoid_use_string_type_to_store_sensitive_data']},
 {name:'sensitive-storage-option-positive',rule:'G.OTH.04',source:'let password: Option<String> = Some("safe")\n',kinds:['G_OTH_04_avoid_use_string_type_to_store_sensitive_data']},
 {name:'sensitive-storage-numeric-control',rule:'G.OTH.04',source:'let password: Int64 = 42\n',kinds:[]},
 {name:'sensitive-storage-name-control',rule:'G.OTH.04',source:'let message: String = "safe"\n',kinds:[]},
 {name:'sensitive-storage-config-control',rule:'G.OTH.04',source:'let password: String = "safe"\n',config:{'structural_rule_G_OTH_04.json':{SensitiveDataVar:['secret']}},kinds:[]},
 {name:'security-open-positive',rule:'G.SEC.01',source:'open class Guard { public open func checkAccess(): Bool { true } }\n',kinds:['G_SEC_01_open_check_function_information']},
 {name:'security-static-positive',rule:'G.SEC.01',source:'open class Guard { public static func CHECK(): Bool { true } }\n',kinds:['G_SEC_01_open_check_function_information']},
 {name:'security-interface-positive',rule:'G.SEC.01',source:'interface Guard { func checkAccess(): Bool }\n',kinds:['G_SEC_01_open_check_function_information']},
 {name:'security-closed-control',rule:'G.SEC.01',source:'class Guard { public func checkAccess(): Bool { true } }\n',kinds:[]},
 {name:'security-name-control',rule:'G.SEC.01',source:'open class Guard { public open func act(): Bool { true } }\n',kinds:[]},
 {name:'exception-sensitive-positive',rule:'G.ERR.02',source:'func api(): Unit { throw Exception("PASSWORD rejected") }\n',kinds:['G_ERR_02_sensitive_info']},
 {name:'exception-sensitive-concat-positive',rule:'G.ERR.02',source:'func api(): Unit { let prefix = "password"\n throw Exception(prefix + " rejected") }\n',kinds:['G_ERR_02_sensitive_info']},
 {name:'exception-sensitive-word-control',rule:'G.ERR.02',source:'func api(): Unit { throw Exception("passwords rejected") }\n',kinds:[]},
 {name:'hardcoded-secret-positive',rule:'G.OTH.02',source:'let password = "paswd"\n',kinds:['G_OTH_02_hardcode_sensitivename_information','G_OTH_02_hardcode_weakpasscode_information']},
 {name:'hardcoded-payload-positive',rule:'G.OTH.02',source:'let command = "chmod"\n',kinds:['G_OTH_02_hardcode_sensitive_information']},
 {name:'hardcoded-secret-control',rule:'G.OTH.02',source:'let message = "safe"\n',kinds:[]},
 {name:'constant-comparison-positive',rule:'G.EXP.07',source:'var changing = 2\nlet result = 1 == changing\n',kinds:['G_EXP_07_constants_on_the_right']},
 {name:'constant-reference-positive',rule:'G.EXP.07',source:'let fixed = 1\nvar changing = 2\nlet result = fixed == changing\n',kinds:['G_EXP_07_constants_on_the_right']},
 {name:'constant-comparison-control',rule:'G.EXP.07',source:'var changing = 2\nlet result = changing == 1\n',kinds:[]},
 {name:'constant-interval-control',rule:'G.EXP.07',source:'var changing = 2\nlet result = 0 < changing && changing < 10\n',kinds:[]},
 {name:'address-ip-positive',rule:'G.OTH.03',source:'let address = "8.8.8.8"\n',kinds:['G_OTH_03_public_ip_hardcode_information']},
 {name:'address-url-positive',rule:'G.OTH.03',source:'let address = "https://example.com/path"\n',kinds:['G_OTH_03_public_url_hardcode_information']},
 {name:'address-email-positive',rule:'G.OTH.03',source:'let address = "person@example.com"\n',kinds:['G_OTH_03_public_email_hardcode_information']},
 {name:'address-private-control',rule:'G.OTH.03',source:'let addresses = "10.0.0.1 172.16.0.1 192.168.0.1 127.0.0.1 169.254.0.1 255.255.255.255 224.0.0.1 0.0.0.0"\n',kinds:[]},
 {name:'address-multicast-zero-positive',rule:'G.OTH.03',source:'let address = "224.0.0.0"\n',kinds:['G_OTH_03_public_ip_hardcode_information']},
 {name:'address-link-zero-positive',rule:'G.OTH.03',source:'let address = "169.254.0.0"\n',kinds:['G_OTH_03_public_ip_hardcode_information']},
 {name:'address-whitelist-control',rule:'G.OTH.03',source:'let address = "https://cangjie-lang.cn/pages/LICENSE"\n',kinds:[]},
 {name:'address-custom-whitelist-control',rule:'G.OTH.03',source:'let address = "8.8.8.8"\n',config:{'structural_rule_G_OTH_03.json':{WhiteList:['8.8.8.8']}},kinds:[]},
 {name:'enum-name-positive',rule:'G.ENU.01',source:'enum State { Ready | Waiting }\nclass Ready {}\n',kinds:['G_ENU_01_0_duplicate_name_information','G_ENU_01_1_duplicate_name_information']},
 {name:'enum-name-control',rule:'G.ENU.01',source:'enum State { Ready | Waiting }\nclass Application {}\n',kinds:[]},
 {name:'enum-overload-positive',rule:'G.ENU.02',source:'enum First { Shared(Int64) }\nenum Second { Shared(Int64) }\n',kinds:['G_ENU_02_enum_constructor_overload_information']},
 {name:'enum-overload-type-control',rule:'G.ENU.02',source:'enum First { Shared(Int64) }\nenum Second { Shared(Bool) }\n',kinds:[]},
 {name:'enum-overload-arity-control',rule:'G.ENU.02',source:'enum First { Shared(Int64) }\nenum Second { Shared(Int64, Int64) }\n',kinds:[]},
 {name:'match-dimensions-positive',rule:'G.EXP.01',source:'func classify(value: Any): Int64 { match (value) { case _: Int64 => 1\n case fallback => 2 } }\n',kinds:['G_EXP_01_avoid_mixed_patterns_in_match_expr_02']},
 {name:'match-dimensions-control',rule:'G.EXP.01',source:'func classify(value: Any): Int64 { match (value) { case _: Int64 => 1\n case _ => 2 } }\n',kinds:[]},
 {name:'match-value-control',rule:'G.EXP.01',source:'func classify(value: Int64): Int64 { match (value) { case 1 => 1\n case _ => 2 } }\n',kinds:[]},
 {name:'overload-scope-positive',rule:'G.FUN.03',source:'func process(value: Int64): Unit {}\nfunc outer(): Unit { func process(value: Bool): Unit {} }\n',kinds:['G_FUN_03_overload_in_different_scopes']},
 {name:'overload-scope-control',rule:'G.FUN.03',source:'func process(value: Int64): Unit {}\nfunc outer(): Unit { func process(value: Int64): Unit {} }\n',kinds:[]},
 {name:'overload-primitive-control',rule:'G.FUN.03',source:'func process(value: Int64): Unit {}\nfunc process(value: Bool): Unit {}\n',kinds:[]},
 {name:'overload-inheritance-positive',rule:'G.FUN.03',source:'open class Parent {}\nclass Child <: Parent {}\nfunc process(value: Parent): Unit {}\nfunc process(value: Child): Unit {}\n',kinds:['G_FUN_03_params_in_overload_funcs']},
 {name:'declaration-positive',rule:'G.DCL.02',source:'public let value = 1\npublic func api() { return 1 }\n',kinds:['G_DCL_02_public_variable_type','G_DCL_02_public_function_type']},
 {name:'declaration-control',rule:'G.DCL.02',source:'public let value: Int64 = 1\npublic func api(): Int64 { return 1 }\n',kinds:[]},
 {name:'function-positive',rule:'G.NAM.04',source:'func BadName(): Unit {}\n',kinds:['G_NAM_04_function_naming_information']},
 {name:'function-control',rule:'G.NAM.04',source:'func goodName(): Unit {}\n',kinds:[]},
 {name:'constant-positive',rule:'G.NAM.05',source:'let badName: Int64 = 1\n',kinds:['G_NAM_05_immutable_global_variable_naming_information']},
 {name:'constant-control',rule:'G.NAM.05',source:'let GOOD_NAME: Int64 = 1\nvar mutableName: Int64 = 1\nfunc locals(): Unit { let localName: Int64 = 1 }\n',kinds:[]},
 {name:'global-positive',rule:'G.VAR.03',source:'var changing: Int64 = 1\nlet fixed: Int64 = 2\n',kinds:['G_VAR_03_global_variable_declaration_information','G_VAR_03_global_variable_declaration_information']},
 {name:'global-control',rule:'G.VAR.03',source:'const CONSTANT: Int64 = 1\nfunc locals(): Unit { var localValue: Int64 = 1 }\n',kinds:[]},
 {name:'import-positive',rule:'G.PKG.01',source:'import std.collection.*\nfunc api(): Unit {}\n',kinds:['G_PKG_01_avoid_wildcard']},
 {name:'import-control',rule:'G.PKG.01',source:'import std.collection.ArrayList\nfunc api(): Unit {}\n',kinds:[]},
 {name:'finally-positive',rule:'G.ERR.04',source:'func api(): Unit { try {} finally { return } }\n',kinds:['G_ERR_04_avoid_return_finally']},
 {name:'finally-loop-control',rule:'G.ERR.04',source:'func api(): Unit { try {} finally { while (true) { break } } }\n',kinds:[]},
 {name:'package-positive',rule:'G.NAM.01',source:'package BadName\nfunc api(): Unit {}\n',kinds:['G_NAM_01_Package_Information']},
 {name:'package-control',rule:'G.NAM.01',source:'package good_name\nfunc api(): Unit {}\n',kinds:[]},
 {name:'package-path-positive',rule:'G.NAM.01',source:'package aaa.bbb\nfunc api(): Unit {}\n',kinds:['G_NAM_01_Package_name_should_match_path']},
 {name:'package-path-control',rule:'G.NAM.01',subdir:'aaa/bbb',source:'package aaa.bbb\nfunc api(): Unit {}\n',kinds:[]},
 {name:'filename-positive',rule:'G.NAM.02',filename:'BadName.cj',source:'func api(): Unit {}\n',kinds:['G_NAM_02_filename_lower_information']},
 {name:'filename-type-positive',rule:'G.NAM.02',source:'public class Foo {}\n',kinds:['G_NAM_02_filename_standard_information']},
 {name:'filename-control',rule:'G.NAM.02',filename:'my_class.cj',source:'public class MyClass {}\n',kinds:[]},
 {name:'copyright-positive',rule:'G.FMT.13',source:'func api(): Unit {}\n',kinds:['G_FMT_13_header_comments_copyright_01']},
 {name:'copyright-line-positive',rule:'G.FMT.13',source:'// Copyright (c) Example\nfunc api(): Unit {}\n',kinds:['G_FMT_13_header_comments_copyright_02']},
 {name:'copyright-control',rule:'G.FMT.13',source:'/* Copyright (c) Example */\nfunc api(): Unit {}\n',kinds:[]},
 {name:'unicode-path',rule:'G.NAM.04',filename:'文件.cj',source:'func BadName(): Unit {}\n',kinds:['G_NAM_04_function_naming_information']},
 {name:'function-args-positive',rule:'G.FUN.01',source:'func api(a: Int64, b: Int64, c: Int64, d: Int64, e: Int64, f: Int64): Unit {}\n',kinds:['G_FUN_01_function_single_responsibility_information_0']},
 {name:'function-args-control',rule:'G.FUN.01',source:'func api(a: Int64, b: Int64, c: Int64, d: Int64, e: Int64): Unit {}\n',kinds:[]},
 {name:'function-depth-positive',rule:'G.FUN.01',source:'func api(): Unit { '+ 'if (true) { '.repeat(5)+'}'.repeat(5)+' }\n',kinds:['G_FUN_01_function_single_responsibility_information_2']},
 {name:'function-depth-control',rule:'G.FUN.01',source:'func api(): Unit { '+ 'if (true) { '.repeat(4)+'}'.repeat(4)+' }\n',kinds:[]},
 {name:'function-lines-positive',rule:'G.FUN.01',source:'func api(): Unit {\n'+ 'println(1)\n'.repeat(49)+'}\n',kinds:['G_FUN_01_function_single_responsibility_information_1']},
 {name:'function-lines-control',rule:'G.FUN.01',source:'func api(): Unit {\n'+ 'println(1)\n'.repeat(48)+'}\n',kinds:[]},
 {name:'function-comment-control',rule:'G.FUN.01',source:'func api(): Unit {\n'+ '// only comment\n'.repeat(60)+'}\n',kinds:[]},
 {name:'function-constructor-control',rule:'G.FUN.01',source:'class Api { init(a: Int64, b: Int64, c: Int64, d: Int64, e: Int64, f: Int64) {} }\n',kinds:[]},
 {name:'lambda-args-positive',rule:'G.FUN.01',source:'let api = {a: Int64, b: Int64, c: Int64, d: Int64, e: Int64, f: Int64 => 1}\n',kinds:['G_FUN_01_function_single_responsibility_information_3']},
 {name:'lambda-args-control',rule:'G.FUN.01',source:'let api = {a: Int64, b: Int64, c: Int64, d: Int64, e: Int64 => 1}\n',kinds:[]},
 {name:'lambda-depth-positive',rule:'G.FUN.01',source:'let api = { => '+ 'if (true) { '.repeat(5)+'}'.repeat(5)+' }\n',kinds:['G_FUN_01_function_single_responsibility_information_5']},
 {name:'lambda-depth-control',rule:'G.FUN.01',source:'let api = { => '+ 'if (true) { '.repeat(4)+'}'.repeat(4)+' }\n',kinds:[]},
 {name:'lambda-lines-positive',rule:'G.FUN.01',source:'let api = { =>\n'+ 'println(1)\n'.repeat(49)+'}\n',kinds:['G_FUN_01_function_single_responsibility_information_4']},
 {name:'lambda-lines-control',rule:'G.FUN.01',source:'let api = { =>\n'+ 'println(1)\n'.repeat(48)+'}\n',kinds:[]},
 {name:'paren-unary-positive',rule:'G.EXP.05',source:'let result = (!flag)\n',kinds:['G_EXP_05_use_parentheses_to_express_operations_order_01']},
 {name:'paren-unary-control',rule:'G.EXP.05',source:'let result = !flag\n',kinds:[]},
 {name:'paren-nested-positive',rule:'G.EXP.05',source:'let result = ((value))\n',kinds:['G_EXP_05_use_parentheses_to_express_operations_order_03']},
 {name:'paren-same-positive',rule:'G.EXP.05',source:'let result = (a + b) + c\n',kinds:['G_EXP_05_use_parentheses_to_express_operations_order_02']},
 {name:'paren-same-right-positive',rule:'G.EXP.05',source:'let result = a + (b + c)\n',kinds:['G_EXP_05_use_parentheses_to_express_operations_order_02']},
 {name:'paren-order-control',rule:'G.EXP.05',source:'let result = (a + b) * c\n',kinds:[]},
 {name:'paren-mixed-positive',rule:'G.EXP.05',source:'let result = a << b + c\n',kinds:['G_EXP_05_use_parentheses_to_express_operations_order_04']},
 {name:'paren-mixed-control',rule:'G.EXP.05',source:'let result = a << (b + c)\n',kinds:[]},
 {name:'paren-tuple-positive',rule:'G.EXP.05',source:'let result = ((a), b)\n',kinds:['G_EXP_05_use_parentheses_to_express_operations_order_03']},
 {name:'paren-tuple-control',rule:'G.EXP.05',source:'let result = (a, b)\n',kinds:[]},
 {name:'paren-array-positive',rule:'G.EXP.05',source:'let result = [(a), b]\n',kinds:['G_EXP_05_use_parentheses_to_express_operations_order_03']},
 {name:'paren-array-control',rule:'G.EXP.05',source:'let result = [a, b]\n',kinds:[]},
 {name:'unused-param-positive',rule:'G.FUN.02',source:'func api(value: Int64): Unit {}\n',kinds:['G_FUN_02_unused_param_information']},
 {name:'unused-param-control',rule:'G.FUN.02',source:'func api(value: Int64): Unit { println(value) }\n',kinds:[]},
 {name:'unused-param-default-control',rule:'G.FUN.02',source:'func api(value: Int64, next!: Int64 = value): Unit { println(next) }\n',kinds:[]},
 {name:'unused-param-wildcard-control',rule:'G.FUN.02',source:'func api(_: Int64): Unit {}\n',kinds:[]},
 {name:'unused-param-interface-control',rule:'G.FUN.02',source:'interface Api { func call(value: Int64): Unit }\n',kinds:[]},
 {name:'unused-param-string-positive',rule:'G.FUN.02',source:'func api(value: Int64): Unit { println("value") }\n',kinds:['G_FUN_02_unused_param_information']},
 {name:'unused-param-capture-control',rule:'G.FUN.02',source:'func api(value: Int64): Unit { let closure = { => value }; println(closure()) }\n',kinds:[]},
 {name:'unused-param-nested-positive',rule:'G.FUN.02',source:'func api(value: Int64): Unit { func nested(unused: Int64): Unit { println(value) }; nested(1) }\n',kinds:['G_FUN_02_unused_param_information']},
 ...[['invalid-continuation',[0x80]],['truncated',[0xe4,0xb8]],['overlong',[0xc0,0x80]],
     ['surrogate',[0xed,0xa0,0x80]],['out-of-range',[0xf4,0x90,0x80,0x80]]].map(([name,bytes])=>
    ({name:'encoding-'+name,rule:'G.FMT.01',source:Buffer.from(bytes),rc:1,kinds:['G_FMT_01_encoding_UTF_8_information']})),
 {name:'encoding-unicode-control',rule:'G.FMT.01',source:'// 中文 é 😀\nfunc api(): Unit {}\n',kinds:[]},
 {name:'encoding-empty-control',rule:'G.FMT.01',source:'',kinds:[]},
 {name:'exception-catch-positive',rule:'G.ERR.01',source:'func api(): Unit { try {} catch (_: Exception) {} }\n',kinds:['G_ERR_01_exceptions_process_01']},
 {name:'exception-catch-comment-positive',rule:'G.ERR.01',source:'func api(): Unit { try {} catch (_: Exception) { /* ignored */ } }\n',kinds:['G_ERR_01_exceptions_process_01']},
 {name:'exception-catch-control',rule:'G.ERR.01',source:'func api(): Unit { try {} catch (err: Exception) { println(err) } }\n',kinds:[]},
 {name:'exception-throw-positive',rule:'G.ERR.01',source:'func api(): Unit { throw Exception("bad") }\n',kinds:['G_ERR_01_exceptions_process_02']},
 {name:'exception-throw-control',rule:'G.ERR.01',source:'// Throws Exception when unavailable\nfunc api(): Unit { throw Exception("bad") }\n',kinds:[]},
 {name:'exception-main-positive',rule:'G.ERR.01',source:'main(): Unit { throw Exception("bad") }\n',kinds:['G_ERR_01_exceptions_process_02']},
 {name:'exception-main-control',rule:'G.ERR.01',source:'// Throws Exception when unavailable\nmain(): Unit { throw Exception("bad") }\n',kinds:[]},
 {name:'exception-variable-control',rule:'G.ERR.01',source:'func api(err: Exception): Unit { throw err }\n',kinds:[]},
 {name:'exception-nested-positive',rule:'G.ERR.01',source:'// Throws Exception\nfunc api(): Unit { func nested(): Unit { throw Exception("bad") }; nested() }\n',kinds:['G_ERR_01_exceptions_process_02']},
 {name:'boolean-comparison-positive',rule:'G.EXP.06',source:'let flag: Bool = true\nlet result = flag == true\n',kinds:['G_EXP_06_avoid_redundant_op_in_bool_type_comparisons']},
 {name:'boolean-comparison-control',rule:'G.EXP.06',source:'let flag: Bool = true\nlet other: Bool = false\nlet result = flag == other\n',kinds:[]},
 {name:'boolean-numeric-control',rule:'G.EXP.06',source:'let result = 1 == 2\n',kinds:[]},
 {name:'decimal-leading-positive',rule:'G.FMT.15',source:'let result: Float64 = 1e5\n',kinds:['G_FMT_15_leading_zero_before_decimal']},
 {name:'decimal-leading-control',rule:'G.FMT.15',source:'let result: Float64 = 1.0e5\n',kinds:[]},
 {name:'nan-positive',rule:'G.TYP.03',source:'let value: Float64 = 1.0\nlet result = value == Float64.NaN\n',kinds:['G_TYP_03_use_isNaN_method_float']},
 {name:'nan-control',rule:'G.TYP.03',source:'let value: Float64 = 1.0\nlet result = value.isNaN()\n',kinds:[]},
 {name:'interface-types-positive',rule:'G.ITF.04',source:'interface Api {}\nfunc api(input: Api): Api { return input }\n',kinds:['G_ITF_04_avoid_directly_using_interfaces_as_types_01','G_ITF_04_avoid_directly_using_interfaces_as_types_02']},
 {name:'interface-types-control',rule:'G.ITF.04',source:'interface Api {}\nclass Box <: Api {}\nfunc api(input: Box): Box { return input }\n',kinds:[]},
 {name:'parameter-name-positive',rule:'G.NAM.06',source:'func api(x: Int64): Unit {}\n',kinds:['G_NAM_06_parameter_camelCase_name']},
 {name:'parameter-name-control',rule:'G.NAM.06',source:'func api(value: Int64): Unit {}\n',kinds:[]},
 {name:'variable-name-positive',rule:'G.NAM.06',source:'var BadName: String = ""\n',kinds:['G_NAM_06_var_camelCase_name']},
 {name:'variable-name-control',rule:'G.NAM.06',source:'var goodName: String = ""\nlet NUMERIC_CONSTANT: Int64 = 1\n',kinds:[]},
 {name:'generic-name-positive',rule:'G.NAM.06',source:'func api<item>(value: item): Unit {}\n',kinds:['G_NAM_06_generic_type_parameters']},
 {name:'generic-name-control',rule:'G.NAM.06',source:'func api<T>(value: T): Unit {}\n',kinds:[]},
 {name:'type-name-positive',rule:'G.NAM.03',source:'class wrong {}\n',kinds:['G_NAM_03_identifier_naming_information']},
 {name:'type-name-control',rule:'G.NAM.03',source:'class Correct {}\n',kinds:[]},
 {name:'exception-name-positive',rule:'G.NAM.03',source:'class Fault <: Exception { init() { super("bad") } }\n',kinds:['G_NAM_03_exception_naming_information']},
 {name:'exception-name-control',rule:'G.NAM.03',source:'class FaultException <: Exception { init() { super("bad") } }\n',kinds:[]},
 {name:'enum-operator-positive',rule:'G.OPR.02',source:'enum Choice { One | Two\n operator func ()(): Int64 { return 1 } }\n',kinds:['G_OPR_02_enum_parentheses_overload_information']},
 {name:'enum-operator-control',rule:'G.OPR.02',source:'class Choice { operator func ()(): Int64 { return 1 } }\n',kinds:[]},
 {name:'option-throw-positive',rule:'G.ERR.03',source:'func api(): Unit { let value: Option<Int64> = None; println(value.getOrThrow()) }\n',kinds:['G_ERR_03_avoid_option_getorthrow']},
 {name:'option-throw-control',rule:'G.ERR.03',source:'func api(): Unit { let value: Option<Int64> = None; try { println(value.getOrThrow()) } catch (_: NoneValueException) { println("missing") } }\n',kinds:[]},
 {name:'mutex-global-positive',rule:'G.CON.01',source:'import std.sync.ReentrantMutex\nlet lock = ReentrantMutex()\n',kinds:['G_CON_01_synchronized_object_modifier_information_2']},
 {name:'mutex-local-control',rule:'G.CON.01',source:'import std.sync.ReentrantMutex\nfunc api(): Unit { let lock = ReentrantMutex() }\n',kinds:[]},
 {name:'pointer-conversion-positive',rule:'FFI.C.7',source:'func api(): Unit { unsafe { let pointer = CPointer<Int8>(); let converted = CPointer<Int64>(pointer) } }\n',kinds:['FFI_C_7_avoid_truncation_error']},
 {name:'pointer-conversion-control',rule:'FFI.C.7',source:'func api(): Unit { unsafe { let pointer = CPointer<Int8>(); let converted = CPointer<Int8>(pointer) } }\n',kinds:[]}
];
// Preserve the original semantic-error inputs while exercising the selected
// CHIR branch: the frontend must still report SEMA findings and return rc1.
for(const name of ['interface-mutation-positive','interface-mut-mismatch-error','interface-mutation-suppressed','interface-parse-error','interface-import-error']) {
  const original=cases.find(c=>c.name===name);assert.ok(original);
  cases.push({...original,name:name+'-with-chir',rules:['G.ITF.01','G.FIO.01','G.VAR.01']});
}
cases.push({name:'immutable-local-suppressed',rule:'G.VAR.01',source:'func api(): Int64 { var value = 1 // cjlint-ignore !G.VAR.01\n value }\n',kinds:[]});
// Preserve the first rejected capture inputs and assert their real stage.
for(const name of ['immutable-captured-write-control','immutable-captured-read-positive']) {
  const test=cases.find(c=>c.name===name);test.rc=1;test.error='lambda capturing mutable variables needs to be called directly';test.kinds=[];
}
cases.push({name:'immutable-captured-iife-write-control',rule:'G.VAR.01',source:'func api(): Int64 { var value = 1\n { => value = 2 }()\n value }\n',kinds:[]});
cases.push({name:'immutable-captured-iife-read-positive',rule:'G.VAR.01',source:'func api(): Int64 { var value = 1\n { => value }() }\n',kinds:['G_VAR_01_prefer_immutable_var']});
let executed=0;
for(const c of cases){
  if(v['cli-only']&&!['declaration-positive','declaration-control','function-control','constant-control'].includes(c.name))continue;
  if(v.case&&c.name!==v.case)continue;
  if(v.rules&&!v.rules.split(',').includes(c.rule))continue;
  executed++;
  const root=path.join(work,c.name),source=path.join(root,'src',c.subdir??'');fs.mkdirSync(source,{recursive:true});
  fs.cpSync(path.join(prefix,'config'),path.join(root,'config'),{recursive:true});
  for(const [name,settings] of Object.entries(c.config??{}))fs.writeFileSync(path.join(root,'config',name),JSON.stringify(settings));
  fs.writeFileSync(path.join(root,'config/cjlint_rule_list.json'),JSON.stringify({RuleList:c.rules??[c.rule,c.rule.toLowerCase()]}));
  const filename=c.filename??'main.cj';
  const text=c.rule==='G.EXP.05'?'func api(a: Int64, b: Int64, c: Int64, flag: Bool): Unit {\n'+c.source+'}\n':c.source;
  fs.writeFileSync(path.join(source,filename),text);
  for(const [name,content] of Object.entries(c.files??{})){fs.mkdirSync(path.dirname(path.join(source,name)),{recursive:true});fs.writeFileSync(path.join(source,name),content);}
  const report=path.join(root,'report.json');
  if(c.dependencies)assert.ok(v['import-path'],'real dependency --import-path required');
  const result=run(c.name,['-f',source,'-c',root,'-o',report,...(c.dependencies?['--import-path',v['import-path']]:[])]);
  check(c.name,()=>{
    assert.equal(result.status,c.rc??0,`${c.name}: actual executable failed`);
    if(c.error)assert.ok(result.stderr.includes(c.error),'real frontend error diagnostic');
    if(c.noReport){assert.equal(fs.existsSync(report),false,'early frontend failure must not produce a report');return;}
    const findings=JSON.parse(fs.readFileSync(report,'utf8'));
    assert.deepEqual(findings.map(f=>f.defectType).sort(),c.kinds.slice().sort(),'target rule diagnostics');
    for(const f of findings){
      assert.equal(f.file,path.join(source,c.reportFile??filename));assert.equal(f.analyzerName,'cangjieCodeCheck');
      assert.equal(f.language,'cangjie');assert.ok(f.line>0&&f.column>0);assert.ok(f.description.startsWith(c.rule+':'));
    }
  });
}
if(v.case||v.rules){
  if(v.case)assert.equal(executed,1,'unknown --case');else assert.ok(executed>0,'unknown --rules');
  console.log(JSON.stringify({commands:commands.length,assertions:assertions.length,passed:assertions.filter(x=>x.pass).length}));
  process.exit(assertions.some(x=>!x.pass)?1:0);
}
for(const option of ['-h','-v'])check('control-'+option,()=>assert.equal(run('control-'+option,[option]).status,0));
const src=path.join(work,'declaration-control/src'),config=path.join(work,'declaration-control');
check('unknown-before-help',()=>assert.equal(run('unknown-before-help',['--unknown','-h']).status,1));
check('help-as-source-value',()=>assert.equal(run('help-as-source-value',['-f','-h']).status,1));
check('version-as-output-value',()=>{
  assert.equal(run('version-as-output-value',['-o','-v','-f',src,'-c',config]).status,0);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(work,'-v.json'),'utf8')),[]);
});
check('multiple-source-directories',()=>{
  const first=path.join(work,'constant-control/src'),second=path.join(work,'function-control/src');
  const report=path.join(work,'multiple-report.json');
  assert.equal(run('multiple-source-directories',['-f',first+' '+second,'-c',config,'-o',report]).status,0);
  assert.deepEqual(JSON.parse(fs.readFileSync(report,'utf8')),[]);
});
check('overlapping-source-directories',()=>{
  const positive=path.join(work,'declaration-positive/src'),report=path.join(work,'overlap-report.json');
  assert.equal(run('overlapping-source-directories',['-f',positive+' '+path.dirname(positive),'-c',config,'-o',report]).status,0);
  assert.equal(JSON.parse(fs.readFileSync(report,'utf8')).length,2);
});
const defaultSource=path.join(work,'default-src');fs.mkdirSync(defaultSource);
fs.writeFileSync(path.join(defaultSource,'main.cj'),'package example\nvar value = 1\nfunc api(): Int64 { value }\n');
check('default-all-configured-rules',()=>{
  const report=path.join(work,'default.json');
  assert.equal(run('default-all-configured-rules',['-f',defaultSource,'-o',report]).status,0);
  assert.ok(JSON.parse(fs.readFileSync(report,'utf8')).some(f=>f.defectType==='G_VAR_01_prefer_immutable_var'),'default dispatch reaches CHIR rule');
});
check('explicit-modules-root',()=>{
  const report=path.join(work,'explicit-modules.json');
  assert.equal(run('explicit-modules-root',['-f',defaultSource,'-m',prefix,'-o',report]).status,0);
  assert.ok(JSON.parse(fs.readFileSync(report,'utf8')).some(f=>f.defectType==='G_VAR_01_prefer_immutable_var'));
});
check('missing-modules-root',()=>{
  const report=path.join(work,'missing-modules.json');
  assert.equal(run('missing-modules-root',['-f',defaultSource,'-m',path.join(work,'absent-modules'),'-o',report]).status,1);
  assert.equal(fs.existsSync(report),false);
});
for(const name of ['interface-mutation-positive','interface-mut-mismatch-error'])check('default-'+name,()=>{
  const original=cases.find(c=>c.name===name),source=path.join(work,'default-'+name);fs.mkdirSync(source);
  fs.writeFileSync(path.join(source,'main.cj'),original.source);
  const report=path.join(work,'default-'+name+'.json');
  const result=run('default-'+name,['-f',source,'-o',report]);assert.equal(result.status,1);
  assert.ok(result.stderr.includes(original.error),'original SEMA diagnostic with default rules');
  assert.ok(JSON.parse(fs.readFileSync(report,'utf8')).some(f=>f.defectType==='G_ITF_01_should_use_mut_modifier'),'default SEMA error report reaches target');
});
check('explicit-all-reference-rules',()=>{
  const reference=JSON.parse(fs.readFileSync(new URL('./reference-surface.json',import.meta.url),'utf8'));
  const rules=[...new Set(reference.registrations.map(r=>r.id))];assert.equal(rules.length,60);
  const root=path.join(work,'all-config');fs.mkdirSync(root);fs.cpSync(path.join(prefix,'config'),path.join(root,'config'),{recursive:true});
  fs.writeFileSync(path.join(root,'config/cjlint_rule_list.json'),JSON.stringify({RuleList:rules}));
  const report=path.join(work,'all.json');
  assert.equal(run('explicit-all-reference-rules',['-f',defaultSource,'-c',root,'-o',report]).status,0);
  assert.ok(JSON.parse(fs.readFileSync(report,'utf8')).some(f=>f.defectType==='G_VAR_01_prefer_immutable_var'),'all-rule dispatch reaches CHIR rule');
});
for(const [name,text] of [['malformed','{"RuleList": ['],['unknown','{"RuleList":["UNKNOWN"]}'],['wrong-type','{"RuleList":false}'],['duplicate-key','{"RuleList":[],"RuleList":[]}']]){
  const root=path.join(work,name);fs.mkdirSync(path.join(root,'config'),{recursive:true});
  fs.writeFileSync(path.join(root,'config/cjlint_rule_list.json'),text);
  check(name,()=>assert.notEqual(run(name,['-f',src,'-c',root]).status,0));
}
check('report-write-error',()=>assert.notEqual(run('report-write-error',['-f',src,'-c',config,'-o',path.join(work,'absent/output')]).status,0));
const bad=path.join(work,'bad-source');fs.mkdirSync(bad);fs.writeFileSync(path.join(bad,'main.cj'),'public func ( {');
check('parse-error',()=>assert.notEqual(run('parse-error',['-f',bad,'-c',config]).status,0));
const positive=path.join(work,'declaration-positive');
check('csv',()=>{
  assert.equal(run('csv',['-f',path.join(positive,'src'),'-c',positive,'-r','csv','-o',path.join(work,'csv')]).status,0);
  const csv=fs.readFileSync(path.join(work,'csv.csv'),'utf8');
  assert.ok(csv.startsWith('SourceFile,Line,Column,EndLine,EndColumn,Description,DefectType,DefectLevel\n'));
  assert.ok(csv.includes('G_DCL_02_public_variable_type'));assert.ok(csv.includes('G_DCL_02_public_function_type'));
});
check('report-replacement',()=>{
  const report=path.join(work,'declaration-positive/report.json');
  assert.equal(run('report-replacement',['-f',path.join(positive,'src'),'-c',positive,'-o',report]).status,0);
  assert.equal(JSON.parse(fs.readFileSync(report,'utf8')).length,2);
});
console.log(JSON.stringify({commands:commands.length,assertions:assertions.length,passed:assertions.filter(x=>x.pass).length,qualification:'selected installed-host cases; target SDK qualification is separate'}));
if(assertions.some(x=>!x.pass))process.exitCode=1;
