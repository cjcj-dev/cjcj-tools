#!/usr/bin/env zx
import fs from 'node:fs';import path from 'node:path';import assert from 'node:assert/strict';import {spawnSync} from 'node:child_process';
const [exe,work,P,mode='normal']=process.argv.slice(2);assert(exe&&work&&P);assert(!fs.existsSync(work));fs.mkdirSync(work,{recursive:true});
const project=work+'/project',database=project+'/compile_commands.json',rows=[],checks=[];
function write(p,s){fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,s);}
function run(name,args){const started=new Date().toISOString(),o=fs.openSync(work+'/'+name+'.stdout','wx'),e=fs.openSync(work+'/'+name+'.stderr','wx'),r=spawnSync(exe,args,{cwd:project,env:process.env,stdio:['ignore',o,e],timeout:180000});fs.closeSync(o);fs.closeSync(e);rows.push({name,argv:[exe,...args],cwd:project,started,ended:new Date().toISOString(),rc:r.status,signal:r.signal,error:r.error?.message??null});fs.writeFileSync(work+'/commands.json',JSON.stringify(rows,null,2));assert.equal(r.status,0,name);assert.equal(r.signal,null);return fs.readFileSync(work+'/'+name+'.stdout','utf8');}
let error=null;try{
write(project+'/cjpm.toml','[workspace]\nmembers = ["app", "control"]\n');
function pkg(dir,name,body,deps=''){
 write(project+'/'+dir+'/cjpm.toml','[package]\nname = "'+name+'"\nversion = "1.0.0"\ncjc-version = "1.1.0"\noutput-type = "static"\nsrc-dir = "source-code"\ncompile-option = '+JSON.stringify('--import-path='+P+'/modules/linux_x86_64_cjnative')+'\n'+deps);
 write(project+'/'+dir+'/source-code/value.cj',body);
}
pkg('leaf','project_leaf','package project_leaf\npublic func diskAnswer(): Int64 { return 42 }\n');
pkg('helper','project_helper','package project_helper\nimport project_leaf.*\npublic func forwarded(): Int64 { return diskAnswer() }\n','[dependencies]\nproject_leaf = {path = "../leaf"}\n');
pkg('app','project_app','package project_app\nimport project_helper.*\nimport lsp_leaf.*\npublic func use(): Int64 { return forwarded() + answer() }\n','[dependencies]\nproject_helper = {path = "../helper"}\n[target.x86_64-unknown-linux-gnu.bin-dependencies]\npath-option = ['+JSON.stringify(P+'/modules/linux_x86_64_cjnative')+']\n');
pkg('control','project_control','package project_control\npublic func independent(): Int64 { return 7 }\n');
write(project+'/ignored/value.cj','package project_leaf\npublic func diskAnswer(): Bool { return true }\n');
const args=['build','-V','-j','2','--target-dir',project+'/selected-target','--export-compile-commands',database];
run('first',args);
const first=fs.readFileSync(database,'utf8'),entries=JSON.parse(first);assert.equal(entries.length,4);assert(entries.every(e=>e.file.includes('/source-code/')&&!e.file.includes('/ignored/')));assert(entries.some(e=>e.arguments.some(a=>a.includes('/modules/linux_x86_64_cjnative'))));assert(entries.every(e=>e.arguments.includes('-p')));fs.writeFileSync(work+'/first-compilation-database.json',first);
checks.push('selected-workspace-path-transitive-bin-source-target');
const cached=run('cache',args);assert(!cached.includes('Compiling package'),'actual cache must not compile');assert.equal(fs.readFileSync(database,'utf8'),first,'same complete selected graph on cache');checks.push('cache-exact-graph');
fs.writeFileSync(work+'/project.json',JSON.stringify({project,database,P,entries},null,2));
}catch(e){error=e.stack;console.error(error);process.exitCode=1;}finally{fs.writeFileSync(work+'/result.json',JSON.stringify({rows,checks,error},null,2));}
