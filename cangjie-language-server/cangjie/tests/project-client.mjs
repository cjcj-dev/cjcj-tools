import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const [exe,sdk,directory,project,requestedMode="project"]=process.argv.slice(2);
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
const database=process.argv[7]??project+'/compile_commands.json';
const request=(id,method,params={})=>({jsonrpc:'2.0',id,method,params}),note=(method,params={})=>({jsonrpc:'2.0',method,params});
const uri=p=>pathToFileURL(p).href,read=p=>fs.readFileSync(p,'utf8'),app=project+'/app/source-code/value.cj',helper=project+'/helper/source-code/value.cj',leaf=project+'/leaf/source-code/value.cj',control=project+'/control/source-code/value.cj';
const pos=(s,needle)=>{const at=s.indexOf(needle);assert(at>=0);const lines=s.slice(0,at).split('\n');return {line:lines.length-1,character:lines.at(-1).length};};
await client('project-stdio',async c=>{
 c.send(request('init','initialize',{rootUri:uri(project),initializationOptions:{compilationDatabase:database}}));assert((await c.take(x=>x.id==='init')).result.capabilities);c.send(note('initialized'));
 async function open(p,version=1,text=read(p)){c.send(note('textDocument/didOpen',{textDocument:{uri:uri(p),version,languageId:'cangjie',text}}));return (await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(p)&&x.params.version===version)).params.diagnostics;}
 async function change(p,version,text){c.send(note('textDocument/didChange',{textDocument:{uri:uri(p),version},contentChanges:[{text}]}));return (await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(p)&&x.params.version===version)).params.diagnostics;}
 async function query(id,method,p,needle){c.send(request(id,'textDocument/'+method,{textDocument:{uri:uri(p)},position:pos(read(p),needle),context:{includeDeclaration:false}}));const r=await c.take(x=>x.id===id);assert.equal(r.error,undefined);return r.result;}
 if(mode!=='project-control')assert.deepEqual(await open(app),[],'PROJECT_IMPORT_TARGET');
 if(mode!=='project-config'&&mode!=='project-control'&&mode!=='project-target'){
 const d=await query('direct','definition',app,'forwarded()');assert(d,'PROJECT_SOURCE_DEFINITION');assert.equal(d.uri,uri(helper));
 assert.deepEqual(await open(helper),[]);const trans=await query('transitive','definition',helper,'diskAnswer()');assert.equal(trans.uri,uri(leaf));
 assert.deepEqual(await open(leaf),[]);const refs=await query('refs','references',leaf,'diskAnswer()');assert.equal(refs.length,1);assert.equal(refs[0].uri,uri(helper));
 assert.equal(await query('binary','definition',app,'answer()'),null,'binary dependency has no invented source URI');
 assert.deepEqual(await open(control),[],'PROJECT_INDEPENDENT_CONTROL');
 const bad=await change(app,2,read(app).replace('use(): Int64','use(): Bool'));assert(bad.some(d=>d.severity===1),'PROJECT_IMPORT_TYPE_TARGET');assert.equal(await query('error-query','definition',app,'forwarded()'),null);
 assert.deepEqual(await change(app,3,read(app)),[]);
 const outside=project+'/ignored/value.cj';assert((await open(outside)).some(d=>d.severity===1&&/outside/.test(d.message)));assert.equal(await query('outside','definition',outside,'diskAnswer()'),null);
 c.send(note('textDocument/didClose',{textDocument:{uri:uri(helper)}}));await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(helper));assert.equal((await query('close','definition',app,'forwarded()')).uri,uri(helper));
 }
 if(mode==='project-control'){
  assert.deepEqual(await open(control),[],'PROJECT_INDEPENDENT_CONTROL');
 }else if(mode!=='project-target'){
 c.send(request('barrier','textDocument/definition',{textDocument:{uri:uri(app)},position:pos(read(app),'forwarded()')}));await c.take(x=>x.id==='barrier');c.drain();
 c.send(note('workspace/didChangeConfiguration',{settings:{compilationDatabase:database+'.missing'}}));const missing=await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(app));assert(missing.params.diagnostics.some(d=>d.severity===1));assert.equal(await query('missing-graph','definition',app,'forwarded()'),null);
 c.drain();c.send(note('workspace/didChangeConfiguration',{settings:{compilationDatabase:database}}));await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(app)&&x.params.diagnostics.length===0);assert.equal((await query('config-restored','definition',app,'forwarded()')).uri,uri(helper));
 const entries=JSON.parse(read(database)),helperEntry=entries.find(e=>e.file===helper),cjo=path.join(path.dirname(helperEntry.output),'project_helper.cjo');
 c.drain();fs.renameSync(cjo,cjo+'.held');try{
  c.send(note('workspace/didChangeWatchedFiles',{changes:[{uri:uri(cjo),type:3}]}));
  const missingCjo=await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(app));assert(missingCjo.params.diagnostics.some(d=>d.severity===1),'PROJECT_MISSING_CJO_TARGET');
  assert.equal(await query('missing-cjo-query','definition',app,'forwarded()'),null);
  assert.deepEqual(await open(control,2),[],'PROJECT_MISSING_CJO_CONTROL');
 }finally{fs.renameSync(cjo+'.held',cjo);}
 c.drain();c.send(note('workspace/didChangeWatchedFiles',{changes:[{uri:uri(cjo),type:1}]}));await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(app)&&x.params.diagnostics.length===0);
 assert.equal((await query('cjo-restored','definition',app,'forwarded()')).uri,uri(helper));
 }
 c.send(request('stop','shutdown'));assert.equal((await c.take(x=>x.id==='stop')).result,null);c.send(note('exit'));c.end();
},0);
console.log('PROJECT_STDIO_TARGET_RESTORED');
