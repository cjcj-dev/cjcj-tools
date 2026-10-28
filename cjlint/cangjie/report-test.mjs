#!/usr/bin/env zx
// Exercise the installed product's actual output, without sorting or deduplicating it in the test.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {parseArgs} from 'node:util';
const {values:v}=parseArgs({options:{prefix:{type:'string'},work:{type:'string'},case:{type:'string'},'import-path':{type:'string'}}});
for(const name of ['prefix','work','import-path'])assert.ok(v[name],name);
const prefix=path.resolve(v.prefix),work=path.resolve(v.work),exe=prefix+'/bin/cjlint';fs.mkdirSync(work);
const fixtures=JSON.parse(fs.readFileSync(new URL('./report-fixtures.json',import.meta.url)));
const fixture=name=>structuredClone(fixtures.find(c=>c.name===name));
const commands=[],assertions=[];
const env={...process.env};for(const k of ['CANGJIE_HOME','CANGJIE_PATH','LD_LIBRARY_PATH','LD_PRELOAD','LD_AUDIT'])delete env[k];
function csv(text){const rows=[],row=[];let field='',quoted=false;for(let i=0;i<text.length;i++){const c=text[i];if(c==='"'){if(quoted&&text[i+1]==='"'){field+='"';i++;}else quoted=!quoted;}else if(!quoted&&(c===','||c==='\n')){row.push(field);field='';if(c==='\n'){rows.push(row.splice(0));}}else field+=c;}assert.equal(quoted,false);return rows.slice(1).map(r=>({file:r[0],line:Number(r[1]),column:Number(r[2]),description:r[5]}));}
function test(name,c,format,verify){
 if(v.case&&name!==v.case)return;
 const root=work+'/'+name,src=root+'/src';fs.mkdirSync(src,{recursive:true});fs.cpSync(prefix+'/config',root+'/config',{recursive:true});
 fs.writeFileSync(root+'/config/cjlint_rule_list.json',JSON.stringify({RuleList:c.rules??[c.rule]}));
 for(const [f,s] of Object.entries(c.config??{}))fs.writeFileSync(root+'/config/'+f,JSON.stringify(s));
 const files=c.files??{'main.cj':c.source};for(const [f,s] of Object.entries(files))fs.writeFileSync(src+'/'+f,s);
 const report=root+'/report.'+format,args=['-f',src,'-c',root,...(format==='console'?[]:['-o',report,'-r',format]),...(c.dependencies?['--import-path',v['import-path']]:[])];
 const r=spawnSync(exe,args,{cwd:work,env,encoding:'utf8',maxBuffer:1024*1024});fs.writeFileSync(root+'/stdout',r.stdout??'');fs.writeFileSync(root+'/stderr',r.stderr??'');
 commands.push({name,argv:[exe,...args],rc:r.status,signal:r.signal});fs.writeFileSync(work+'/commands.json',JSON.stringify(commands,null,2)+'\n');
 try{assert.equal(r.status,c.rc??0,'actual product exit');let rows;
 if(format==='json')rows=JSON.parse(fs.readFileSync(report,'utf8'));
 else if(format==='csv')rows=csv(fs.readFileSync(report,'utf8'));
 else rows=(r.stdout??'').trim().split('\n').filter(Boolean).map(line=>{const m=line.match(/^(.*):(\d+):(\d+): (.*)$/);assert.ok(m,'actual console diagnostic');return {file:m[1],line:Number(m[2]),column:Number(m[3]),description:m[4]};});
 verify(rows,src);assertions.push({name,pass:true});
 }catch(e){assertions.push({name,pass:false,error:e.message});}
 fs.writeFileSync(work+'/assertions.json',JSON.stringify(assertions,null,2)+'\n');
}
const one=description=>(rows,src)=>{assert.equal(rows.length,1,'one actual diagnostic');assert.equal(rows[0].description,typeof description==='function'?description(src):description,'exact diagnostic body');};
test('shadow-body',fixture('shadow-global-positive'),'json',one("G.DCL.01: 'value' on line 1 is shadowed by the 'value' on line 2, please avoid shadowing."));
test('shadow-function-body',fixture('shadow-function-positive'),'csv',one("G.DCL.01: 'act' on line 1 is shadowed by the 'act' on line 2, please avoid shadowing."));
test('shadow-generic-body',fixture('shadow-generic-positive'),'json',one("G.DCL.01: 'T' on line 1 is shadowed by the 'T' on line 1, please avoid shadowing."));
test('lock-body',fixture('lock-order-positive'),'console',one(src=>`P.01: The nested synchronized objects has a different sequence than the nested synchronized objects on the line 5 of the file '${src}/main.cj', which may cause a deadlock.`));
test('serial-direct-body',fixture('serial-flow-direct-type-positive'),'json',one("G.SER.03: Type mismatch: type 'Struct-String' is deserialized in line 6, but in function 'serialize()', return type is 'Int64'(line 5)."));
const reverse=fixture('serial-flow-direct-type-positive');reverse.source=reverse.source.replace('let value: Int64','let value: String').replace('init(v: Int64)','init(v: String)').replace('String.deserialize(dm)','Int64.deserialize(dm)').replace('Box(0)','Box(\"\")');
test('serial-reverse-body',reverse,'csv',one("G.SER.03: Type mismatch: type 'Int64' is deserialized in line 6, but in function 'serialize()', return type is 'Struct-String'(line 5)."));
const embedded=fixture('serial-flow-key-positive');embedded.source=embedded.source.replaceAll('"missing"','"other%s%d"');
test('argument-placeholder-body',embedded,'json',one("G.SER.03: Type mismatch: the deserialize type of 'other%s%d' is 'Int64'(line 6), but in function 'serialize()', 'other%s%d' is not serialized."));
for(const name of ['shadow-global-control','lock-order-control','serial-flow-control','serialize-data-control'])test(name,fixture(name),'json',rows=>assert.equal(rows.length,0,'independent legal control'));
const all={rules:['G.SYN.01','G.VAR.03','G.FMT.13','G.VAR.02','G.VAR.01'],source:'package example\nvar value = 1\nfunc api(): Int64 { value }\n'};
const ordered=["G.FMT.13: The file header comments should contain the copyright information.","G.VAR.01: Prefer immutable variables when the value of the variable 'value' does not change.","G.VAR.02: Prefer variable 'value' to follow the principle of minimizing scope.","G.VAR.03: Avoid declaring global variable 'value'.","G.SYN.01: The syntax 'global variable' is disabled in this project."];
const duplicate=fixture('serialize-data-positive');duplicate.source=duplicate.source.replace('"password"','"password passwd"');
const suppressed=structuredClone(duplicate);suppressed.source=suppressed.source.replace('.serialize() }','.serialize() } // cjlint-ignore !G.SER.01');
const multi={rule:'G.SER.01',files:{'a.cj':'func one(): Unit { "password passwd".serialize() }\n','z.cj':'func two(): Unit { "password passwd".serialize() }\n','extension.cj':'extend String { public func serialize(): Unit {} }\n'}};
const scanned={rules:['G.OTH.02','G.FMT.13'],files:{'a.cj':'// secret\nfunc first(): Unit {}\n','z.cj':'// secret\nfunc second(): Unit {}\n'},config:{'structural_rule_G_OTH_02.json':{RegexSet:['secret'],SenInfoName:[],WeakPasscode:[]}}};
for(const format of ['json','csv','console']){
 test('position-order-'+format,all,format,rows=>{assert.deepEqual(rows.map(r=>r.line),[1,2,2,2,2],'raw position order');assert.deepEqual(rows.map(r=>r.description),ordered,'same-position distinct bodies retained in reference insertion order');});
 test('duplicate-'+format,duplicate,format,one("G.SER.01: Serialize unencrypted sensitive data 'password passwd' may cause information leak"));
 test('suppressed-'+format,suppressed,format,rows=>assert.equal(rows.length,0,'suppression before final normalization'));
 test('cross-file-'+format,multi,format,(rows,src)=>{assert.equal(rows.length,2,'deduplicate within, not across, files');assert.deepEqual(rows.map(r=>r.file),[src+'/a.cj',src+'/z.cj'],'source file order and identity');assert.ok(rows.every(r=>r.description==="G.SER.01: Serialize unencrypted sensitive data 'password passwd' may cause information leak"));});
 test('text-and-ast-files-'+format,scanned,format,(rows,src)=>{assert.deepEqual(rows.map(r=>[r.file,r.line,r.column]),[[src+'/a.cj',1,1],[src+'/a.cj',1,4],[src+'/z.cj',1,1],[src+'/z.cj',1,4]],'real source identity shared by text and AST diagnostics');});
}
assert.ok(assertions.length>0,'known report case');
console.log(JSON.stringify({commands:commands.length,passed:assertions.filter(x=>x.pass).length,failed:assertions.filter(x=>!x.pass).length}));process.exitCode=assertions.some(x=>!x.pass)?1:0;
