#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const [exe,sdk,work]=process.argv.slice(2);fs.mkdirSync(work,{recursive:true});
const commands=[],checks=[],transcript=[];
const save=()=>{fs.writeFileSync(work+'/results.json',JSON.stringify({commands,checks},null,2));fs.writeFileSync(work+'/transcript.json',JSON.stringify(transcript,null,2));};
function run(label,argv,expected=0){const r=spawnSync(argv[0],argv.slice(1),{cwd:work,encoding:'utf8',timeout:120000});commands.push({label,argv,rc:r.status,signal:r.signal});fs.writeFileSync(work+'/'+label+'.stdout',r.stdout??'');fs.writeFileSync(work+'/'+label+'.stderr',r.stderr??'');save();assert.equal(r.status,expected,label+' '+r.stderr);}
const root=work+'/project',src=root+'/src',out=root+'/output',module='testRenamedOrg::cj0993';
fs.mkdirSync(src+'/xoo',{recursive:true});fs.mkdirSync(out,{recursive:true});
const main=src+'/main.cj',other=src+'/aaa.cj',child=src+'/xoo/xoo.cj',db=root+'/compile_commands.json';
fs.writeFileSync(main,'package '+module+'\nmain():Int64{42}\n');
fs.writeFileSync(other,'package testOrg::cj0993\nfunc unchanged():Int64{1}\n');
fs.writeFileSync(child,'public package '+module+'.xoo\npublic let x:Int64=42\n');
const cjc=sdk+'/bin/cjc';
const childArgs=[cjc,'--module-name',module,'--output-type=staticlib','--output-dir',out,'-p',src+'/xoo','-o','libxoo.a'];
run('build-real-child',childArgs);
const rootArgs=[cjc,'--module-name',module,'--import-path',out,'--output-type=staticlib','--output-dir',out,'-p',src,'--no-sub-pkg','-o','libroot.a'];
fs.writeFileSync(db,JSON.stringify([
 ...[main,other].map(file=>({directory:root,file,arguments:rootArgs})),{directory:root,file:child,arguments:childArgs}
],null,2));
const env={...process.env};for(const key of ['LD_LIBRARY_PATH','LD_PRELOAD','LD_AUDIT','CANGJIE_HOME','CANGJIE_PATH'])delete env[key];
const started=new Date().toISOString(),p=spawn(exe,['--sdk',sdk],{cwd:work,env,stdio:['pipe','pipe','pipe']});
let data=Buffer.alloc(0),stderr='',ended=false;const queue=[];
const closed=new Promise(resolve=>{p.on('error',e=>resolve({error:e.message}));p.on('close',(rc,signal)=>{ended=true;resolve({rc,signal});});});
p.stderr.on('data',x=>stderr+=x);p.stdout.on('data',chunk=>{data=Buffer.concat([data,chunk]);for(;;){const end=data.indexOf('\r\n\r\n');if(end<0)return;const match=/Content-Length: (\d+)/i.exec(data.subarray(0,end).toString());assert(match,'framed stdout');const size=Number(match[1]);if(data.length<end+4+size)return;const value=JSON.parse(data.subarray(end+4,end+4+size));data=data.subarray(end+4+size);queue.push(value);transcript.push({receive:value});save();}});
function send(method,params={},id){const value={jsonrpc:'2.0',method,params,...(id===undefined?{}:{id})},body=Buffer.from(JSON.stringify(value));transcript.push({send:value});p.stdin.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`),body]));}
async function take(predicate){const deadline=Date.now()+180000;while(Date.now()<deadline){const i=queue.findIndex(predicate);if(i>=0)return queue.splice(i,1)[0];if(ended)throw Error('server ended '+stderr);await new Promise(r=>setTimeout(r,20));}throw Error('response timeout '+stderr);}
const uri=pathToFileURL(main).href;let version=0;
async function complete(label,marked,expected,absent=[]){
 const at=marked.indexOf('|'),text=marked.replace('|',''),lines=text.slice(0,at).split('\n');version++;
 send(version===1?'textDocument/didOpen':'textDocument/didChange',version===1?{textDocument:{uri,languageId:'cangjie',version,text}}:{textDocument:{uri,version},contentChanges:[{text}]});
 await take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri&&x.params.version===version);
 send('textDocument/completion',{textDocument:{uri},position:{line:lines.length-1,character:lines.at(-1).length}},label);
 const reply=await take(x=>x.id===label);checks.push({label:label+'-target-reached',pass:true});save();
 try{
  assert.equal(reply.error,undefined,label+' '+JSON.stringify(reply));
  const labels=reply.result.items.map(x=>x.label);for(const name of expected)assert(labels.includes(name),label+' missing '+name);for(const name of absent)assert(!labels.includes(name),label+' unexpected '+name);
  checks.push({label,pass:true});
 }catch(e){checks.push({label,pass:false,error:e.stack});}save();
}
const timer=setTimeout(()=>p.kill('SIGTERM'),480000);
try{
 send('initialize',{rootUri:pathToFileURL(root).href,initializationOptions:{compilationDatabase:db}},'init');assert((await take(x=>x.id==='init')).result.capabilities);send('initialized');
 await complete('configured-module','package '+module+'\nimport t|\nmain():Int64{42}\n',[module],['testOrg::cj0993']);
 await complete('configured-child','package '+module+'\nimport '+module+'.x|\nmain():Int64{42}\n',['xoo']);
 await complete('old-org-filter','package '+module+'\nimport testO|\nmain():Int64{42}\n',[],['testOrg::cj0993']);
 // The ordinary semantic control uses an independently valid command. Mixed
 // declarations deliberately make the preceding import-discovery project red.
 const validDb=root+'/compile-valid.json';
 fs.writeFileSync(validDb,JSON.stringify([{directory:root,file:main,arguments:rootArgs}],null,2));
 send('workspace/didChangeConfiguration',{settings:{compilationDatabase:validDb}});
 await complete('local-control','package '+module+'\nmain():Int64{let answer=42\nans|wer}\n',['answer']);
 const renamed='otherOrg::otherModule',renamedDb=root+'/compile-renamed.json';
 fs.writeFileSync(renamedDb,JSON.stringify([{directory:root,file:main,arguments:rootArgs.map(x=>x===module?renamed:x)}],null,2));
 send('workspace/didChangeConfiguration',{settings:{compilationDatabase:renamedDb}});
 await complete('configuration-change','package '+module+'\nimport o|\nmain():Int64{42}\n',[renamed],[module,'testOrg::cj0993']);
 send('workspace/didChangeConfiguration',{settings:{compilationDatabase:db}});
 await complete('configuration-restored','package '+module+'\nimport t|\nmain():Int64{42}\n',[module],[renamed,'testOrg::cj0993']);
 send('shutdown',{},'stop');assert.equal((await take(x=>x.id==='stop')).result,null);send('exit');p.stdin.end();const r=await closed;assert.equal(r.rc,0);commands.push({label:'installed-stdio',argv:[exe,'--sdk',sdk],started,ended:new Date().toISOString(),...r});
}finally{clearTimeout(timer);if(!ended)p.kill('SIGTERM');fs.writeFileSync(work+'/server.stderr',stderr);save();}
process.exitCode=checks.every(x=>x.pass)?0:1;
