import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const [exe,sdk,directory,cjpm,seed]=process.argv.slice(2);
const requestedMode="project-live";
const hostEnvironmentControl=requestedMode==='analysis-host';
const mode=hostEnvironmentControl?'analysis':requestedMode;fs.mkdirSync(directory,{recursive:true});
const cases=[];
const encode=value=>{const body=typeof value==='string'?value:JSON.stringify(value);return Buffer.concat([Buffer.from(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n`),Buffer.from(body)]);};
async function client(label,body,expected,selectedSdk=sdk){
 if(mode==='analysis'&&!label.startsWith('analysis-'))return;
 if(mode==='highlight'&&label!=='document-highlight')return;
 if(mode==='highlight-control'&&label!=='highlight-definition-control')return;
 if(mode==='snapshot'&&label!=='error-snapshot-queries')return;
 if(mode==='workspace'&&label!=='workspace-unopened-siblings')return;
 if(mode==='control'&&label!=='independent-shutdown')return;
 if(mode==='target'&&label!=='lifecycle-semantics')return;
 const env={...process.env};for(const key of ['LD_LIBRARY_PATH','LD_PRELOAD','LD_AUDIT','CANGJIE_HOME','CANGJIE_PATH']){if(key!=='CANGJIE_HOME'||!hostEnvironmentControl)delete env[key];}
 if(hostEnvironmentControl)assert(env.CANGJIE_HOME&&env.CANGJIE_HOME!==selectedSdk,'distinct real host home control');
 const started=new Date().toISOString(),p=spawn(exe,['--sdk',selectedSdk],{env,stdio:['pipe','pipe','pipe']});let data=Buffer.alloc(0),stderr='',ended=false;const transcript=[];const queue=[],waiters=[];
 const closed=new Promise(resolve=>{p.on('error',error=>resolve({error:String(error)}));p.on('close',(rc,signal)=>{ended=true;resolve({rc,signal})});});
 p.stderr.on('data',b=>stderr+=b);p.stdout.on('data',chunk=>{transcript.push({direction:'receive-bytes',base64:chunk.toString('base64')});data=Buffer.concat([data,chunk]);for(;;){const boundary=data.indexOf('\r\n\r\n');if(boundary<0)break;const header=data.subarray(0,boundary).toString();const match=/^Content-Length: (\d+)$/m.exec(header);assert(match,'stdout is framed JSON-RPC, no compiler chatter');const size=Number(match[1]);if(data.length<boundary+4+size)break;const value=JSON.parse(data.subarray(boundary+4,boundary+4+size));data=data.subarray(boundary+4+size);transcript.push({direction:"receive",value});queue.push(value);for(const wake of waiters.splice(0))wake();}});
 async function take(predicate){const deadline=Date.now()+45000;while(Date.now()<deadline){let index=queue.findIndex(predicate);if(index>=0)return queue.splice(index,1)[0];if(ended)throw Error('server ended before response '+stderr);await Promise.race([new Promise(resolve=>waiters.push(resolve)),new Promise(resolve=>setTimeout(resolve,20))]);}throw Error('response timeout '+JSON.stringify(queue)+' '+stderr);}
 const api={send:value=>{transcript.push({direction:"send",value});p.stdin.write(encode(value));},raw:bytes=>{transcript.push({direction:"send-bytes",base64:bytes.toString("base64")});p.stdin.write(bytes);},take,drain:()=>queue.splice(0),end:()=>p.stdin.end()};
 const timeout=setTimeout(()=>p.kill('SIGTERM'),120000);let failure;
 try{await body(api);const result=await closed;assert.equal(result.rc,expected,label);assert.equal(result.signal,null);cases.push({label,argv:[exe,'--sdk',selectedSdk],started,ended:new Date().toISOString(),...result,stderr,pass:true});}
 catch(e){failure=e;if(!ended)p.kill('SIGTERM');const result=await closed;cases.push({label,started,ended:new Date().toISOString(),...result,stderr,pass:false,error:e.stack});}
 finally{clearTimeout(timeout);fs.writeFileSync(directory+'/'+label+'-transcript.json',JSON.stringify(transcript,null,2));fs.writeFileSync(directory+'/client-results.json',JSON.stringify(cases,null,2));}
 if(failure)throw failure;
}
const project=directory+'/project',database=project+'/compile_commands.json',rows=[];fs.mkdirSync(project);
for(const p of ['cjpm.toml','app','helper','leaf','control','binary'])fs.cpSync(seed+'/'+p,project+'/'+p,{recursive:true});
function build(name,expected=0){const argv=[cjpm,'build','-i','-V','-j','2','--target-dir',project+'/target','--export-compile-commands',database],started=new Date().toISOString(),o=fs.openSync(directory+'/'+name+'.stdout','wx'),e=fs.openSync(directory+'/'+name+'.stderr','wx'),r=spawnSync(argv[0],argv.slice(1),{cwd:project,env:process.env,stdio:['ignore',o,e],timeout:180000});fs.closeSync(o);fs.closeSync(e);rows.push({name,argv,cwd:project,started,ended:new Date().toISOString(),rc:r.status,signal:r.signal,error:r.error?.message??null});fs.writeFileSync(directory+'/producer-commands.json',JSON.stringify(rows,null,2));assert.equal(r.status,expected,name);assert.equal(r.signal,null);}
const app=project+'/app/source-code/value.cj',original=fs.readFileSync(app,'utf8'),uri=pathToFileURL(app).href;
const request=(id,method,params={})=>({jsonrpc:'2.0',id,method,params}),note=(method,params={})=>({jsonrpc:'2.0',method,params});
const at=original.indexOf('forwarded()'),lines=original.slice(0,at).split('\n'),position={line:lines.length-1,character:lines.at(-1).length};
build('initial');
try {await client('live-build-failure',async c=>{
 c.send(request('init','initialize',{rootUri:pathToFileURL(project).href,initializationOptions:{compilationDatabase:database}}));assert((await c.take(x=>x.id==='init')).result.capabilities);
 c.send(note('textDocument/didOpen',{textDocument:{uri,version:1,languageId:'cangjie',text:original}}));assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri)).params.diagnostics,[]);
 async function query(id){c.send(request(id,'textDocument/definition',{textDocument:{uri},position}));const r=await c.take(x=>x.id===id);assert.equal(r.error,undefined);return r.result;}
 assert(await query('before'),'LIVE_BEFORE_INDEX');c.drain();
 fs.writeFileSync(app,original.replace('use(): Int64','use(): Bool'));build('real-compiler-failure',1);assert(!fs.existsSync(database),'real failure removed DB');
 c.send(note('workspace/didChangeWatchedFiles',{changes:[{uri:pathToFileURL(database).href,type:3}]}));const failed=await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri);assert(failed.params.diagnostics.some(d=>d.severity===1));assert.equal(await query('failed'),null,'LIVE_FAILED_BUILD_NO_OLD_INDEX');
 fs.writeFileSync(app,original);build('restored');c.drain();
 c.send(note('workspace/didChangeWatchedFiles',{changes:[{uri:pathToFileURL(database).href,type:1}]}));assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri)).params.diagnostics,[]);assert(await query('restored'),'LIVE_RESTORED_INDEX');
 c.send(request('stop','shutdown'));assert.equal((await c.take(x=>x.id==='stop')).result,null);c.send(note('exit'));c.end();
},0);}finally{fs.writeFileSync(app,original);}
console.log('PROJECT_REAL_FAILED_BUILD_INDEX_RESTORED');
