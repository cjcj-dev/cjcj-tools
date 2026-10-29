#!/usr/bin/env zx
import fs from 'node:fs';import path from 'node:path';import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const [prefix,work]=process.argv.slice(2).map(x=>path.resolve(x));fs.mkdirSync(work,{recursive:true});
const sdk=JSON.parse(fs.readFileSync(path.join(prefix,'build-facts.json'),'utf8')).sdk;
const env={...process.env,CANGJIE_HOME:sdk,LD_LIBRARY_PATH:sdk+'/runtime/lib/linux_x86_64_cjnative:'+sdk+'/tools/lib'};
const commands=[],checks=[];function check(name,condition){checks.push({name,executed:true,pass:!!condition});fs.writeFileSync(work+'/assertions.json',JSON.stringify(checks,null,2));assert.ok(condition,name);}
function run(name,argv,expected=0){const p=spawnSync(argv[0],argv.slice(1),{env,cwd:work,encoding:'utf8',timeout:20000,maxBuffer:8*1024*1024});commands.push({name,argv,rc:p.status,signal:p.signal,error:p.error?.message});fs.writeFileSync(work+'/commands.json',JSON.stringify(commands,null,2));fs.writeFileSync(work+'/'+name+'.stdout',p.stdout??'');fs.writeFileSync(work+'/'+name+'.stderr',p.stderr??'');check(name+' rc',p.status===expected);return p.stdout;}
const binary=prefix+'/bin/cjprof',target=work+'/target';
run('target-build',[sdk+'/bin/cjc',root+'/tests/CangjieRecordTarget.cj','-o',target]);
run('help',[binary,'record','--help'],1);run('no-command',[binary,'record'],1);run('invalid-pid',[binary,'record','-p','-1'],1);
const launched=work+'/launched.data';const text=run('launch',[binary,'record','-f','499','-o',launched,'--',target]);
check('launch actual samples positive',/Recorded [1-9][0-9]* samples/.test(text));
check('actual parallel thread sampling',Number(text.match(/Sampled (\d+) of/)?.[1])>=2);
const report=run('launch-report',[binary,'report','-i',launched]);check('Cangjie symbol demangling and aggregation',report.includes('recordTarget')&&report.includes('worker'));
const svg=work+'/sample.svg';run('launch-flame',[binary,'report','-i',launched,'-F','-o',svg]);check('sampled stacks reach interactive SVG',fs.readFileSync(svg,'utf8').includes('recordTarget'));
const child=spawn(target,[],{env,cwd:work,stdio:['ignore','pipe','pipe']});let stdout='',stderr='';child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);const ended=new Promise(r=>child.on('exit',(rc,signal)=>r({rc,signal})));
try{
 await new Promise(r=>setTimeout(r,150));
 const out=work+'/attached.data';const recorded=run('attach',[binary,'record','-p',String(child.pid),'-f','251','-o',out]);check('attach actual samples positive',/Recorded [1-9][0-9]* samples/.test(recorded));
 check('attach sample consumer',run('attach-report',[binary,'report','-i',out]).includes('recordTarget'));
}finally{
 if(child.exitCode===null && child.signalCode===null)child.kill('SIGTERM');const result=await ended;commands.push({name:'attach-target',argv:[target],pid:child.pid,...result});fs.writeFileSync(work+'/commands.json',JSON.stringify(commands,null,2));fs.writeFileSync(work+'/attach-target.stdout',stdout);fs.writeFileSync(work+'/attach-target.stderr',stderr);
}
for(const attach of [false,true]){
 const name=attach?'interrupt-attach':'interrupt-launch',out=work+'/'+name+'.data';
 let ownedTarget;
 if(attach){ownedTarget=spawn(target,['8000'],{env,cwd:work,stdio:'ignore'});await new Promise(r=>setTimeout(r,150));}
 const argv=[binary,'record','-f','199','-o',out,...(attach?['-p',String(ownedTarget.pid)]:['--',target,'8000'])];
 const proc=spawn(argv[0],argv.slice(1),{env,cwd:work,stdio:['ignore','pipe','pipe']});let stdout='',stderr='';proc.stdout.on('data',b=>stdout+=b);proc.stderr.on('data',b=>stderr+=b);
 const done=new Promise(r=>proc.on('exit',(rc,signal)=>r({rc,signal})));
 const start=Date.now();while(!attach&&!stdout.includes('TARGET_PID')&&proc.exitCode===null&&Date.now()-start<5000)await new Promise(r=>setTimeout(r,20));
 await new Promise(r=>setTimeout(r,400));proc.kill('SIGINT');
 let timer;const result=await Promise.race([done,new Promise(r=>{timer=setTimeout(()=>r(null),5000)})]);clearTimeout(timer);
 if(!result){proc.kill('SIGKILL');const killed=await done;commands.push({name,argv,pid:proc.pid,...killed,error:'failed to stop within 5000ms'});fs.writeFileSync(work+'/commands.json',JSON.stringify(commands,null,2));fs.writeFileSync(work+'/'+name+'.stdout',stdout);fs.writeFileSync(work+'/'+name+'.stderr',stderr);throw Error(name+' failed to stop');}
 commands.push({name,argv,pid:proc.pid,...result});fs.writeFileSync(work+'/commands.json',JSON.stringify(commands,null,2));fs.writeFileSync(work+'/'+name+'.stdout',stdout);fs.writeFileSync(work+'/'+name+'.stderr',stderr);
 try{
  check(name+' graceful stop',result.rc===0&&result.signal===null);
  check(name+' sampled data',/Recorded [1-9][0-9]* samples/.test(stdout));run(name+'-report',[binary,'report','-i',out]);
  if(attach){check('interrupt attach preserves owned target',ownedTarget.exitCode===null&&ownedTarget.signalCode===null);}
  else{const pid=Number(stdout.match(/TARGET_PID (\d+)/)?.[1]);check('launch target identity captured',pid>0);let alive=true;try{process.kill(pid,0)}catch(e){if(e.code==='ESRCH')alive=false;else throw e;}check('interrupt launch terminates exact target',!alive);}
 }finally{if(ownedTarget&&ownedTarget.exitCode===null&&ownedTarget.signalCode===null){const ended=new Promise(r=>ownedTarget.on('exit',r));ownedTarget.kill('SIGTERM');await ended;}}
}
console.log('PASS record '+checks.length+' assertions');
