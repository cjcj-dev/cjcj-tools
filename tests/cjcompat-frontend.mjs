#!/usr/bin/env zx
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const root=fs.mkdtempSync(path.join(process.env.RELEASE_EVIDENCE_TEST_ROOT??os.tmpdir(),'cjcompat-frontend-'));
const producer=new URL('../packages/cjcompat/build/build.mjs',import.meta.url).pathname;
const source=path.join(root,'compiler'),sdk=path.join(root,'sdk'),libs=path.join(root,'libs'),commands=[];
fs.mkdirSync(source);fs.mkdirSync(path.join(sdk,'bin'),{recursive:true});fs.mkdirSync(libs);
fs.writeFileSync(path.join(source,'fixed.cj'),'package fixed\n');
function run(label,argv,options={}){
 const p=spawnSync(argv[0],argv.slice(1),{encoding:'utf8',...options});
 commands.push({label,argv,rc:p.status,signal:p.signal,error:p.error?.message??null});
 fs.writeFileSync(path.join(root,label+'.stdout'),p.stdout??'');fs.writeFileSync(path.join(root,label+'.stderr'),p.stderr??'');
 fs.writeFileSync(path.join(root,'commands.json'),JSON.stringify(commands,null,2));return p;
}
for(const argv of [['git','init',source],['git','-C',source,'add','.'],['git','-C',source,'-c','user.name=Zxilly','-c','user.email=zxilly@outlook.com','commit','-m','test: fixed frontend']])assert.equal(run('git-'+commands.length,argv).status,0);
const sha=run('revision',['git','-C',source,'rev-parse','HEAD']).stdout.trim();
const marker=path.join(root,'compiler-reached.json');
fs.writeFileSync(path.join(sdk,'bin/cjc'),'#!/usr/bin/env node\nimport fs from "node:fs";fs.writeFileSync(process.env.CJCOMPAT_FRONTEND_TEST_MARKER,JSON.stringify(process.argv));process.exit(73);\n',{mode:0o755});
// The controlled compiler exits before reading CJO/object inputs.
fs.renameSync(path.join(sdk,'bin/cjc'),path.join(sdk,'bin/cjc.mjs'));
fs.symlinkSync('cjc.mjs',path.join(sdk,'bin/cjc'));
function build(label,ref){
 fs.rmSync(marker,{force:true});
 const p=run(label,[process.execPath,producer,'build','--sdk',sdk,'--compiler-source',source,'--compiler-libs',libs,'--shim',root+'/shim.o','--llvm',root+'/libLLVM.so','--build-dir',root+'/'+label,...(ref===undefined?[]:['--frontend-ref',ref])],{env:{...process.env,CJCOMPAT_FRONTEND_TEST_MARKER:marker}});
 return {p,reached:fs.existsSync(marker)};
}
const checks=[];
function check(label,fn){try{fn();checks.push({label,executed:true,pass:true});}catch(error){checks.push({label,executed:true,pass:false,error:error.message});}fs.writeFileSync(root+'/checks.json',JSON.stringify(checks,null,2));}
const good=build('explicit-match',sha);check('explicit matching source reaches compiler',()=>{assert.equal(good.p.status,73);assert(good.reached,'matching real Git source reaches compiler');const facts=JSON.parse(fs.readFileSync(root+'/explicit-match/inputs.json'));assert.equal(facts.compilerRevision,sha);});
for(const [label,ref]of [['mismatch','0'.repeat(40)],['short',sha.slice(0,7)],['default',undefined]]){
 const r=build(label,ref);check(label,()=>{assert.equal(r.p.status,1);assert(!r.reached,'source rejection must precede compiler');assert.match(r.p.stderr,label==='short'?/full source commit/:/compiler source must be fixed/);});
}
fs.renameSync(source+'/.git',source+'/.git-held');
try{const r=build('archive-is-not-git',sha);check('archive rejection',()=>{assert.equal(r.p.status,1);assert(!r.reached);assert.match(r.p.stderr,/compiler source must be fixed/);});}finally{fs.renameSync(source+'/.git-held',source+'/.git');}
const restored=build('restored-match',sha);check('restored matching source reaches compiler',()=>{assert.equal(restored.p.status,73);assert(restored.reached);});
assert(checks.every(row=>row.pass),JSON.stringify(checks.filter(row=>!row.pass)));
console.log('CJCOMPAT_FIXED_SOURCE_MATCH_REJECT_RESTORE_PASS '+root);
