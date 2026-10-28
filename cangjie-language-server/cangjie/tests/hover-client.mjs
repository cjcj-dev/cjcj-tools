import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {pathToFileURL} from 'node:url';
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
const source=`package hover_sample
func same<T>(item: T): T { item }
func pick(item: Int64): Int64 { item }
func pick(item: Bool): Bool { item }
class Holder {
    public var value: Int64 = 7
    public init() {}
    public func get(): Int64 { value }
}
func use(parameter: Int64): Int64 {
    let explicit: Int64 = parameter
    let inferred = explicit
    let holder = Holder()
    let member = holder.value
    let method = holder.get()
    let generic = same<Int64>(inferred)
    let chosen = pick(explicit)
    let boolean = pick(true)
    let shadow: Int64 = 9
    if (true) {
        let shadow: Bool = false
        let inner = shadow
    }
    /* 😀 */ let unicode: Int64 = inferred
    return unicode + member + method + generic + chosen + shadow
}
`;
async function finish(c){c.send(request('stop','shutdown'));assert.equal((await c.take(x=>x.id==='stop')).result,null);c.send(note('exit'));c.end();}
async function init(c,opts={}){c.send(request('init','initialize',opts));const r=await c.take(x=>x.id==='init');assert.equal(r.result.capabilities.hoverProvider,true);c.send(note('initialized'));}
async function open(c,p,text,version=1){c.send(note('textDocument/didOpen',{textDocument:{uri:uri(p),languageId:'cangjie',version,text}}));return (await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(p)&&x.params.version===version)).params.diagnostics;}
async function change(c,p,text,version){c.send(note('textDocument/didChange',{textDocument:{uri:uri(p),version},contentChanges:[{text}]}));return (await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(p)&&x.params.version===version)).params.diagnostics;}
let serial=0;
async function query(c,p,text,needle,method='hover',n=0){const id='q'+(++serial);c.send(request(id,'textDocument/'+method,{textDocument:{uri:uri(p)},position:position(text,needle,n)}));const r=await c.take(x=>x.id===id);assert.equal(r.error,undefined);return r.result;}
async function hover(c,p,text,needle,name,type,n=0){const r=await query(c,p,text,needle,'hover',n);assert(r,'HOVER_RESOLVED_TYPE_TARGET '+needle);assert.equal(r.contents.kind,'plaintext');assert.equal(r.contents.value,name+': '+type,'HOVER_RESOLVED_TYPE_TARGET '+needle);const start=position(text,needle,n);assert.deepEqual(r.range,{start,end:{line:start.line,character:start.character+name.length}},'HOVER_REQUEST_UTF16_RANGE');return r;}
if(mode!=='project')await client(mode==='control'?'definition-control':'resolved-hover',async c=>{
 const p=path.join(directory,'use.cj');fs.writeFileSync(p,source);await init(c);assert.deepEqual(await open(c,p,source),[],'VALID_HOVER_SOURCE');
 if(mode==='control'){const result=await query(c,p,source,'pick(explicit)','definition');assert.equal(result.uri,uri(p));assert.equal(result.range.start.line,2);await finish(c);return;}
 await hover(c,p,source,'explicit:','explicit','Int64');
 if(mode==='target'){await finish(c);return;}
 await hover(c,p,source,'parameter\n','parameter','Int64');
 await hover(c,p,source,'inferred =','inferred','Int64');
 await hover(c,p,source,'value\n','value','Int64');
 await hover(c,p,source,'get()\n','get','() -> Int64');
 await hover(c,p,source,'same<Int64>','same','(Int64) -> Int64');
 await hover(c,p,source,'pick(explicit)','pick','(Int64) -> Int64');
 await hover(c,p,source,'pick(true)','pick','(Bool) -> Bool');
 await hover(c,p,source,'shadow\n','shadow','Bool');
 await hover(c,p,source,'shadow\n','shadow','Int64',1);
 await hover(c,p,source,'unicode:','unicode','Int64');
 await hover(c,p,source,'same<T>','same','(T) -> T');
 assert.equal(await query(c,p,source,'/* 😀 */'),null,'comment is not a symbol');
 const boundary=position(source,'explicit:');boundary.character+='explicit'.length;const edge='q'+(++serial);c.send(request(edge,'textDocument/hover',{textDocument:{uri:uri(p)},position:boundary}));assert.equal((await c.take(x=>x.id===edge)).result,null);
 const simple='package hover_sample\nfunc answer(): Int64 { let value: Int64 = 4; return value }\n';
 assert.deepEqual(await change(c,p,simple,2),[]);await hover(c,p,simple,'value:','value','Int64');
 const bool=simple.replaceAll('Int64','Bool').replace('= 4','= true');assert.deepEqual(await change(c,p,bool,3),[]);await hover(c,p,bool,'value:','value','Bool');
 const bad=bool.replace('= true','= 4');assert((await change(c,p,bad,4)).some(d=>d.severity===1));assert.equal(await query(c,p,bad,'value:'),null,'failed snapshot must not keep hover');
 assert.deepEqual(await change(c,p,source,5),[]);await hover(c,p,source,'explicit:','explicit','Int64');
 const malformed='bad-params';c.send(request(malformed,'textDocument/hover',{textDocument:{uri:uri(p)},position:{line:'bad',character:0}}));assert.equal((await c.take(x=>x.id===malformed)).error.code,-32602);
 await finish(c);
},0);
if(mode==='all'||mode==='project')await client('project-hover',async c=>{
 const db=project+'/compile_commands.json',app=project+'/app/source-code/value.cj',helper=project+'/helper/source-code/value.cj',a=fs.readFileSync(app,'utf8'),h=fs.readFileSync(helper,'utf8');
 await init(c,{initializationOptions:{compilationDatabase:db}});assert.deepEqual(await open(c,app,a),[]);
 await hover(c,app,a,'forwarded()','forwarded','() -> Int64');
 assert.deepEqual(await open(c,helper,h),[]);await hover(c,helper,h,'diskAnswer()','diskAnswer','() -> Int64');
 await hover(c,app,a,'answer()','answer','() -> Int64');
 // Open buffer wins; close must restore the same file's disk snapshot.
 const overlay=h+'\nfunc bufferOnly(): Bool { true }\n';assert.deepEqual(await change(c,helper,overlay,2),[]);await hover(c,helper,overlay,'bufferOnly()','bufferOnly','() -> Bool');
 c.send(note('textDocument/didClose',{textDocument:{uri:uri(helper)}}));c.send(request('barrier-close','textDocument/hover',{textDocument:{uri:uri(helper)},position:position(h,'diskAnswer()')}));const closed=await c.take(x=>x.id==='barrier-close');assert.equal(closed.result.contents.value,'diskAnswer: () -> Int64');
 assert.equal(await query(c,helper,overlay,'bufferOnly()'),null,'closed disk must not keep buffer declaration');
 c.drain();c.send(note('workspace/didChangeConfiguration',{settings:{compilationDatabase:db+'.missing'}}));await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(app)&&x.params.diagnostics.some(d=>d.severity===1));assert.equal(await query(c,app,a,'forwarded()'),null,'failed graph clears hover');
 c.drain();c.send(note('workspace/didChangeConfiguration',{settings:{compilationDatabase:db}}));await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri(app)&&x.params.diagnostics.length===0);await hover(c,app,a,'forwarded()','forwarded','() -> Int64');
 await finish(c);
},0);
console.log('HOVER_STDIO_PASS mode='+mode);
