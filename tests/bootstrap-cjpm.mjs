#!/usr/bin/env zx
// Actual build entries with a terminating CJPM fixture: argv/env and failure
// propagation only. Placeholder CJO/archive bytes are never parsed by a compiler.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const source=path.resolve(import.meta.dirname,'..');
const work=fs.mkdtempSync(path.join(process.env.TMPDIR??os.tmpdir(),'bootstrap-cjpm-'));
const write=(p,s,mode)=>{fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,s,{mode});};
const target=path.join(work,'target-sdk'),host=path.join(work,'host-sdk'),frontend=path.join(work,'frontend');
for(const sdk of [target,host])write(sdk+'/tools/bin/cjpm',`#!/usr/bin/env node
import fs from 'node:fs';
fs.writeFileSync(process.env.CJPM_TEST_RECORD,JSON.stringify({argv:process.argv,home:process.env.CANGJIE_HOME,path:process.env.PATH,loader:process.env.LD_LIBRARY_PATH,selected:${JSON.stringify(sdk)}}));
process.exit(73);
`,0o755);
for(const name of ['parse','option','ast','lex','utils','basic']){
 write(frontend+'/'+name+'@cjcj.cjo','not a CJO; execution stops at the manager');
 write(frontend+'/lib'+name+'@cjcj.a','not an archive');
}
for(const name of ['runtime.o','shim.o','libLLVM.so'])write(work+'/'+name,'unused fixture');
const sha='1'.repeat(40);
for(const tool of ['cjfmt','cjlint']){
 const root=path.join(work,tool),build=path.join(root,'build');
 for(const file of tool==='cjfmt'?['build/build.mjs','build/cangjie.mjs','build/cjpm.toml.in']:['build/build.mjs','cjpm.toml.in'])write(root+'/'+file,fs.readFileSync(source+'/packages/'+tool+'/'+file));
 write(root+'/src/main.cj','main() { println(42) }');
 const common=tool==='cjfmt'?['--frontend-cjo',frontend,'--frontend-lib',frontend]:[
  '--frontend-source',frontend,'--frontend-ref',sha,'--frontend-artifacts',frontend,
  '--frontend-runtime-object',work+'/runtime.o','--llvm-shim',work+'/shim.o','--llvm-library',work+'/libLLVM.so'];
 for(const explicit of [false,true]){
  const label=explicit?'separate':'default',record=path.join(work,tool+'-'+label+'.json');
  const argv=[build+'/build.mjs','build','--sdk',target,'--build-dir',root+'/out-'+label,...common,...(explicit?['--cjpm-sdk',host]:[])];
  const p=spawnSync(process.execPath,argv,{encoding:'utf8',env:{...process.env,CJPM_TEST_RECORD:record}});
  write(record+'.process.json',JSON.stringify({argv:[process.execPath,...argv],rc:p.status,signal:p.signal,stdout:p.stdout,stderr:p.stderr},null,2));
  assert.equal(p.status,tool==='cjfmt'?73:1,p.stdout+'\n'+p.stderr);
  const row=JSON.parse(fs.readFileSync(record)),selected=explicit?host:target;
  assert.equal(row.selected,selected);assert.equal(row.home,target);
  assert.equal(row.path.split(path.delimiter)[0],target+'/bin');
  assert(row.loader.split(path.delimiter).every(p=>p.startsWith(selected+'/')));
  assert.equal(row.argv[2],'build');
  if(tool==='cjlint')assert.equal(JSON.parse(fs.readFileSync(root+'/out-'+label+'/commands.json'))[0].rc,73);
 }
}
console.log('BOOTSTRAP_CJPM_ENTRY_CONTRACT '+work);
