import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {pathToFileURL,fileURLToPath} from 'node:url';
const [exe,sdk,directory,project,mode='all']=process.argv.slice(2);
fs.mkdirSync(directory,{recursive:true});
const cases=[];
const encode=value=>{const body=typeof value==='string'?value:JSON.stringify(value);return Buffer.concat([Buffer.from(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n`),Buffer.from(body)]);};
async function client(label,body,expected,selectedSdk=sdk){
 const env={...process.env};for(const key of ['LD_LIBRARY_PATH','LD_PRELOAD','LD_AUDIT','CANGJIE_HOME','CANGJIE_PATH']){delete env[key];}
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

const request=(id,method,params={})=>({jsonrpc:'2.0',id,method,params}),note=(method,params={})=>({jsonrpc:'2.0',method,params});
const uri=p=>pathToFileURL(p).href;
const position=(text,needle,n=0)=>{let i=-1;for(let k=0;k<=n;k++){i=text.indexOf(needle,i+1);assert(i>=0,needle);}const lines=text.slice(0,i).split('\n');return {line:lines.length-1,character:lines.at(-1).length};};
function buildProject(label){
 const recipe=JSON.parse(fs.readFileSync(path.join(project,'../project-build-recipe.json'),'utf8'));
 const started=new Date().toISOString(),r=spawnSync(recipe.argv[0],recipe.argv.slice(1),{cwd:project,env:recipe.env,encoding:'utf8',timeout:180000});
 fs.writeFileSync(directory+'/'+label+'.json',JSON.stringify({...recipe,started,ended:new Date().toISOString(),rc:r.status,signal:r.signal,error:r.error?.message??null},null,2));fs.writeFileSync(directory+'/'+label+'.stdout',r.stdout??'');fs.writeFileSync(directory+'/'+label+'.stderr',r.stderr??'');assert.equal(r.status,0,label+' '+r.stderr);
 const exe=project+'/target/release/bin/rename_app';const env={...recipe.env,LD_LIBRARY_PATH:recipe.env.CANGJIE_HOME+'/runtime/lib/linux_x86_64_cjnative:'+recipe.env.CANGJIE_HOME+'/lib/linux_x86_64_cjnative'};
 const run=spawnSync(exe,[],{cwd:project,env,encoding:'utf8',timeout:30000});fs.writeFileSync(directory+'/'+label+'-run.json',JSON.stringify({argv:[exe],cwd:project,env,rc:run.status,signal:run.signal,error:run.error?.message??null,stdout:run.stdout,stderr:run.stderr},null,2));assert.equal(run.status,0,label+' actual program '+run.error+' '+run.stderr);
}
async function finish(c){c.send(request('stop','shutdown'));assert.equal((await c.take(x=>x.id==='stop')).result,null);c.send(note('exit'));c.end();}
async function init(c,opts={}){c.send(request('init','initialize',{...opts,capabilities:{workspace:{workspaceEdit:{documentChanges:true}}}}));const r=await c.take(x=>x.id==='init');assert.equal(r.result.capabilities.renameProvider.prepareProvider,true);c.send(note('initialized'));}
async function open(c,p,text,version=1){c.send(note('textDocument/didOpen',{textDocument:{uri:uri(p),languageId:'cangjie',version,text}}));return (await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(p)&&x.params.version===version)).params.diagnostics;}
async function change(c,p,text,version){c.send(note('textDocument/didChange',{textDocument:{uri:uri(p),version},contentChanges:[{text}]}));return (await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(p)&&x.params.version===version)).params.diagnostics;}
let serial=0;
async function query(c,p,text,needle,method='rename',newName='',n=0){const id='q'+(++serial);c.send(request(id,'textDocument/'+method,{textDocument:{uri:uri(p)},position:position(text,needle,n),...(method==='rename'?{newName}:{})}));return c.take(x=>x.id===id);}
function offset(text,pos){const lines=text.split('\n');assert(pos.line<lines.length);return lines.slice(0,pos.line).reduce((n,x)=>n+x.length+1,0)+pos.character;}
function apply(result,files,versions){assert(result?.documentChanges?.length,'RENAME_ATOMIC_EDIT');const changed=new Map();for(const change of result.documentChanges){const p=fileURLToPath(change.textDocument.uri);assert(files.has(p));assert.equal(change.textDocument.version,versions.get(p)??null,'RENAME_SNAPSHOT_VERSION');let text=files.get(p);const edits=change.edits.map(e=>({first:offset(text,e.range.start),last:offset(text,e.range.end),text:e.newText})).sort((a,b)=>b.first-a.first);let end=text.length+1;for(const e of edits){assert(e.last<end,'non-overlapping edits');text=text.slice(0,e.first)+e.text+text.slice(e.last);end=e.first;}changed.set(p,text);}return changed;}
const capture=`package rename_sample
func result(): Int64 {
    let victim: Int64 = 4
    if (true) { let occupied: Int64 = 7; return victim + occupied }
    return victim
}
`;
if(mode!=='project'&&mode!=='members')await client(mode==='target'?'capture-target':mode==='control'?'rename-control':'rename-local',async c=>{
 const p=path.join(directory,'use.cj');fs.writeFileSync(p,capture);await init(c);assert.deepEqual(await open(c,p,capture),[],'VALID_CAPTURE_INPUT');
 if(mode==='target'||mode==='all'){
  const r=await query(c,p,capture,'victim:','rename','occupied');assert.equal(r.result,undefined,'RENAME_CAPTURE_TARGET');assert.match(r.error?.message??'',/reference binding/,'RENAME_CAPTURE_TARGET');console.log('RENAME_CAPTURE_REJECTED');
  if(mode==='target'){await finish(c);return;}
 }
 const prep=await query(c,p,capture,'victim:','prepareRename');assert.equal(prep.error,undefined);assert.equal(prep.result.placeholder,'victim');
 let r=await query(c,p,capture,'victim:','rename','fresh');assert.equal(r.error,undefined,JSON.stringify(r));let updated=apply(r.result,new Map([[p,capture]]),new Map([[p,1]])).get(p);assert(updated.includes('return fresh + occupied'));assert(!updated.includes('victim'));assert.deepEqual(await change(c,p,updated,2),[]);let def=await query(c,p,updated,'fresh +','definition');assert.equal(def.result.range.start.line,2);
 if(mode==='control'){await finish(c);return;}
 const samples=[
  {text:'package rename_sample\nfunc sum(value!: Int64): Int64 { value }\nfunc use(): Int64 { sum(value: 4) }\n',at:'value!',next:'amount',count:3},
  {text:'package rename_sample\nfunc same<T>(value: T): T { value }\nfunc use(): Int64 { same<Int64>(4) }\n',at:'T>',next:'Item',count:3},
  {text:'package rename_sample\nclass Holder { public var value: Int64 = 4; public init() {} }\nfunc use(): Int64 { let holder = Holder(); return holder.value }\n',at:'value:',next:'amount',count:2},
  {text:'package rename_sample\nclass Holder { public init() {} }\nfunc use(): Holder { let holder: Holder = Holder(); return holder }\n',at:'Holder {',next:'Container',count:4},
  {text:'package rename_sample\nfunc pick(value: Int64): Int64 { value }\nfunc pick(value: Bool): Bool { value }\nfunc use(): Int64 { let control = pick(true); return pick(4) }\n',at:'pick(value: Int64)',next:'choose',count:2},
  {text:'package rename_sample\nfunc use(): Int64 { /* 😀 */ let value: Int64 = 4; return value }\n',at:'value:',next:'renamed',count:2}
 ];
 let version=2;
 for(const [index,test] of samples.entries()){
  assert.deepEqual(await change(c,p,test.text,++version),[],'VALID_CASE_'+index);const r=await query(c,p,test.text,test.at,'rename',test.next);assert.equal(r.error,undefined,'CASE_'+index+' '+JSON.stringify(r));assert.equal(r.result.documentChanges[0].edits.length,test.count,'EXACT_DECL_REFERENCE_SET_'+index);const text=apply(r.result,new Map([[p,test.text]]),new Map([[p,version]])).get(p);assert.deepEqual(await change(c,p,text,++version),[],'RENAMED_SEMA_'+index);
 }
 assert.deepEqual(await change(c,p,capture,++version),[]);
 for(const bad of ['if','_','x y','new/*x*/','']){const r=await query(c,p,capture,'victim:','rename',bad);assert(r.error,'ILLEGAL_IDENTIFIER '+bad);assert.equal(r.result,undefined);}
 const duplicate=capture.replace('let victim: Int64 = 4','let victim: Int64 = 4\n    let duplicate: Int64 = 2');assert.deepEqual(await change(c,p,duplicate,++version),[]);assert((await query(c,p,duplicate,'victim:','rename','duplicate')).error,'DUPLICATE_DECL_REJECT');
 const broken=capture.replace('= 4','= true');assert((await change(c,p,broken,++version)).some(d=>d.severity===1));assert((await query(c,p,broken,'victim:','prepareRename')).error,'ERROR_SNAPSHOT_REJECT');
 assert.deepEqual(await change(c,p,capture,++version),[]);const last=version;c.send(note('textDocument/didChange',{textDocument:{uri:uri(p),version:last},contentChanges:[{text:broken}]}));const good=await query(c,p,capture,'victim:','rename','latest');assert.equal(good.error,undefined);assert.equal(good.result.documentChanges[0].textDocument.version,last,'STALE_NOTIFICATION_MUST_NOT_REPLACE_SNAPSHOT');
 await finish(c);
},0);
if(mode==='members')await client('rename-members',async c=>{
 const p=path.join(directory,'members.cj');await init(c);let version=1;
 const normal='package rename_members\nclass Holder { public init() {} public func answer(): Int64 { 42 } }\nfunc use(): Int64 { Holder().answer() }\n';
 fs.writeFileSync(p,normal);assert.deepEqual(await open(c,p,normal,version),[]);
 const edit=await query(c,p,normal,'answer():','rename','result');assert.equal(edit.error,undefined,JSON.stringify(edit));assert.equal(edit.result.documentChanges[0].edits.length,2);
 const changed=apply(edit.result,new Map([[p,normal]]),new Map([[p,version]])).get(p);assert.deepEqual(await change(c,p,changed,++version),[],'FINAL_MEMBER_RENAMED');
 const cases=[
  {text:'package rename_members\nopen class Base { public init() {} public open func answer(): Int64 { 42 } }\nclass Derived <: Base { public init() { super() } public override func answer(): Int64 { 7 } }\n',at:'answer():',n:0},
  {text:'package rename_members\nopen class Base { public init() {} public open func answer(): Int64 { 42 } }\nclass Derived <: Base { public init() { super() } public override func answer(): Int64 { 7 } }\n',at:'answer():',n:1},
  {text:'package rename_members\ninterface Answer { func answer(): Int64 }\nclass Holder <: Answer { public init() {} public func answer(): Int64 { 42 } }\n',at:'answer():',n:1}
 ];
 for(const test of cases){assert.deepEqual(await change(c,p,test.text,++version),[],'VALID_RELATED_MEMBER_INPUT');const rejected=await query(c,p,test.text,test.at,'prepareRename','',test.n);assert(rejected.error,'RELATED_MEMBER_PREPARE_REJECT');assert.equal(rejected.result,undefined);}
 await finish(c);
},0);
if(mode==='project'||mode==='all')await client('rename-project',async c=>{
 const db=project+'/compile_commands.json',leaf=project+'/leaf/src/lib.cj',helper=project+'/helper/src/lib.cj',app=project+'/app/src/main.cj';const files=new Map([leaf,helper,app].map(p=>[p,fs.readFileSync(p,'utf8')]));
 await init(c,{initializationOptions:{compilationDatabase:db}});assert.deepEqual(await open(c,helper,files.get(helper)),[]);const r=await query(c,helper,files.get(helper),'answer()','rename','renamedAnswer');assert.equal(r.error,undefined,JSON.stringify(r));assert.equal(r.result.documentChanges.length,2);const updated=apply(r.result,files,new Map([[helper,1]]));assert(updated.get(leaf).includes('func renamedAnswer'));assert(updated.get(helper).includes('renamedAnswer()'));for(const [p,text]of updated){fs.writeFileSync(p,text);files.set(p,text);}buildProject("applied-rename");assert.deepEqual(await change(c,helper,files.get(helper),2),[],'APPLIED_SOURCE_GRAPH_REANALYSIS');
 // The live server uses disk CJO until the normal build refresh. Candidate
 // validation above used the newly exported CJO, not those original artifacts.
 await finish(c);
},0);
console.log('RENAME_STDIO_PASS mode='+mode);
