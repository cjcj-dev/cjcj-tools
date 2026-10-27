import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const [exe,sdk,directory,mode]=process.argv.slice(2);fs.mkdirSync(directory,{recursive:true});
const cases=[];
const encode=value=>{const body=typeof value==='string'?value:JSON.stringify(value);return Buffer.concat([Buffer.from(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n`),Buffer.from(body)]);};
async function client(label,body,expected){
 if(mode==='control'&&label!=='independent-shutdown')return;
 if(mode==='target'&&label!=='lifecycle-semantics')return;
 const env={...process.env};for(const key of ['LD_LIBRARY_PATH','LD_PRELOAD','LD_AUDIT','CANGJIE_HOME','CANGJIE_PATH'])delete env[key];
 const started=new Date().toISOString(),p=spawn(exe,['--sdk',sdk],{env,stdio:['pipe','pipe','pipe']});let data=Buffer.alloc(0),stderr='',ended=false;const transcript=[];const queue=[],waiters=[];
 const closed=new Promise(resolve=>{p.on('error',error=>resolve({error:String(error)}));p.on('close',(rc,signal)=>{ended=true;resolve({rc,signal})});});
 p.stderr.on('data',b=>stderr+=b);p.stdout.on('data',chunk=>{data=Buffer.concat([data,chunk]);for(;;){const boundary=data.indexOf('\r\n\r\n');if(boundary<0)break;const header=data.subarray(0,boundary).toString();const match=/^Content-Length: (\d+)$/m.exec(header);assert(match,'stdout is framed JSON-RPC, no compiler chatter');const size=Number(match[1]);if(data.length<boundary+4+size)break;const value=JSON.parse(data.subarray(boundary+4,boundary+4+size));data=data.subarray(boundary+4+size);transcript.push({direction:"receive",value});queue.push(value);for(const wake of waiters.splice(0))wake();}});
 async function take(predicate){const deadline=Date.now()+45000;while(Date.now()<deadline){let index=queue.findIndex(predicate);if(index>=0)return queue.splice(index,1)[0];if(ended)throw Error('server ended before response '+stderr);await Promise.race([new Promise(resolve=>waiters.push(resolve)),new Promise(resolve=>setTimeout(resolve,20))]);}throw Error('response timeout '+JSON.stringify(queue)+' '+stderr);}
 const api={send:value=>{transcript.push({direction:"send",value});p.stdin.write(encode(value));},raw:bytes=>{transcript.push({direction:"send-bytes",base64:bytes.toString("base64")});p.stdin.write(bytes);},take,end:()=>p.stdin.end()};
 const timeout=setTimeout(()=>p.kill('SIGTERM'),120000);let failure;
 try{await body(api);const result=await closed;assert.equal(result.rc,expected,label);assert.equal(result.signal,null);cases.push({label,argv:[exe,'--sdk',sdk],started,ended:new Date().toISOString(),...result,stderr,pass:true});}
 catch(e){failure=e;if(!ended)p.kill('SIGTERM');const result=await closed;cases.push({label,started,ended:new Date().toISOString(),...result,stderr,pass:false,error:e.stack});}
 finally{clearTimeout(timeout);fs.writeFileSync(directory+'/'+label+'-transcript.json',JSON.stringify(transcript,null,2));fs.writeFileSync(directory+'/client-results.json',JSON.stringify(cases,null,2));}
 if(failure)throw failure;
}
const a=path.join(directory,'first source.cj'),b=path.join(directory,'other.cj'),uri=pathToFileURL(a).href,other=pathToFileURL(b).href;
const text='package server_fixture\npublic class Box {\n public var value: Int64 = 7\n public init() {}\n}\npublic func answer(): Int64 { return 42 }\n';
const peer='package server_fixture\npublic func use(): Int64 { let text = "😀"; let b = Box(); return b.value + answer() }\n';
fs.writeFileSync(a,text);fs.writeFileSync(b,peer);
const request=(id,method,params={})=>({jsonrpc:'2.0',id,method,params});const note=(method,params={})=>({jsonrpc:'2.0',method,params});
const pos=(s,needle)=>{const at=s.indexOf(needle);assert(at>=0);const lines=s.slice(0,at).split('\n');return {line:lines.length-1,character:lines.at(-1).length};};
await client('lifecycle-semantics',async c=>{
 c.send(request(0,'textDocument/definition'));assert.equal((await c.take(x=>x.id===0)).error.code,-32002);
 const init=encode(request('init','initialize',{capabilities:{general:{positionEncodings:['utf-16']}}}));c.raw(init.subarray(0,9));c.raw(init.subarray(9));
 const result=await c.take(x=>x.id==='init');assert.equal(result.result.capabilities.positionEncoding,'utf-16');
 c.send(note('initialized'));c.send(note('textDocument/didOpen',{textDocument:{uri,languageId:'cangjie',version:1,text}}));
 assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri&&x.params.version===1)).params.diagnostics,[]);
 const opened=encode(note('textDocument/didOpen',{textDocument:{uri:other,languageId:'cangjie',version:1,text:peer}}));const emoji=opened.indexOf(Buffer.from('😀'));c.raw(opened.subarray(0,emoji+2));c.raw(opened.subarray(emoji+2));
 const diag=await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===other);assert.deepEqual(diag.params.diagnostics,[]);
 c.send(request(1,'textDocument/definition',{textDocument:{uri:other},position:pos(peer,'value +')}));
 const member=await c.take(x=>x.id===1);assert(member.result,'LSP_MEMBER_DEFINITION_TARGET');assert.equal(member.result.uri,uri);assert.deepEqual(member.result.range.start,pos(text,'value:'));
 c.send(request(2,'textDocument/definition',{textDocument:{uri:other},position:pos(peer,'answer()')}));
 const def=await c.take(x=>x.id===2);assert.equal(def.result.uri,uri);assert.deepEqual(def.result.range.start,pos(text,'answer()'));
 c.send(request(3,'textDocument/references',{textDocument:{uri},position:pos(text,'answer()'),context:{includeDeclaration:false}}));
 const refs=await c.take(x=>x.id===3);assert.equal(refs.result.length,1);assert.equal(refs.result[0].uri,other);
 c.send(note('textDocument/didChange',{textDocument:{uri,version:2},contentChanges:[{text:text.replace('return 42','return true')}]}));
 const broken=await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri&&x.params.version===2);assert(broken.params.diagnostics.some(x=>x.severity===1&&x.message.length>0),'actual compiler type diagnostic');
 const range={start:pos(text,'42'),end:{...pos(text,'42'),character:pos(text,'42').character+4}};
 c.send(note('textDocument/didChange',{textDocument:{uri,version:3},contentChanges:[{range,text:'42'}]}));
 assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri&&x.params.version===3)).params.diagnostics,[]);
 c.send(request(4,'textDocument/definition',{textDocument:{uri:other},position:pos(peer,'answer()')}));assert.equal((await c.take(x=>x.id===4)).result.uri,uri);
 c.send(note('textDocument/didClose',{textDocument:{uri:other}}));await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===other&&x.params.diagnostics.length===0);
 c.send(request(5,'textDocument/definition',{textDocument:{uri:other},position:{line:1,character:1}}));assert.equal((await c.take(x=>x.id===5)).error.code,-32602);
 c.raw(Buffer.concat([encode(request(6,'not/a/method')),encode('{broken-json}')]));assert.equal((await c.take(x=>x.id===6)).error.code,-32601);assert.equal((await c.take(x=>x.error?.code===-32700)).id,null);
 c.send(request(7,'shutdown'));assert.equal((await c.take(x=>x.id===7)).result,null);c.send(note('exit'));c.end();
},0);
await client('exit-before-shutdown',async c=>{c.send(note('exit'));c.end()},1);
await client('truncated-frame',async c=>{c.raw(Buffer.from('Content-Length: 90\r\n\r\n{}'));c.end()},2);

if(mode==='control')await client('independent-shutdown',async c=>{c.send(request('control-init','initialize'));assert((await c.take(x=>x.id==='control-init')).result.capabilities);c.send(request('control-stop','shutdown'));assert.equal((await c.take(x=>x.id==='control-stop')).result,null);c.send(note('exit'));c.end();},0);

console.log('LSP_SERVER_CLIENT_PASS processes='+cases.length+' mode='+(mode??'all'));
