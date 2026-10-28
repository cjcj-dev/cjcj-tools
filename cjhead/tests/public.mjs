#!/usr/bin/env zx
import {$} from 'zx';
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {createHash} from 'node:crypto';
const here=path.dirname(fileURLToPath(import.meta.url));
const args=process.argv.slice(process.argv.findIndex(arg=>path.resolve(arg)===fileURLToPath(import.meta.url))+1);
const {values:v}=parseArgs({args,options:{binary:{type:'string'},evidence:{type:'string'},only:{type:'string'}}});
if(!v.binary||!v.evidence)throw Error('--binary and --evidence required');
const binary=path.resolve(v.binary), evidence=path.resolve(v.evidence), fixture=path.join(here,'fixtures');
await fs.mkdir(evidence,{recursive:true});
await fs.writeFile(path.join(evidence,'binary.json'),JSON.stringify({binary,sha256:createHash('sha256').update(await fs.readFile(binary)).digest('hex')}));
const records=[];
const invoke=async(name,argv,{cwd=evidence,env=process.env}={})=>{
 const p=await $({cwd,env,nothrow:true,quiet:true})`${binary} ${argv}`;
 const row={name,argv:[binary,...argv],cwd,rc:p.exitCode,signal:p.signal??null};records.push(row);
 await fs.writeFile(path.join(evidence,name+'.stdout'),p.stdout);
 await fs.writeFile(path.join(evidence,name+'.stderr'),p.stderr);
 await fs.writeFile(path.join(evidence,'commands.json'),JSON.stringify(records,null,2));
 return p;
};
const text=async(dir,name)=>fs.readFile(path.join(dir,name),'utf8');
const ok=p=>assert.equal(p.exitCode,0,p.stdout+p.stderr);
const absent=(s,...names)=>{for(const n of names)assert.ok(!s.includes(n),'Unexpected exported content: '+n);};
const tests={
 async help(){ok(await invoke('help',['-h']));ok(await invoke('no-args',[]));},
 async smoke(){
  const out=path.join(evidence,'smoke');await fs.mkdir(out);
  ok(await invoke('smoke',['-i',path.join(fixture,'smoke'),'-o',out]));
  const s=await text(out,'api.cj.d');assert.ok(s.includes('public func visible(): Int64'),'public declaration reached output');
  absent(s,'hidden','1234567','7654321');assert.ok(s.includes('Visible documentation'),'declaration comment retained');
 },
 async visibility(){
  const out=path.join(evidence,'api');await fs.mkdir(out);
  ok(await invoke('visibility',['-i',path.join(fixture,'api'),'-o',out]));
  const s=await text(out,'types.cj.d');
  for(const n of ['class Base','protected let inherited','protected func inheritedCall','class Closed','visibleClosed','class Box<T>','struct Pair','enum Choice','Second(Int64)','interface API','prop count','func fallback','type Alias','let constant'])assert.ok(s.includes(n),'Missing '+n);
  assert.ok(s.includes('public func get(): T'),'public method named get remains exported');
  absent(s,'secret','hidden','closedSecret','InternalType','PrivateType','1234567','567891','778899','111222','get() {');
  const ext=await text(out,'extend.cj.d');assert.ok(ext.includes('func extra'));assert.ok(ext.includes('inheritedExtra'));absent(ext,'privateExtension','hiddenExtra','654321','777888');
 },
 async package(){
  const out=path.join(evidence,'package');
  ok(await invoke('package',['-i',path.join(fixture,'api'),'-o',out,'-p']));
  const s=await text(out,'api.cj.d');assert.equal((s.match(/package api/g)||[]).length,1);assert.ok(s.includes('func extra'));assert.ok(s.includes('class Base'));
 },
 async single(){
  const out=path.join(evidence,'single');await fs.mkdir(out);
  ok(await invoke('single',['-i',path.join(fixture,'api','skip.cj'),'-o',out]));
  assert.deepEqual(await fs.readdir(out),['skip.cj.d']);
  const direct=path.join(evidence,'direct.cj.d');ok(await invoke('single-output-file',['-i',path.join(fixture,'api','skip.cj'),'-o',direct]));assert.ok((await fs.readFile(direct,'utf8')).includes('excluded'));
 },
 async defaults(){
  const out=path.join(evidence,'defaults');await fs.mkdir(out);
  ok(await invoke('default-output',['-i',path.join(fixture,'smoke')],{cwd:out}));assert.ok((await text(out,'api.cj.d')).includes('visible'));
 },
 async exclusion(){
  const conf=path.join(evidence,'exclude.txt');await fs.writeFile(conf,'[invalid\n^skip\\.cj$\n');
  const out=path.join(evidence,'exclude');await fs.mkdir(out);
  ok(await invoke('exclusion',['-i',path.join(fixture,'api'),'-o',out,'--exclude',conf]));
  assert.ok(!(await fs.readdir(out)).includes('skip.cj.d'));assert.ok((await fs.readdir(out)).includes('types.cj.d'));
 },
 async recursive(){
  const out=path.join(evidence,'nested');await fs.mkdir(out);
  ok(await invoke('recursive',['-i',path.join(fixture,'nested','root'),'-o',out]));
  assert.ok((await text(out,'root.cj.d')).includes('func root'));assert.ok((await text(out,'child/child.cj.d')).includes('func child'));
 },
 async annotations(){
  const out=path.join(evidence,'annotations output');await fs.mkdir(out);
  ok(await invoke('annotations',['-i',path.join(fixture,'annotations'),'-o',out]));
  const s=await text(out,'api.cj.d');assert.ok(s.includes('@Deprecated'));assert.ok(s.includes('Keep { braces } and text intact'));assert.ok(s.includes('Declaration documentation'));assert.ok(s.includes('value!: String = "{text}"'));absent(s,'body-is-not-api');
 },
 async features(){
  const out=path.join(evidence,'features');
  ok(await invoke('features',['-i',path.join(fixture,'features'),'-o',out]));
  const s=await text(out,'api.cj.d');
  for(const n of ['File documentation','sealed interface Restricted','public Primary(public let value: Int64)','where T <: Marker','func bounded','func identity<T>'])assert.ok(s.includes(n),'Missing '+n);
  const extension=s.match(/^extend<T> Generic<T>[^\n]*\{\n[\s\S]*?^}/m)?.[0];
  assert.equal(extension,'extend<T> Generic<T> where T <: Marker {\n    public func bounded(value: T): T\n}','R3 explicit where must remain on the Generic extension itself');
  const additional=s.match(/^extend<T> Carrier<T>[^\n]*\{\n[\s\S]*?^}/m)?.[0];
  assert.equal(additional,'extend<T> Carrier<T> where T <: Marker & Extra {\n    public func extraBound(value: T): T\n}','extension-only additional bound must remain on Carrier');
  absent(s,'unexported','678678','{ value }');
  assert.ok(s.includes(process.platform==='win32'?'func windowsOnly':'func unixOnly'));
  absent(s,process.platform==='win32'?'func unixOnly':'func windowsOnly','789789');
 },
 async packages(){
  const implicit=path.join(evidence,'implicit-package');
  ok(await invoke('implicit-package',['-i',path.join(fixture,'implicit'),'-o',implicit]));
  const s=await text(implicit,'api.cj.d');assert.ok(s.includes('package default'));assert.ok(s.includes('func implicitPackage'));absent(s,'888777');
  for(const kind of ['internal','private']){
   const out=path.join(evidence,kind+'-package');
   const p=await invoke(kind+'-package',['-i',path.join(fixture,kind+'-package'),'-o',out]);
   if(kind==='private'){
    assert.notEqual(p.exitCode,0,'private package is invalid Cangjie');await assert.rejects(fs.stat(path.join(out,'api.cj.d')));
   }else{ok(p);absent(await text(out,'api.cj.d'),'public class Hidden');}
  }
 },
 async copyright(){
  const resource=path.join(path.dirname(binary),'resources','COPYRIGHT.txt');
  let original=null;try{original=await fs.readFile(resource);}catch(e){if(e.code!=='ENOENT')throw e;}
  await fs.mkdir(path.dirname(resource),{recursive:true});
  try{
   await fs.writeFile(resource,'// Distribution copyright control');
   const out=path.join(evidence,'copyright');
   ok(await invoke('copyright',['-i',path.join(fixture,'smoke'),'-o',out]));
   assert.ok((await text(out,'api.cj.d')).startsWith('// Distribution copyright control\n'));
   await fs.writeFile(resource,'  \n');
   const blank=path.join(evidence,'blank-copyright');
   ok(await invoke('blank-copyright',['-i',path.join(fixture,'smoke'),'-o',blank]));
   assert.ok((await text(blank,'api.cj.d')).startsWith('package smoke'));
  }finally{if(original===null)await fs.unlink(resource);else await fs.writeFile(resource,original);}
 },
 async errors(){
  for(const [name,argv] of [['unknown',['--invalid']],['missing-value',['-i']],['missing-input',['-p']],['bad-path',['-i',path.join(evidence,'missing')]],['syntax',['-i',path.join(fixture,'syntax'),'-o',path.join(evidence,'syntax')]],['semantic',['-i',path.join(fixture,'invalid'),'-o',path.join(evidence,'invalid')]]]){
   const p=await invoke(name,argv);assert.notEqual(p.exitCode,0,name+' must reject');
  }
  const env={...process.env};delete env.CANGJIE_HOME;assert.notEqual((await invoke('missing-home',['-i',path.join(fixture,'smoke')],{env})).exitCode,0);
  await assert.rejects(fs.stat(path.join(evidence,'invalid','bad.cj.d')));
  const blocked=path.join(evidence,'blocked');await fs.writeFile(blocked,'not a directory');
  assert.notEqual((await invoke('output-error',['-i',path.join(fixture,'smoke'),'-o',path.join(blocked,'out')])).exitCode,0);
  const atomic=path.join(evidence,'atomic-input');await fs.mkdir(path.join(atomic,'bad'),{recursive:true});
  await fs.copyFile(path.join(fixture,'smoke/api.cj'),path.join(atomic,'api.cj'));
  await fs.writeFile(path.join(atomic,'bad/bad.cj'),'package smoke.bad\npublic func invalid(): Int64 { "wrong type" }\n');
  const atomicOut=path.join(evidence,'atomic-output');
  assert.notEqual((await invoke('atomic-semantic-error',['-i',atomic,'-o',atomicOut])).exitCode,0);
  await assert.rejects(fs.stat(path.join(atomicOut,'api.cj.d')));
 }
};
let failure=null;
for(const [name,run] of Object.entries(tests)){
 if(v.only&&v.only!==name)continue;
 try{await run();console.log('PASS '+name);}catch(e){failure={name,error:e.stack};console.log('FAIL '+name+': '+e.message);break;}
}
await fs.writeFile(path.join(evidence,'result.json'),JSON.stringify({failure,commands:records.length},null,2));
if(failure)process.exitCode=1;
