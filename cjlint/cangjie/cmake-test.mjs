#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
const {values:v}=parseArgs({options:{root:{type:'string'},sdk:{type:'string'},'frontend-ref':{type:'string'},
  'frontend-source':{type:'string'},'frontend-artifacts':{type:'string'},'frontend-runtime-object':{type:'string'},
  'llvm-shim':{type:'string'},'llvm-library':{type:'string'},'analysis-sdk':{type:'string'},work:{type:'string'},rules:{type:'string'},'import-path':{type:'string'}}});
for(const k of ['root','sdk','frontend-ref','frontend-source','frontend-artifacts','frontend-runtime-object','llvm-shim','llvm-library','analysis-sdk','work'])assert.ok(v[k],`--${k} required`);
const root=path.resolve(v.root),source=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const records=path.resolve(root,v.work),build=path.join(records,'build'),prefix=path.join(records,'install');
fs.mkdirSync(records,{recursive:false});
const commands=[];
function run(name,argv,extra={}){
  const out=fs.openSync(path.join(records,name+'.stdout'),'w'),err=fs.openSync(path.join(records,name+'.stderr'),'w');
  const r=spawnSync(argv[0],argv.slice(1),{cwd:root,stdio:['ignore',out,err],...extra});
  fs.closeSync(out);fs.closeSync(err);
  commands.push({name,argv,rc:r.status,signal:r.signal,error:r.error?.message??null});
  fs.writeFileSync(path.join(records,'commands.json'),JSON.stringify(commands,null,2)+'\n');
  console.log(`${name} rc=${r.status}`);assert.equal(r.status,0,`${name} failed`);
}
run('configure',['cmake','-S',source,'-B',build,'-DCMAKE_BUILD_TYPE=Release',
  '-DCANGJIE_HOME='+path.resolve(v.sdk),'-DCJLINT_FRONTEND_SOURCE='+path.resolve(v['frontend-source']),
  '-DCJLINT_FRONTEND_REF='+v['frontend-ref'],'-DCJLINT_FRONTEND_ARTIFACTS='+path.resolve(v['frontend-artifacts']),
  '-DCJLINT_FRONTEND_RUNTIME_OBJECT='+path.resolve(v['frontend-runtime-object']),
  '-DCJLINT_LLVM_SHIM='+path.resolve(v['llvm-shim']),'-DCJLINT_LLVM_LIBRARY='+path.resolve(v['llvm-library']),
  '-DCJLINT_ANALYSIS_SDK='+path.resolve(v['analysis-sdk'])]);
run('build',['cmake','--build',build,'--parallel','4']);
// An unchanged cached build must keep the exact already-produced product.
const metadata=path.join(build,'cangjie/product.json'),before=fs.readFileSync(metadata,'utf8');
run('cached-build',['cmake','--build',build,'--parallel','4']);
assert.equal(fs.readFileSync(metadata,'utf8'),before);
run('install',['cmake','--install',build,'--prefix',prefix]);
const selected=v.rules?['--rules',v.rules]:[];
const imports=v['import-path']?['--import-path',path.resolve(v['import-path'])]:[];
run('functional',[process.execPath,path.join(source,'cangjie/product-test.mjs'),'--prefix',prefix,'--work',path.join(records,'functional'),...selected,...imports]);
run('cli',[process.execPath,path.join(source,'cangjie/product-test.mjs'),'--prefix',prefix,'--work',path.join(records,'cli'),'--cli-only']);
// Existing suppression/exclusion cases are unchanged; the selected business
// cases include SEMA+CHIR error and new CHIR suppression controls.
const destdir=path.join(records,'destdir');
run('destdir-install',['cmake','--install',build,'--prefix','/cjlint'],{env:{...process.env,DESTDIR:destdir}});
run('destdir-functional',[process.execPath,path.join(source,'cangjie/product-test.mjs'),'--prefix',path.join(destdir,'cjlint'),'--work',path.join(records,'destdir-functional'),'--cli-only']);
run('package',['cmake','--build',build,'--target','package','--parallel','4']);
const packages=fs.readdirSync(build).filter(name=>/^cjlint-.*\.tar\.gz$/.test(name));assert.equal(packages.length,1);
const archive=path.join(build,packages[0]),unpack=path.join(records,'fresh');fs.mkdirSync(unpack);
run('unpack',['tar','-xzf',archive,'-C',unpack]);
const fresh=path.join(unpack,packages[0].slice(0,-7));
const hash=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const identity=JSON.parse(before);assert.equal(hash(path.join(fresh,'bin/cjlint')),identity.sha256,'fresh package executable');
run('fresh-functional',[process.execPath,path.join(source,'cangjie/product-test.mjs'),'--prefix',fresh,'--work',path.join(records,'fresh-functional'),...selected,...imports]);
run('fresh-cli',[process.execPath,path.join(source,'cangjie/product-test.mjs'),'--prefix',fresh,'--work',path.join(records,'fresh-cli'),'--cli-only']);
fs.writeFileSync(path.join(records,'result.json'),JSON.stringify({pass:true,scope:'Linux installed host; selected rules and CLI; CMake build/cache/install/DESTDIR/CPack/fresh',
  commands:commands.length,archive,archiveBytes:fs.statSync(archive).size,elf:identity.sha256,target:'NOT_RUN'},null,2)+'\n');
