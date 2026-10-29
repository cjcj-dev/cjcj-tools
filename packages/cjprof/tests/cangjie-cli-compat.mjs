#!/usr/bin/env zx
// Public getopt contracts derived from the fixed three Commands/*.cpp tables.
import fs from 'node:fs';import path from 'node:path';import net from 'node:net';import {fileURLToPath} from 'node:url';import {spawn,spawnSync} from 'node:child_process';import {setTimeout as delay} from 'node:timers/promises';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),[prefix,fixtures,work]=process.argv.slice(2).map(x=>path.resolve(x));fs.mkdirSync(work,{recursive:true});
const sdk=JSON.parse(fs.readFileSync(prefix+'/build-facts.json')).sdk,env={...process.env,CANGJIE_HOME:sdk,LD_LIBRARY_PATH:sdk+'/runtime/lib/linux_x86_64_cjnative:'+sdk+'/tools/lib'};delete env.POSIXLY_CORRECT;
const binary=prefix+'/bin/cjprof',commands=[],checks=[];
function check(name,pass){checks.push({name,executed:true,pass:!!pass});fs.writeFileSync(work+'/assertions.json',JSON.stringify(checks,null,2));console.log((pass?'PASS ':'FAIL ')+name);}
function run(name,args,expected=0,extraEnv={}){const argv=[binary,...args],p=spawnSync(binary,args,{env:{...env,...extraEnv},cwd:work,encoding:'utf8',timeout:15000,maxBuffer:4*1024*1024});commands.push({name,argv,rc:p.status,signal:p.signal,error:p.error?.message,env:extraEnv});fs.writeFileSync(work+'/commands.json',JSON.stringify(commands,null,2));fs.writeFileSync(work+'/'+name+'.stdout',p.stdout??'');fs.writeFileSync(work+'/'+name+'.stderr',p.stderr??'');check(name+' rc',p.status===expected);return p;}
const heap=work+'/heap=wire.data',samples=work+'/samples=wire.data';fs.copyFileSync(root+'/tests/heap.data',heap);fs.copyFileSync(fixtures+'/samples-2-8.data',samples);fs.copyFileSync(heap,work+'/cjprof.data');fs.copyFileSync(heap,work+'/--');
const heapForms=[['long-separated',['--input',heap]],['long-equal',['--input='+heap]],['short-separated',['-i',heap]],['short-joined',['-i'+heap]],['unique-abbreviation',['--inp='+heap]],['cluster-required',['-Vi'+heap]]];
for(const [name,args]of heapForms){const p=run('heap-'+name,['heap',...args,'--json']);check('heap '+name+' real parsed objects',p.stdout?.includes('"objects":['));}
for(const [name,args]of [['short-separated',['-D','2']],['short-joined',['-D2']],['long-separated',['--depth','2']],['long-equal',['--depth=2']],['signed-whitespace',['--depth= +2']]]){
 const p=run('depth-'+name,['heap','-i',heap,'--show-reference',...args]);check('depth '+name+' accepted value',!p.stdout?.includes('Invalid depth'));
}
for(const args of [['--show-reference'],['--show-reference='],['--show-reference=NOT_MATCH'],['-tV'],['--show-t'],['--incoming-r','--show-reference'],['--']])run('heap-flags-'+commands.length,['heap','-i',heap,...args]);
run('required-value-is-terminator',['heap','-i','--','--json']);
for(const args of [['--input'],['-i'],['--input='],['--input=missing.data'],['--unknown'],['-z'],['--verbose=yes'],['--d=2'],['--show-reference','operand'],['--dump-report','8080'],['-r'],['--','--json'],['operand','--json']])run('heap-error-'+commands.length,['heap',...args],1);
for(const args of [['--depth=bad'],['-D0']]){const p=run('depth-fallback-'+commands.length,['heap','-i',heap,...args]);check('invalid depth keeps prior default',p.stdout?.includes('Invalid depth'));}
// GNU optional_argument accepts only an attached value. Exercise the actual
// server consumer for absent/empty/invalid values and a unique long prefix.
for(const option of ['--dump-report','--dump-report=','--dump-report=bad','--dump-report=0','--dump-report=65536','--dump-r=8097']){
 const argv=[binary,'heap','-i'+heap,option],child=spawn(argv[0],argv.slice(1),{env,cwd:work,stdio:['ignore','pipe','pipe']});let output='';child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);const done=new Promise(r=>child.on('close',(rc,signal)=>{commands.push({name:option,argv,rc,signal,pid:child.pid});r();}));
 try{const end=Date.now()+8000;while(!output.includes('Access URL:')&&child.exitCode===null&&Date.now()<end)await delay(25);const port=Number(output.match(/Access URL:.*:(\d+)/)?.[1]);check(option+' reaches HTTP consumer',port>0);check(option+' port fallback or explicit value',option.startsWith('--dump-r=')?port>=8097:port>=8080&&port<8097);
  if(port){let response='';await new Promise((resolve,reject)=>{const s=net.createConnection(port,'127.0.0.1');s.setTimeout(5000,()=>s.destroy(Error('timeout')));s.on('connect',()=>s.write('GET /api/fragment/summary HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'));s.on('data',b=>response+=b);s.on('close',resolve);s.on('error',reject);});check(option+' actual HTTP summary',response.includes('instance_object_total'));}
 }finally{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await done;fs.writeFileSync(work+'/optional-'+commands.length+'.log',output);fs.writeFileSync(work+'/commands.json',JSON.stringify(commands,null,2));}
}
for(const command of ['heap','report','record'])for(const flag of ['-h','--help']){const p=run(command+'-help-'+flag,[command,flag],1);check(command+' legacy help text',p.stdout?.includes('Usage:'));}
const reportForms=[['long-separated',['--input',samples]],['long-equal',['--input='+samples]],['short-separated',['-i',samples]],['short-joined',['-i'+samples]],['unique-abbreviation',['--inp='+samples]]];
for(const [name,args]of reportForms){const p=run('report-'+name,['report',...args]);check('report '+name+' actual sample aggregation',p.stdout?.includes('66.67%'));}
for(const [name,args]of [['long-equal',['--input='+samples,'--flame-graph','--output='+work+'/long.svg']],['short-cluster',['-Fi'+samples,'-o'+work+'/short.svg']],['long-abbreviation',['--inp='+samples,'--flame','--out='+work+'/abbr.svg']]]){
 run('flame-'+name,['report',...args]);const output=work+'/'+({ 'long-equal':'long','short-cluster':'short','long-abbreviation':'abbr'}[name])+'.svg';check(name+' installed SVG written',fs.existsSync(output)&&fs.readFileSync(output,'utf8').includes('function zoom'));
}
for(const args of [['--input'],['--input='],['-i'],['--flame-graph=yes'],['--unknown'],['-z'],['--','--input='+samples],['operand','-i',samples]])run('report-error-'+commands.length,['report',...args],1);
// Compile only the owned targets needed by actual dump/record option consumers.
for(const [name,source]of [['record-target','CangjieRecordTarget.cj'],['dump-target','CangjieDumpTarget.cj']]){
 const argv=[sdk+'/bin/cjc',root+'/tests/'+source,'-o',work+'/'+name],p=spawnSync(argv[0],argv.slice(1),{env,encoding:'utf8'});commands.push({name,argv,rc:p.status,signal:p.signal});fs.writeFileSync(work+'/'+name+'.stderr',p.stderr??'');check(name+' build',p.status===0);if(p.status!==0)throw Error('test target preparation failed');
}
const target=work+'/record-target';
for(const [name,options]of [['long-equal',['--freq=499','--output='+work+'/record-long.data']],['short-joined',['-f499','-o'+work+'/record-short.data']],['long-separated',['--freq','499','--output',work+'/record-long-space.data']],['short-separated',['-f','499','-o',work+'/record-short-space.data']]]){
 const p=run('record-'+name,['record',...options,'--',target]);check(name+' actual positive CPU samples',/Recorded [1-9][0-9]* samples/.test(p.stdout??''));
}
for(const [value,message]of [[' +499',null],['0','Invalid frequency'],['bad','Invalid frequency'],['9223372036854775808','Invalid frequency'],['999999999','Maximum frequency rate'],['max','Using a maximum frequency']]){
 const p=run('freq-value-'+commands.length,['record','--freq='+value,'--','/bin/echo']);check('frequency value semantics '+value,message?p.stdout?.includes(message):!p.stdout?.includes('Invalid frequency'));
}
const permutation=run('record-permutation',['record','/bin/echo','--freq=499']);check('GNU options after command consumed',!permutation.stdout?.includes('--freq=499'));
const posix=run('record-posix',['record','/bin/echo','--freq=499'],0,{POSIXLY_CORRECT:'1'});check('POSIXLY_CORRECT preserves command argument',posix.stdout?.includes('--freq=499'));
const ended=run('record-terminator',['record','-f499','--','/bin/echo','--freq=251']);check('explicit terminator preserves command argument',ended.stdout?.includes('--freq=251'));
for(const args of [['--freq'],['-f'],['--output'],['--pid'],['--pid=-1'],['-p-1'],['--help=yes'],['--unknown']])run('record-error-'+commands.length,['record',...args],1);
for(const [name,option]of [['long','--pid='],['short','-p'],['long-space','--pid'],['short-space','-p']]){
 const child=spawn(target,[],{env,cwd:work,stdio:'ignore'}),done=new Promise(r=>child.on('close',r));
 try{await delay(150);const p=run('attach-'+name,['record',...(name.endsWith('space')?[option,String(child.pid)]:[option+child.pid]),'-f499','-o'+work+'/attach-'+name+'.data']);check(name+' attach samples positive',/Recorded [1-9][0-9]* samples/.test(p.stdout??''));}finally{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await done;}
}
const child=spawn(work+'/dump-target',[],{env,cwd:work,stdio:['ignore','pipe','pipe']}),done=new Promise(r=>child.on('close',r));let ready='';child.stdout.on('data',b=>ready+=b);
try{
 const end=Date.now()+5000;while(!ready.includes('DUMP_TARGET_READY')&&child.exitCode===null&&Date.now()<end)await delay(20);check('dump target ready',ready.includes('DUMP_TARGET_READY'));
 for(const [name,args,out]of [['long',['--dump='+child.pid,'--output='+work+'/dump-long.data'],work+'/dump-long.data'],['short',['-d'+child.pid,'-o'+work+'/dump-short.data'],work+'/dump-short.data'],['long-space',['--dump',String(child.pid),'--output',work+'/dump-long-space.data'],work+'/dump-long-space.data'],['short-space',['-d',String(child.pid),'-o',work+'/dump-short-space.data'],work+'/dump-short-space.data']]){run('dump-'+name,['heap',...args]);check(name+' actual runtime dump destination',fs.existsSync(out)&&fs.statSync(out).size>0);}
}finally{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await done;}
console.log('CLI compatibility '+checks.length+' assertions; failed='+checks.filter(x=>!x.pass).length);process.exitCode=checks.some(x=>!x.pass)?1:0;
