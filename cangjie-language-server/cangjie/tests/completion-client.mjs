import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const [exe,sdk,directory,project,mode='basic']=process.argv.slice(2);
fs.mkdirSync(directory,{recursive:true});
const cases=[];
const encode=value=>{const body=typeof value==='string'?value:JSON.stringify(value);return Buffer.concat([Buffer.from(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n`),Buffer.from(body)]);};
async function client(label,body,expected,selectedSdk=sdk){
 const env={...process.env};for(const key of ['LD_LIBRARY_PATH','LD_PRELOAD','LD_AUDIT','CANGJIE_HOME','CANGJIE_PATH']){delete env[key];}
 const started=new Date().toISOString(),p=spawn(exe,['--sdk',selectedSdk],{env,stdio:['pipe','pipe','pipe']});let data=Buffer.alloc(0),stderr='',ended=false;const transcript=[];const queue=[],waiters=[];
 const closed=new Promise(resolve=>{p.on('error',error=>resolve({error:String(error)}));p.on('close',(rc,signal)=>{ended=true;resolve({rc,signal})});});
 p.stderr.on('data',b=>stderr+=b);p.stdout.on('data',chunk=>{transcript.push({direction:'receive-bytes',base64:chunk.toString('base64')});data=Buffer.concat([data,chunk]);for(;;){const boundary=data.indexOf('\r\n\r\n');if(boundary<0)break;const header=data.subarray(0,boundary).toString();const match=/^Content-Length: (\d+)$/m.exec(header);assert(match,'stdout is framed JSON-RPC, no compiler chatter');const size=Number(match[1]);if(data.length<boundary+4+size)break;const value=JSON.parse(data.subarray(boundary+4,boundary+4+size));data=data.subarray(boundary+4+size);transcript.push({direction:"receive",value});queue.push(value);for(const wake of waiters.splice(0))wake();}});
 async function take(predicate){const deadline=Date.now()+180000;while(Date.now()<deadline){let index=queue.findIndex(predicate);if(index>=0)return queue.splice(index,1)[0];if(ended)throw Error('server ended before response '+stderr);await Promise.race([new Promise(resolve=>waiters.push(resolve)),new Promise(resolve=>setTimeout(resolve,20))]);}throw Error('response timeout '+JSON.stringify(queue)+' '+stderr);}
 const api={send:value=>{transcript.push({direction:"send",value});p.stdin.write(encode(value));},raw:bytes=>{transcript.push({direction:"send-bytes",base64:bytes.toString("base64")});p.stdin.write(bytes);},take,drain:()=>queue.splice(0),end:()=>p.stdin.end()};
 const timeout=setTimeout(()=>p.kill('SIGTERM'),210000);let failure;
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
 const exe=project+'/target/release/bin/completion_app';assert(recipe.targetEnv,'explicit qualified target runtime environment');const env=recipe.targetEnv;
 const loader=spawnSync('ldd',[exe],{env,encoding:'utf8'});fs.writeFileSync(directory+'/'+label+'-loader.json',JSON.stringify({argv:['ldd',exe],env,rc:loader.status,stdout:loader.stdout,stderr:loader.stderr},null,2));assert.equal(loader.status,0);assert(!loader.stdout.includes('not found'));assert(!loader.stdout.includes('/input/H/'));
 const run=spawnSync(exe,[],{cwd:project,env,encoding:'utf8',timeout:30000});fs.writeFileSync(directory+'/'+label+'-run.json',JSON.stringify({argv:[exe],cwd:project,env,rc:run.status,signal:run.signal,error:run.error?.message??null,stdout:run.stdout,stderr:run.stderr},null,2));assert.equal(run.status,0,label+' actual program '+run.error+' '+run.stderr);
}

let serial=0;
async function finish(c){c.send(request('stop','shutdown'));assert.equal((await c.take(x=>x.id==='stop')).result,null);c.send(note('exit'));c.end();}
async function init(c,opts={}){c.send(request('init','initialize',opts));const r=await c.take(x=>x.id==='init');assert.deepEqual(r.result.capabilities.completionProvider.triggerCharacters,['.']);c.send(note('initialized'));}
async function open(c,p,text,version=1){c.send(note('textDocument/didOpen',{textDocument:{uri:uri(p),languageId:'cangjie',version,text}}));return (await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(p)&&x.params.version===version)).params.diagnostics;}
async function change(c,p,text,version){c.send(note('textDocument/didChange',{textDocument:{uri:uri(p),version},contentChanges:[{text}]}));return (await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(p)&&x.params.version===version)).params.diagnostics;}
function marked(input){const index=input.indexOf('|');assert(index>=0);const text=input.slice(0,index)+input.slice(index+1),lines=text.slice(0,index).split('\n');return {text,point:{line:lines.length-1,character:lines.at(-1).length}};}
async function complete(c,p,point){const id='q'+(++serial);c.send(request(id,'textDocument/completion',{textDocument:{uri:uri(p)},position:point}));return await c.take(x=>x.id===id);}
function offset(text,p){const lines=text.split('\n');return lines.slice(0,p.line).reduce((n,s)=>n+s.length+1,0)+p.character;}
function apply(text,item){const edit=item.textEdit;return text.slice(0,offset(text,edit.range.start))+edit.newText+text.slice(offset(text,edit.range.end));}
const prefix='package completion_user\n';
const generic=prefix+'class Box<T> {\n public let value: T\n private let secret: Int64 = 9\n public init(item: T) { value = item }\n}\n';
const fixtures=[
 {label:'constraint-positive',input:prefix+'interface Allowed {}\nclass Value <: Allowed { public init() {} }\nclass Box<T> { public let value: T; public init(item: T) { value = item } }\nextend<T> Box<T> where T <: Allowed { public func gate(): Int64 { 42 } }\nfunc use(box: Box<Value>): Int64 { box.ga|te() }\n',name:'gate',typeIncludes:'Int64'},
 {label:'constraint-negative',input:prefix+'interface Allowed {}\nclass Box<T> { public let value: T; public init(item: T) { value = item } }\nextend<T> Box<T> where T <: Allowed { public func gate(): Int64 { 42 } }\nfunc use(box: Box<Int64>): Int64 { box.ga| }\n',empty:true},
 {label:'protected-same-package',input:prefix+'open class Base { public let value: Int64 = 42; protected let secret: Int64 = 7; public init() {} }\nfunc use(item: Base): Int64 { item.se| }\n',name:'secret',type:'secret: Int64'},
 {label:'wrong-instance',input:prefix+'class Holder { public let value: Int64 = 42; public static let answer: Int64 = 42; public init() {} }\nfunc use(): Int64 { Holder.va| }\n',empty:true},

 {label:'type-context',input:generic+'func use(): Unit { let item: Bo|x<Int64> = Box<Int64>(42) }\n',name:'Box',typeIncludes:'Box'},
 {label:'generic-bool',input:generic+'func use(box: Box<Bool>): Bool { return box.va| }\n',name:'value',type:'value: Bool'},
 {label:'inherited',input:prefix+'open class Base { public let value: Int64 = 42; public init() {} }\nclass Child <: Base { public init() { super() } }\nfunc use(child: Child): Int64 { child.va| }\n',name:'value',type:'value: Int64'},
 {label:'static',input:prefix+'class Holder { public init() {}; public static func answer(): Int64 { 42 } }\nfunc use(): Int64 { Holder.ans|wer() }\n',name:'answer',typeIncludes:'Int64'},
 {label:'overload',input:prefix+'func answer(x: Int64): Int64 { x }\nfunc answer(x: Bool): Bool { x }\nfunc use(): Int64 { ans|wer(42) }\n',name:'answer',typeIncludes:'Int64'},
 {label:'extension',input:generic+'extend<T> Box<T> { public func read(): T { value } }\nfunc use(box: Box<Int64>): Int64 { box.re|ad() }\n',name:'read',typeIncludes:'Int64'},
 {label:'empty-token',input:prefix+'func use(): Int64 { let answer = 42; return | }\n',name:'answer',type:'answer: Int64'},

 {label:'local',input:prefix+'main(): Int64 { let answer: Int64 = 42; return an| }\n',name:'answer',type:'answer: Int64',absent:['noSuchName']},
 {label:'shadow',input:prefix+'func use(): Unit { let shadow: Int64 = 1; if (true) { let shadow: Bool = true; let value = sh| } }\n',name:'shadow',type:'shadow: Bool'},
 {label:'member',input:generic+'func use(box: Box<Int64>): Int64 { return box.va| }\n',name:'value',type:'value: Int64',absent:['secret']},
 {label:'member-all',input:generic+'func use(box: Box<Int64>): Int64 { return box.| }\n',name:'value',type:'value: Int64',absent:['secret']},
 {label:'private-filter',input:generic+'func use(box: Box<Int64>): Int64 { return box.se| }\n',empty:true},
 {label:'later-filter',input:prefix+'func use(): Unit { let valid = 7; let output = lat|; let later = 9 }\n',empty:true},
 {label:'utf16',input:prefix+'func use(parameter: Int64): Int64 { /* 😀 */ return para|meter }\n',name:'parameter',type:'parameter: Int64'},
 {label:'unrelated-error',input:prefix+'func use(): Int64 { let answer = 42; let broken: Bool = 1; return an| }\n',error:true},
 {label:'comment',input:prefix+'func use(): Int64 { /* ans|wer */ return 42 }\n',error:true},
 {label:'string',input:prefix+'func use(): Unit { let text = "ans|wer" }\n',error:true},
 {label:'empty-match',input:prefix+'func use(): Int64 { let answer = 42; return zzz| }\n',empty:true},
];
for(const test of fixtures.filter(test=>mode==='basic'||mode.split(',').includes(test.label))){
 await client(test.label,async c=>{
  const p=path.join(directory,test.label+'.cj'),input=marked(test.input);fs.writeFileSync(p,input.text);
  await init(c);await open(c,p,input.text);const result=await complete(c,p,input.point);
  if(test.error){assert.equal(result.error?.code,-32602,'COMPLETION_ERROR_SNAPSHOT_TARGET '+test.label);}
  else {
   assert.equal(result.error,undefined,'COMPLETION_SEMANTIC_TARGET '+test.label+' '+JSON.stringify(result));
   assert.equal(result.result.isIncomplete,false);const items=result.result.items;
   if(test.empty)assert.deepEqual(items,[],'COMPLETION_FILTER_TARGET '+test.label);
   else{
    const item=items.find(x=>x.label===test.name);assert(item,'COMPLETION_BINDING_TARGET '+test.label+' '+JSON.stringify(items));
    if(test.type)assert.equal(item.detail,test.type,'COMPLETION_TYPE_TARGET '+test.label); if(test.typeIncludes)assert(item.detail.includes(test.typeIncludes),'COMPLETION_RESOLVED_TYPE_TARGET '+test.label+' '+item.detail);
    for(const name of test.absent??[])assert(!items.some(x=>x.label===name),'COMPLETION_VISIBILITY_TARGET '+name);
    const edited=apply(input.text,item);fs.writeFileSync(p+'.applied',edited);
    const diagnostics=await change(c,p,edited,2);assert.deepEqual(diagnostics,[],'COMPLETION_APPLIED_SEMA_TARGET '+test.label);
   }
  }
  await finish(c);
 },0);
}
console.log('COMPLETION_STDIO_PASS '+cases.length);

if(mode==='project')await client('completion-project',async c=>{
 const db=project+'/compile_commands.json',helper=project+'/helper/src/lib.cj';
 let version=1;
 const initial=fs.readFileSync(helper,'utf8');
 await init(c,{initializationOptions:{compilationDatabase:db}});assert.deepEqual(await open(c,helper,initial,version),[]);
 const samples=[
  {label:'imported',code:'package completion_helper\nimport completion_leaf.*\npublic func forwarded(): Int64 { ans|wer() }\n',name:'answer'},
  {label:'alias',code:'package completion_helper\nimport completion_leaf.answer as importedAnswer\npublic func forwarded(): Int64 { importedAn|swer() }\n',name:'importedAnswer'},
  {label:'qualified',code:'package completion_helper\nimport completion_leaf\npublic func forwarded(): Int64 { completion_leaf.ans|wer() }\n',name:'answer'},
 ];
 for(const sample of samples){
  const input=marked(sample.code.replaceAll('\\n','\n'));await change(c,helper,input.text,++version);
  const result=await complete(c,helper,input.point);assert.equal(result.error,undefined,'COMPLETION_PROJECT_TARGET '+sample.label+' '+JSON.stringify(result));
  const item=result.result.items.find(x=>x.label===sample.name);assert(item,'COMPLETION_IMPORT_BINDING '+sample.label);assert(item.detail.includes('Int64'));
  const applied=apply(input.text,item);assert.deepEqual(await change(c,helper,applied,++version),[],'COMPLETION_IMPORT_APPLY '+sample.label);fs.writeFileSync(helper,applied);buildProject('completion-'+sample.label);
 }
 const module=project+'/target/release/completion_leaf/completion_leaf.cjo';const hidden=module+'.completion-missing';assert(fs.existsSync(module));assert(!fs.existsSync(hidden));fs.renameSync(module,hidden);
 try{
  c.drain();c.send(note('workspace/didChangeConfiguration',{settings:{compilationDatabase:db}}));const d=(await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(helper))).params.diagnostics;assert(d.some(x=>x.severity===1));
  const text=fs.readFileSync(helper,'utf8');const result=await complete(c,helper,position(text,'answer()'));assert(result.error,'COMPLETION_MISSING_CJO_REJECT');assert.equal(result.result,undefined);
 }finally{fs.renameSync(hidden,module);}
 c.drain();c.send(note('workspace/didChangeConfiguration',{settings:{compilationDatabase:db}}));assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(helper))).params.diagnostics,[]);
 const text=fs.readFileSync(helper,'utf8');assert.equal((await complete(c,helper,position(text,'answer()'))).error,undefined,'COMPLETION_RESTORED_CJO');
 await finish(c);
},0);

if(mode==='accessibility')await client('completion-accessibility',async c=>{
 const db=project+'/compile_commands.json',leaf=project+'/leaf/src/lib.cj',helper=project+'/helper/src/lib.cj';
 fs.writeFileSync(directory+'/prior-leaf.cj',fs.readFileSync(leaf));fs.writeFileSync(directory+'/prior-helper.cj',fs.readFileSync(helper));
 const guard='\npublic open class Guard { public let value: Int64 = 42; protected let secret: Int64 = 7; private let privateValue: Int64 = 9; let packageValue: Int64 = 8; public init() {} }\n';
 const prepared=fs.readFileSync(leaf,'utf8').includes(guard);if(!prepared)fs.appendFileSync(leaf,guard);
 const base='package completion_helper\nimport completion_leaf.*\npublic func forwarded(): Int64 { 42 }\n';if(prepared){assert.equal(fs.readFileSync(helper,'utf8'),base);fs.writeFileSync(directory+'/reused-input.json',JSON.stringify({leaf,helper,reason:'unchanged normal CJO/build/loader/run from accessibility-v1; only diagnostic severity assertion corrected'}));}else{fs.writeFileSync(helper,base);buildProject('accessibility-input');}
 await init(c,{initializationOptions:{compilationDatabase:db}});let version=1;assert.deepEqual((await open(c,helper,base,version)).filter(x=>x.severity===1),[]);
 for(const name of ['secret','privateValue','packageValue']){
  const completeText=base+'func inspect(item: Guard): Int64 { item.'+name+' }\n';
  const rejected=await change(c,helper,completeText,++version);assert(rejected.some(x=>x.severity===1),'ACTUAL_SEMA_ACCESS_REJECTION '+name);fs.writeFileSync(directory+'/'+name+'-actual-diagnostics.json',JSON.stringify(rejected,null,2));
  const input=marked(base+'func inspect(item: Guard): Int64 { item.'+name.slice(0,2)+'| }\n');await change(c,helper,input.text,++version);
  const result=await complete(c,helper,input.point);assert.equal(result.error,undefined,'COMPLETION_ACCESS_CONTEXT '+JSON.stringify(result));assert.deepEqual(result.result.items,[],'COMPLETION_ACCESS_FILTER '+name);
 }
 const input=marked(base+'func inspect(item: Guard): Int64 { item.va| }\n');await change(c,helper,input.text,++version);const normal=await complete(c,helper,input.point);assert.equal(normal.error,undefined);const item=normal.result.items.find(x=>x.label==='value');assert.equal(item?.detail,'value: Int64');assert.deepEqual(await change(c,helper,apply(input.text,item),++version),[]);
 await finish(c);
},0);

if(mode==='import-statement')await client('completion-import-statement',async c=>{
 const db=project+'/compile_commands.json',helper=project+'/helper/src/lib.cj';let version=1;
 const input=marked('package completion_helper\nimport completion_leaf.ans|wer\npublic func forwarded(): Int64 { answer() }\n');
 await init(c,{initializationOptions:{compilationDatabase:db}});await open(c,helper,input.text,version);
 const result=await complete(c,helper,input.point);assert.equal(result.error,undefined,'COMPLETION_IMPORT_STATEMENT '+JSON.stringify(result));
 const item=result.result.items.find(x=>x.label==='answer');assert(item);assert(item.detail.includes('Int64'));
 const applied=apply(input.text,item);assert.deepEqual(await change(c,helper,applied,++version),[]);fs.writeFileSync(helper,applied);buildProject('import-statement-applied');
 await finish(c);
},0);
