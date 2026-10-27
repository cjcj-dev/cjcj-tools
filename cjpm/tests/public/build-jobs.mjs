#!/usr/bin/env zx
// Linux integration gate: public build.py -> build.mjs -> real selected CJC.
// No replacement compiler or native producer. Keep the raw execve trace.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const [sourceArg,outputArg,arm='green']=process.argv.slice(2);
assert(sourceArg&&outputArg,'usage: build-jobs.mjs <cjpm-source> <evidence> [green|cut-*|restore]');
const source=path.resolve(sourceArg),output=path.resolve(outputArg),src=path.join(source,'src');
fs.mkdirSync(output,{recursive:true});
assert(!fs.existsSync(output+'/results.json')&&!fs.existsSync(output+'/commands.json'),'use fresh evidence; retain prior attempts');
const records=[],checks=[],affinity=os.availableParallelism();
// Derive expected production units and internal edges from the actual selected
// source, independently of the build script's package array or a call count.
const packages=new Map();
for(const entry of fs.readdirSync(src,{withFileTypes:true}).filter(x=>x.isDirectory())) {
 const directory=path.join(src,entry.name);
 const files=fs.readdirSync(directory).filter(n=>n.endsWith('.cj')&&!n.endsWith('_test.cj'));
 if(!files.length)continue;
 const text=files.map(n=>fs.readFileSync(path.join(directory,n),'utf8')).join('\n');
 const declarations=[...text.matchAll(/^\s*package\s+(cjpm\.[A-Za-z_][\w]*)\s*$/gm)].map(m=>m[1]);
 assert(declarations.length&&declarations.every(n=>n==='cjpm.'+entry.name),'normal package declaration '+directory);
 const imports=[...text.matchAll(/^\s*import\s+cjpm\.([A-Za-z_][\w]*)[.\s]/gm)].map(m=>m[1]);
 packages.set(entry.name,{directory,package:'cjpm.'+entry.name,imports:[...new Set(imports)].filter(n=>n!==entry.name)});
}
assert(packages.has('watcher'),'selected product must include the Cangjie publication watcher');
for(const unit of packages.values())for(const dependency of unit.imports)assert(packages.has(dependency),'internal dependency '+dependency);
assert.match(fs.readFileSync(src+'/main.cj','utf8'),/^\s*package\s+cjpm\s*$/m);
fs.writeFileSync(output+'/source-graph.json',JSON.stringify({source,packages:[...packages.values()],main:src,affinity},null,2));
function check(name,condition,detail){checks.push({name,passed:Boolean(condition),detail});console.log(`${condition?'PASS':'FAIL'} ${name}`);}
function executions(text){
 const pending=new Map(),result=[];
 for(const line of text.split('\n')) {
  const match=/^\s*(\d+)\s+(.*)$/.exec(line);if(!match)continue;
  const [,pid,body]=match;let call=body;
  if(body.startsWith('execve(')&&body.endsWith('<unfinished ...>')){pending.set(pid,body.slice(0,-'<unfinished ...>'.length));continue;}
  if(body.startsWith('<... execve resumed>')){assert(pending.has(pid),'matching unfinished execve');call=pending.get(pid)+body.slice('<... execve resumed>'.length);pending.delete(pid);}
  if(!call.startsWith('execve(')||!/= 0$/.test(call))continue;
  const decoded=/^execve\(("(?:[^"\\]|\\.)*"), (\[.*\]), .*\)\s+= 0$/.exec(call);
  assert(decoded,'complete execve argv: '+line);
  // Selected source/tool paths and arguments are emitted as JSON-compatible
  // quoted strings. Unexpected/truncated trace syntax is a gate error, never
  // silently dropped from the producer set.
  result.push({pid:Number(pid),exe:JSON.parse(decoded[1]),argv:JSON.parse(decoded[2]),raw:line});
 }
 assert.equal(pending.size,0,'all execve records completed');return result;
}
function run(name,args,extra={}){
 const trace=output+'/'+name+'.execve',stdout=output+'/'+name+'.stdout',stderr=output+'/'+name+'.stderr';
 const env={...process.env,...extra};for(const k of Object.keys(env))if(env[k]===undefined)delete env[k];
 const argv=['strace','-f','-s','65536','-e','trace=execve','-o',trace,'python3',source+'/build/build.py',...args];
 const o=fs.openSync(stdout,'wx'),e=fs.openSync(stderr,'wx'),start=new Date().toISOString();
 const p=spawnSync(argv[0],argv.slice(1),{cwd:source,env,stdio:['ignore',o,e]});fs.closeSync(o);fs.closeSync(e);
 const r={name,argv,cwd:source,start,end:new Date().toISOString(),rc:p.status,signal:p.signal,error:p.error?.message??null,trace,stdout,stderr,
  input:{CANGJIE_HOME:env.CANGJIE_HOME??null,CANGJIE_STDX_PATH:env.CANGJIE_STDX_PATH??null,CANGJIE_BUILD_JOBS:env.CANGJIE_BUILD_JOBS??null,MAKEFLAGS:env.MAKEFLAGS??null}};
 records.push(r);fs.writeFileSync(output+'/commands.json',JSON.stringify(records,null,2));
 assert.equal(p.error,undefined,'tracer/public entry must start');assert(fs.existsSync(trace),'real execve trace');
 r.execs=executions(fs.readFileSync(trace,'utf8'));
 const compiler=env.CANGJIE_HOME?path.resolve(env.CANGJIE_HOME,'bin/cjc'):null;
 r.cjc=r.execs.filter(e=>compiler&&path.resolve(e.exe)===compiler);
 r.otherCompilers=r.execs.filter(e=>['cjc','cjc.exe'].includes(path.basename(e.exe))&&(!compiler||path.resolve(e.exe)!==compiler));
 r.native=r.execs.filter(e=>['make','gmake','mingw32-make','cmake'].includes(path.basename(e.exe)));
 fs.writeFileSync(output+'/commands.json',JSON.stringify(records,null,2));return r;
}
function value(argv,flag){const i=argv.indexOf(flag);return i<0?undefined:argv[i+1];}
function budget(name,args,jobs,extra={},nativeOnly=false){
 const r=run(name,['build','-t','release',...args],extra);
 check(name+':build-exit',r.rc===0&&r.signal===null,{rc:r.rc,signal:r.signal});
 check(name+':retired-native-producer-absent',r.native.length===0,r.native);
 check(name+':selected-compiler-only',r.otherCompilers.length===0,r.otherCompilers);
 if(nativeOnly){check(name+':empty-native-phase',r.cjc.length===0,r.cjc);return r;}
 const expected=[...packages.values()].map(p=>p.directory).concat(src),actual=r.cjc.map(c=>value(c.argv,'-p'));
 check(name+':source-production-set',actual.length===expected.length&&expected.every(p=>actual.filter(a=>a===p).length===1),{expected,actual});
 const outputDir=path.join(source,'build/bin/cjpm');
 for(const unit of packages.values()){
  const calls=r.cjc.filter(c=>value(c.argv,'-p')===unit.directory),call=calls[0],archive='lib'+unit.package+'.a';
  check(name+':package '+unit.package,calls.length===1&&call.argv.includes('--output-type=staticlib')&&value(call.argv,'--output-dir')===outputDir&&value(call.argv,'-o')===archive,{calls});
  check(name+':dependency order '+unit.package,unit.imports.every(dep=>actual.indexOf(packages.get(dep).directory)>=0&&actual.indexOf(packages.get(dep).directory)<actual.indexOf(unit.directory)),unit.imports);
  check(name+':published '+unit.package,fs.statSync(path.join(outputDir,archive),{throwIfNoEntry:false})?.size>0&&fs.statSync(path.join(outputDir,unit.package+'.cjo'),{throwIfNoEntry:false})?.size>0,{archive});
 }
 const main=r.cjc.filter(c=>value(c.argv,'-p')===src),link=main[0]?.argv??[];
 check(name+':main-consumes-all-CJ-packages',main.length===1&&actual.at(-1)===src&&[...packages.values()].every(p=>link.includes('-l'+p.package)),link);
 check(name+':no-retired-watcher-link',r.cjc.every(c=>!c.argv.some(a=>a==='-lfswatcher'||a==='-luv'||a.includes('/cpp/out'))),r.cjc);
 check(name+':cj-budget',r.cjc.length>0&&r.cjc.every(c=>c.argv.filter(a=>/^-j\d+$/.test(a)).join(',')==='-j'+jobs),r.cjc);
 check(name+':main-published',value(link,'-o')==='cjpm'&&fs.statSync(path.join(source,'dist/cjpm'),{throwIfNoEntry:false})?.size>0,link);
 return r;
}
let fatal=null;
try {
 budget('explicit',['--jobs','2','--set-rpath','$ORIGIN/../../runtime/lib/linux_x86_64_cjnative'],Math.min(2,affinity),{CANGJIE_BUILD_JOBS:'1',MAKEFLAGS:'-j1'});
 // Controls also execute after a budget cut. No C++ producer is reintroduced
 // to manufacture a native budget assertion after that graph was retired.
 for(const value of ['0','-1','word','1.5']){
  const r=run('invalid-'+value.replace(/[^a-z0-9]/g,'_'),['build','-t','release','--jobs',value]);
  check('invalid '+value+':argparse',r.rc===2&&/jobs must be a positive integer/.test(fs.readFileSync(r.stderr,'utf8')),{rc:r.rc});
  check('invalid '+value+':no-build',r.native.length===0&&r.cjc.length===0&&r.otherCompilers.length===0,{native:r.native,cjc:r.cjc});
 }
 budget('native-only-control',['--native-only','--jobs','2'],Math.min(2,affinity),{CANGJIE_BUILD_JOBS:'invalid',MAKEFLAGS:'-j1'},true);
 if(!arm.startsWith('cut')&&arm!=='restore'){
  // Default/env/precedence must reach real CJ producers, not the empty phase.
  budget('env-default',[],Math.min(1,affinity),{CANGJIE_BUILD_JOBS:'1',MAKEFLAGS:undefined});
  budget('affinity-default',[],affinity,{CANGJIE_BUILD_JOBS:undefined,MAKEFLAGS:undefined});
  budget('explicit-precedence-clipped',['-j',String(affinity+1)],affinity,{CANGJIE_BUILD_JOBS:'invalid',MAKEFLAGS:'-j1'});
  const envBad=run('invalid-env',['build','-t','release','--native-only'],{CANGJIE_BUILD_JOBS:'0'});
  check('invalid env:argparse',envBad.rc===2&&envBad.native.length===0&&envBad.cjc.length===0&&envBad.otherCompilers.length===0,{rc:envBad.rc});
  const missing=run('missing-sdk',['build','-t','release','--jobs','2'],{CANGJIE_HOME:undefined});
  check('missing SDK:exit propagates',missing.rc===1&&missing.native.length===0&&missing.cjc.length===0&&missing.otherCompilers.length===0,{rc:missing.rc});
 }
}catch(error){fatal=error.stack;console.error(fatal);process.exitCode=1;}
finally{fs.writeFileSync(output+'/results.json',JSON.stringify({arm,checks,passed:checks.filter(x=>x.passed).length,failed:checks.filter(x=>!x.passed).length,fatal,records},null,2));}
if(fatal||checks.some(x=>!x.passed))process.exitCode=1;
