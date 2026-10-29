#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const [prefix,work]=process.argv.slice(2).map(x=>path.resolve(x));fs.mkdirSync(work,{recursive:true});
const sdk=JSON.parse(fs.readFileSync(path.join(prefix,'build-facts.json'),'utf8')).sdk;
const env={...process.env,CANGJIE_HOME:sdk,LD_LIBRARY_PATH:path.join(sdk,'runtime/lib/linux_x86_64_cjnative')+':'+path.join(sdk,'tools/lib')};
const commands=[],checks=[];function check(name,condition){checks.push({name,executed:true,pass:!!condition});fs.writeFileSync(path.join(work,'assertions.json'),JSON.stringify(checks,null,2));assert.ok(condition,name);}
function run(name,argv,expected=0){const p=spawnSync(argv[0],argv.slice(1),{env,cwd:work,encoding:'utf8',timeout:15000,maxBuffer:8*1024*1024});commands.push({name,argv,rc:p.status,signal:p.signal,error:p.error?.message});fs.writeFileSync(path.join(work,'commands.json'),JSON.stringify(commands,null,2));fs.writeFileSync(path.join(work,name+'.stdout'),p.stdout??'');fs.writeFileSync(path.join(work,name+'.stderr'),p.stderr??'');check(name+' rc',p.status===expected);return p.stdout;}
run('target-build',[path.join(sdk,'bin/cjc'),path.join(root,'tests/CangjieDumpTarget.cj'),'-o',path.join(work,'target')]);
const target=spawn(path.join(work,'target'),[],{cwd:work,env,stdio:['ignore','pipe','pipe']});let stdout='',stderr='';target.stdout.on('data',b=>stdout+=b);target.stderr.on('data',b=>stderr+=b);
const exit=new Promise(resolve=>target.on('exit',(rc,signal)=>resolve({rc,signal})));
try {
 const deadline=Date.now()+5000;while(!stdout.includes('DUMP_TARGET_READY')&&target.exitCode===null&&Date.now()<deadline)await new Promise(r=>setTimeout(r,20));
 check('actual Cangjie target ready',stdout.includes('DUMP_TARGET_READY'));
 fs.writeFileSync(path.join(work,'item_data.dat'),'obsolete-dump-positive-control');
 const out=path.join(work,'live.data');run('dump-explicit',[path.join(prefix,'bin/cjprof'),'heap','--dump',String(target.pid),'--output',out]);
 // Runtime writes the already opened dump descriptor across the atomic move.
 const completeDeadline=Date.now()+5000;let parsed;
 while(Date.now()<completeDeadline){const p=spawnSync(path.join(prefix,'bin/cjprof'),['heap','-i',out,'--json'],{env,cwd:work,encoding:'utf8',timeout:3000,maxBuffer:8*1024*1024});
  commands.push({name:'live-consumer',argv:[path.join(prefix,'bin/cjprof'),'heap','-i',out,'--json'],rc:p.status,signal:p.signal,error:p.error?.message});fs.writeFileSync(path.join(work,'commands.json'),JSON.stringify(commands,null,2));fs.writeFileSync(path.join(work,'live-consumer-'+commands.length+'.stdout'),p.stdout??'');fs.writeFileSync(path.join(work,'live-consumer-'+commands.length+'.stderr'),p.stderr??'');
  if(p.status===0){parsed=JSON.parse(p.stdout);break;}await new Promise(r=>setTimeout(r,100));}
 check('real runtime heap parsed',!!parsed&&parsed.objects.length>0);
 check('real target Payload class consumed',parsed.constructors.some(x=>x.name.includes('Payload')));
 check('old dump replaced and moved',!fs.existsSync(path.join(work,'item_data.dat'))&&fs.readFileSync(out).subarray(0,21).toString().startsWith('CANGJIE PROFILE'));
 run('dump-default',[path.join(prefix,'bin/cjprof'),'heap','-d',String(target.pid)]);
 check('default output created',fs.existsSync(path.join(work,'cjprof.data')));
 run('dump-bad-pid',[path.join(prefix,'bin/cjprof'),'heap','--dump','-1'],1);
 run('dump-missing-pid',[path.join(prefix,'bin/cjprof'),'heap','--dump','2147483647'],1);
 console.log('PASS live dump '+checks.length+' assertions');
} finally {
 if(target.exitCode===null)target.kill('SIGTERM');const result=await exit;commands.push({name:'target',argv:[path.join(work,'target')],...result});fs.writeFileSync(path.join(work,'commands.json'),JSON.stringify(commands,null,2));fs.writeFileSync(path.join(work,'target.stdout'),stdout);fs.writeFileSync(path.join(work,'target.stderr'),stderr);
}
