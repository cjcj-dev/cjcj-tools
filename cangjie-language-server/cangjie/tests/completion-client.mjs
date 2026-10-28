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
