#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {parseArgs} from 'node:util';
import {fileURLToPath} from 'node:url';
const {values:v}=parseArgs({options:{'build-dir':{type:'string'},prefix:{type:'string'},work:{type:'string'}}});
for(const key of ['build-dir','prefix','work'])assert.ok(v[key],`--${key} required`);
const source=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const build=path.resolve(v['build-dir']),prefix=path.resolve(v.prefix),work=path.resolve(v.work);
fs.mkdirSync(work,{recursive:false});
const commands=[],products=[];
function run(name,args,expected=0){
  const out=fs.openSync(path.join(work,name+'.stdout'),'w'),err=fs.openSync(path.join(work,name+'.stderr'),'w');
  const r=spawnSync(args[0],args.slice(1),{cwd:work,stdio:['ignore',out,err]});fs.closeSync(out);fs.closeSync(err);
  commands.push({name,args,cwd:work,rc:r.status,signal:r.signal,error:r.error?.message??null});
  fs.writeFileSync(path.join(work,'commands.json'),JSON.stringify(commands,null,2)+'\n');
  console.log(name+' rc='+r.status);assert.equal(r.status,expected,name);
}
function capture(label){
  const metadata=JSON.parse(fs.readFileSync(path.join(build,'cangjie/product.json'),'utf8'));
  const same=products.find(p=>p.sha256===metadata.sha256);
  const elf=same?.elf??path.join(work,label+'.elf');
  if(!same)fs.copyFileSync(metadata.executable,elf);
  products.push({label,...metadata,elf});fs.writeFileSync(path.join(work,'products.json'),JSON.stringify(products,null,2)+'\n');
}
function buildInstall(label){
  run(label+'-build',['cmake','--build',build,'--parallel','4']);capture(label);
  run(label+'-install',['cmake','--install',build,'--prefix',prefix]);
}
function test(name,selected,expected=0){
  run(name,[process.execPath,path.join(source,'cangjie/product-test.mjs'),'--prefix',prefix,'--work',path.join(work,name),'--case',selected],expected);
}
capture('candidate');test('candidate-target','immutable-local-positive');
const file=path.join(source,'cangjie/src/DataflowRules.cj'),before=fs.readFileSync(file,'utf8');
const from='if (selected.contains("G.VAR.01")) { ImmutableCheck(findings, source).run(pkg) }';
const to='if (selected.contains("G.VAR.01")) { () }';
assert.equal(before.split(from).length,2,'one real CHIR consumer dispatch');
const line=before.slice(0,before.indexOf(from)).split('\n').length;
fs.writeFileSync(path.join(work,'cut.diff'),`--- a/cjlint/cangjie/src/DataflowRules.cj\n+++ b/cjlint/cangjie/src/DataflowRules.cj\n@@ -${line},1 +${line},1 @@\n-    ${from}\n+    ${to}\n`);
let failure;
try{
  fs.writeFileSync(file,before.replace(from,to));buildInstall('cut');
  test('cut-target','immutable-local-positive',1);
  const actual=JSON.parse(fs.readFileSync(path.join(work,'cut-target/commands.json'),'utf8'));
  assert.equal(actual.length,1);assert.equal(actual[0].rc,0,'product ran; no earlier failure');
  const assertions=JSON.parse(fs.readFileSync(path.join(work,'cut-target/assertions.json'),'utf8'));
  assert.equal(assertions[0].pass,false);assert.ok(assertions[0].error.includes('target rule diagnostics'),'target assertion executed');
  test('cut-immutable-control','immutable-let-control');
  test('cut-independent-chir','spawn-mutex-global-positive');
  test('cut-sema-error-control','interface-mutation-positive');
}catch(e){failure=e;}
finally{
  fs.writeFileSync(file,before);assert.equal(fs.readFileSync(file,'utf8'),before);
  fs.writeFileSync(path.join(work,'source-restored.json'),JSON.stringify({file,restored:true})+'\n');
  buildInstall('restored');
  test('restored-target','immutable-local-positive');
  test('restored-independent-chir','spawn-mutex-global-positive');
  test('restored-sema-error-control','interface-mutation-positive');
}
if(failure)throw failure;
fs.writeFileSync(path.join(work,'result.json'),JSON.stringify({pass:true,scope:'new G.VAR.01 real CHIR consumer dispatch; independent CHIR and SEMA controls',commands:commands.length},null,2)+'\n');
