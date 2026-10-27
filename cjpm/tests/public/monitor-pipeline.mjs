#!/usr/bin/env zx
// Real installed CJPM -> real selected CJC -> file publication -> Monitor.
// A successful build alone is insufficient: task completion also wakes Monitor.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const [exeArg,workArg,mode='normal']=process.argv.slice(2);
assert(exeArg&&workArg&&['normal','control'].includes(mode),'monitor-pipeline.mjs <cjpm> <fresh-work> [normal|control]');
const exe=path.resolve(exeArg),work=path.resolve(workArg),project=work+'/project';
assert(!fs.existsSync(work),'retain prior evidence; use fresh work');fs.mkdirSync(work,{recursive:true});
const commands=[],checks=[];let fatal=null;
function save(){fs.writeFileSync(work+'/results.json',JSON.stringify({exe,mode,commands,checks,fatal},null,2));}
function check(name,fn){try{fn();checks.push({name,pass:true});}catch(e){checks.push({name,pass:false,error:e.stack});throw e;}finally{save();}}
function run(name,argv,cwd=project){const started=new Date().toISOString(),o=fs.openSync(work+'/'+name+'.stdout','wx'),e=fs.openSync(work+'/'+name+'.stderr','wx');const p=spawnSync(argv[0],argv.slice(1),{cwd,env:{...process.env,CJPM_WAIT_DEPS_DIAG:'1',CJPM_JOBSERVER:'1',CJPM_JOBSERVER_TRACE:'1'},stdio:['ignore',o,e]});fs.closeSync(o);fs.closeSync(e);commands.push({name,argv,cwd,started,ended:new Date().toISOString(),rc:p.status,signal:p.signal,error:p.error?.message??null});save();return p;}
function write(p,t){fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,t);}
function walk(p){return fs.readdirSync(p,{withFileTypes:true}).flatMap(e=>e.isDirectory()?walk(path.join(p,e.name)):[path.join(p,e.name)]);}
function traceFacts(raw){
 const roles=new Map(),pending=new Map(),events=[],compilers=[];
 for(const line of raw.split('\n')){
  const m=/^\s*(\d+)\s+([\d.]+)\s+(.*)$/.exec(line);if(!m)continue;
  const pid=Number(m[1]),at=Number(m[2]);let call=m[3];
  if(call.endsWith('<unfinished ...>')){pending.set(pid,call.slice(0,-'<unfinished ...>'.length));continue;}
  if(call.startsWith('<... ')){const r=/^<\.\.\. \w+ resumed>(.*)$/.exec(call);if(!r)continue;assert(pending.has(pid),'matching resumed syscall');call=pending.get(pid)+r[1];pending.delete(pid);}
  const child=/^(?:clone3?|fork|vfork)\(.*\)\s+= (\d+)\s*$/.exec(call);if(child&&!roles.has(Number(child[1])))roles.set(Number(child[1]),roles.get(pid));
  const exec=/^execve\("([^"]+)".*\)\s+= 0$/.exec(call);
  if(exec){if(path.resolve(exec[1])===exe)roles.set(pid,'cjpm');else if(path.basename(exec[1])==='cjc'){roles.set(pid,'cjc');compilers.push({pid,at,call});}}
  const file=/"([^"\n]+\.cjo\.flag)"/.exec(call);if(!file)continue;
  const result=/=\s+(\d+)\s*$/.exec(call);if(!result)continue;
  const kind= /^open(?:at)?\(/.test(call)&&call.includes('O_CREAT')?'create':/^unlink(?:at)?\(/.test(call)?'remove':/^(?:access|faccessat2?|newfstatat|stat|statx|lstat)\(/.test(call)?'observe':null;
  if(kind)events.push({pid,at,role:roles.get(pid)??'unknown',file:file[1],kind,result:Number(result[1]),call});
 }
 return {events,compilers};
}
try{
 write(project+'/cjpm.toml','[package]\nname = "monitorcase"\nversion = "1.0.0"\ncjc-version = "1.0.0"\noutput-type = "executable"\n'+(mode==='normal'?'[package.package-configuration."monitorcase.leaf"]\noutput-type = "static"\n':'')+'[profile]\nexperimental = true\n[profile.build]\nincremental = true\ncompile-pipeline-parallel = true\n');
 write(project+'/src/main.cj','package monitorcase\n'+(mode==='normal'?'import monitorcase.leaf.*\n':'')+'main(): Int64 { let value = '+(mode==='normal'?'answer()':'42')+'; println("MONITOR_PROGRAM_TARGET ${value}"); return if (value == 42) { 0 } else { 41 } }\n');
 if(mode==='normal')write(project+'/src/leaf/value.cj','package monitorcase.leaf\npublic func answer(): Int64 { 42 }\n');
 const trace=work+'/build.execve-files';
 const p=run('build',['strace','-f','-ttt','-s','4096','-e','trace=%file,clone,clone3,fork,vfork,exit_group','-o',trace,exe,'build','-V','-j','2']);
 check('real-build-exit',()=>{assert.equal(p.status,0);assert.equal(p.signal,null);assert.equal(p.error,undefined);});
 const facts=traceFacts(fs.readFileSync(trace,'utf8'));fs.writeFileSync(work+'/publication.json',JSON.stringify(facts,null,2));
 check('real-compiler-executed',()=>assert(facts.compilers.length>0));
 const logs=fs.readFileSync(work+'/build.stdout','utf8')+fs.readFileSync(work+'/build.stderr','utf8');
 if(mode==='normal'){
  check('real-monitor-registered',()=>assert.match(logs,/id=monitor~monitorcase\.leaf\|/));
  check('real-monitor-notified',()=>assert.match(logs,/\[Monitor\] received 'FoundCjoFile' notification for .*monitorcase\.leaf\.cjo/));
  const publications=facts.events.filter(e=>e.role==='cjc'&&e.kind==='create'&&e.file.endsWith('/monitorcase.leaf.cjo.flag'));
  check('real-compiler-flag-publication',()=>assert(publications.length>0));
  // Deliberately distinguish the watcher path from compiler-exit fallback.
  // Preserve a target failure if only the latter made this build succeed.
  check('WATCHER_OBSERVED_REAL_CJC_FLAG',()=>assert(publications.some(c=>facts.events.some(o=>o.role==='cjpm'&&o.kind==='observe'&&o.result===0&&o.file===c.file&&o.at>=c.at&&!facts.events.some(r=>r.role==='cjc'&&r.kind==='remove'&&r.file===c.file&&r.at>=c.at&&r.at<o.at))),'real CJC publication was not observed by CJPM before compiler removed it'));
 }else check('independent-empty-monitor-control',()=>assert(!logs.includes('id=monitor~')));
 const binary=project+'/target/release/bin/main',ran=run('program',[binary]);check('program-value',()=>{assert.equal(ran.status,0);assert.match(fs.readFileSync(work+'/program.stdout','utf8'),/MONITOR_PROGRAM_TARGET 42/);});
 const cached=run('cached-build',[exe,'build','-V','-j','2']);check('real-cache',()=>{assert.equal(cached.status,0);assert(!fs.readFileSync(work+'/cached-build.stdout','utf8').includes('Compiling package'));});
 const files=walk(project+'/target');check('watcher-joined-and-cleaned',()=>assert(!files.some(p=>p.endsWith('.cjo.flag'))));
}catch(e){fatal=e.stack;console.error(fatal);process.exitCode=1;}finally{save();}
