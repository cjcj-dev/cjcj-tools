import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const [exe,sdk,directory,mode]=process.argv.slice(2);fs.mkdirSync(directory,{recursive:true});
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
 const env={...process.env};for(const key of ['LD_LIBRARY_PATH','LD_PRELOAD','LD_AUDIT','CANGJIE_HOME','CANGJIE_PATH'])delete env[key];
 const started=new Date().toISOString(),p=spawn(exe,['--sdk',selectedSdk],{env,stdio:['pipe','pipe','pipe']});let data=Buffer.alloc(0),stderr='',ended=false;const transcript=[];const queue=[],waiters=[];
 const closed=new Promise(resolve=>{p.on('error',error=>resolve({error:String(error)}));p.on('close',(rc,signal)=>{ended=true;resolve({rc,signal})});});
 p.stderr.on('data',b=>stderr+=b);p.stdout.on('data',chunk=>{transcript.push({direction:'receive-bytes',base64:chunk.toString('base64')});data=Buffer.concat([data,chunk]);for(;;){const boundary=data.indexOf('\r\n\r\n');if(boundary<0)break;const header=data.subarray(0,boundary).toString();const match=/^Content-Length: (\d+)$/m.exec(header);assert(match,'stdout is framed JSON-RPC, no compiler chatter');const size=Number(match[1]);if(data.length<boundary+4+size)break;const value=JSON.parse(data.subarray(boundary+4,boundary+4+size));data=data.subarray(boundary+4+size);transcript.push({direction:"receive",value});queue.push(value);for(const wake of waiters.splice(0))wake();}});
 async function take(predicate){const deadline=Date.now()+45000;while(Date.now()<deadline){let index=queue.findIndex(predicate);if(index>=0)return queue.splice(index,1)[0];if(ended)throw Error('server ended before response '+stderr);await Promise.race([new Promise(resolve=>waiters.push(resolve)),new Promise(resolve=>setTimeout(resolve,20))]);}throw Error('response timeout '+JSON.stringify(queue)+' '+stderr);}
 const api={send:value=>{transcript.push({direction:"send",value});p.stdin.write(encode(value));},raw:bytes=>{transcript.push({direction:"send-bytes",base64:bytes.toString("base64")});p.stdin.write(bytes);},take,end:()=>p.stdin.end()};
 const timeout=setTimeout(()=>p.kill('SIGTERM'),120000);let failure;
 try{await body(api);const result=await closed;assert.equal(result.rc,expected,label);assert.equal(result.signal,null);cases.push({label,argv:[exe,'--sdk',selectedSdk],started,ended:new Date().toISOString(),...result,stderr,pass:true});}
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


// Same resolved positions are queried before, during and after a real SEMA
// error. A null response cannot pass solely because the position had no index.
await client('error-snapshot-queries',async c=>{
 c.send(request('snapshot-init','initialize'));assert((await c.take(x=>x.id==='snapshot-init')).result.capabilities);
 c.send(note('initialized'));
 c.send(note('textDocument/didOpen',{textDocument:{uri,languageId:'cangjie',version:1,text}}));
 assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri&&x.params.version===1)).params.diagnostics,[]);
 c.send(note('textDocument/didOpen',{textDocument:{uri:other,languageId:'cangjie',version:1,text:peer}}));
 assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===other)).params.diagnostics,[]);
 async function query(id,method,document,position){
  c.send(request(id,method,{textDocument:{uri:document},position,...(method.endsWith('/references')?{context:{includeDeclaration:false}}:{})}));
  const reply=await c.take(x=>x.id===id);assert.equal(reply.error,undefined);assert(Object.hasOwn(reply,'result'));return reply.result;
 }
 async function validQueries(prefix){
  const definition=await query(prefix+'-definition','textDocument/definition',other,pos(peer,'answer()'));
  assert(definition,'LSP_VALID_SNAPSHOT_DEFINITION_CONTROL');assert.equal(definition.uri,uri);assert.deepEqual(definition.range.start,pos(text,'answer()'));
  const references=await query(prefix+'-references','textDocument/references',uri,pos(text,'answer()'));
  assert.equal(references.length,1,'LSP_VALID_SNAPSHOT_REFERENCES_CONTROL');assert.equal(references[0].uri,other);assert.deepEqual(references[0].range.start,pos(peer,'answer()'));
 }
 await validQueries('before');
 c.send(note('textDocument/didChange',{textDocument:{uri,version:2},contentChanges:[{text:text.replace('return 42','return true')}]}));
 const broken=await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri&&x.params.version===2);
 assert(broken.params.diagnostics.some(x=>x.severity===1&&x.message.length>0),'LSP_ERROR_SNAPSHOT_DIAGNOSTIC_REACHED');
 for(const [tag,document,at] of [['changed',uri,pos(text,'answer()')],['dependent',other,pos(peer,'answer()')]]){
  assert.equal(await query('bad-'+tag+'-definition','textDocument/definition',document,at),null,'LSP_ERROR_SNAPSHOT_DEFINITION_REJECT '+tag);
  assert.equal(await query('bad-'+tag+'-references','textDocument/references',document,at),null,'LSP_ERROR_SNAPSHOT_REFERENCES_REJECT '+tag);
 }
 c.send(note('textDocument/didChange',{textDocument:{uri,version:3},contentChanges:[{text}]}));
 assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===uri&&x.params.version===3)).params.diagnostics,[]);
 await validQueries('restored');
 c.send(request('snapshot-shutdown','shutdown'));assert.equal((await c.take(x=>x.id==='snapshot-shutdown')).result,null);c.send(note('exit'));c.end();
},0);

await client('workspace-unopened-siblings',async c=>{
 const project=path.join(directory,'workspace with spaces');fs.mkdirSync(project,{recursive:true});
 const disk=path.join(project,'definition.cj'),use=path.join(project,'use.cj');
 const diskUri=pathToFileURL(disk).href,useUri=pathToFileURL(use).href;
 const definition='package workspace_case\npublic func diskAnswer(): Int64 { return 42 }\n';
 const source='package workspace_case\npublic func use(): Int64 { return diskAnswer() }\n';
 fs.writeFileSync(disk,definition);fs.writeFileSync(use,source);
 c.send(request('workspace-init','initialize',{workspaceFolders:[{uri:pathToFileURL(project).href,name:'workspace'}]}));
 assert((await c.take(x=>x.id==='workspace-init')).result.capabilities);
 c.send(note('initialized'));c.send(note('textDocument/didOpen',{textDocument:{uri:useUri,languageId:'cangjie',version:1,text:source}}));
 assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===useUri)).params.diagnostics,[],'LSP_UNOPENED_SIBLING_ANALYZED');
 const query=async(id,method,uri,text)=>{c.send(request(id,method,{textDocument:{uri},position:pos(text,'diskAnswer()'),...(method.endsWith('references')?{context:{includeDeclaration:false}}:{})}));return await c.take(x=>x.id===id);};
 const found=await query('disk-definition','textDocument/definition',useUri,source);
 assert.equal(found.result.uri,diskUri,'LSP_UNOPENED_DEFINITION_TARGET');assert.deepEqual(found.result.range.start,pos(definition,'diskAnswer()'));
 const refs=await query('disk-references','textDocument/references',diskUri,definition);
 assert.equal(refs.result.length,1);assert.equal(refs.result[0].uri,useUri,'LSP_UNOPENED_QUERY_TARGET');
 // Disk is now invalid. An opened valid overlay must take precedence.
 fs.writeFileSync(disk,definition.replace('return 42','return true'));
 c.send(note('textDocument/didOpen',{textDocument:{uri:diskUri,languageId:'cangjie',version:1,text:definition}}));
 assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===diskUri)).params.diagnostics,[]);
 assert.equal((await query('overlay-definition','textDocument/definition',useUri,source)).result.uri,diskUri);
 c.send(note('textDocument/didClose',{textDocument:{uri:diskUri}}));
 c.send(request('disk-error-barrier','textDocument/definition',{textDocument:{uri:useUri},position:pos(source,'diskAnswer()')}));
 assert.equal((await c.take(x=>x.id==='disk-error-barrier')).result,null,'LSP_CLOSED_DISK_ERROR_REJECT');
 fs.writeFileSync(disk,definition);
 c.send(note('workspace/didChangeWatchedFiles',{changes:[{uri:diskUri,type:2}]}));
 assert.equal((await query('disk-restored','textDocument/definition',useUri,source)).result.uri,diskUri,'LSP_DISK_EVENT_RESTORES_INDEX');
 c.send(request('workspace-shutdown','shutdown'));assert.equal((await c.take(x=>x.id==='workspace-shutdown')).result,null);c.send(note('exit'));c.end();
},0);

if(mode==='control')await client('independent-shutdown',async c=>{c.send(request('control-init','initialize'));assert((await c.take(x=>x.id==='control-init')).result.capabilities);c.send(request('control-stop','shutdown'));assert.equal((await c.take(x=>x.id==='control-stop')).result,null);c.send(note('exit'));c.end();},0);



async function highlightCase(c,onlyDefinition=false){
 const project=path.join(directory,'highlight project');fs.mkdirSync(project,{recursive:true});
 const definitionPath=path.join(project,'definition.cj'),usePath=path.join(project,'use.cj');
 const definitionUri=pathToFileURL(definitionPath).href,useUri=pathToFileURL(usePath).href;
 const definition='package highlight_case\npublic func target(): Int64 { return 42 }\n';
 const use='package highlight_case\npublic func use(): Int64 { let emoji = "😀"; return target() + target() }\npublic func shadow(target: Int64): Int64 { return target + target }\n';
 fs.writeFileSync(definitionPath,definition);fs.writeFileSync(usePath,use);
 const ranges=(text)=>[...text.matchAll(/\btarget\b/g)].map(m=>{const lines=text.slice(0,m.index).split('\n'),start={line:lines.length-1,character:lines.at(-1).length};return {start,end:{line:start.line,character:start.character+6}};});
 const compare=(actual,expected,label)=>{assert(Array.isArray(actual),label);for(const row of actual)assert.equal(row.kind,1,'kind is Text, not inferred read/write');assert.deepEqual(actual.map(x=>x.range).sort((a,b)=>a.start.line-b.start.line||a.start.character-b.start.character),expected,label);};
 let serial=0;
 async function query(uri,position,method='textDocument/documentHighlight'){
  const id='highlight-query-'+serial++;c.send(request(id,method,{textDocument:{uri},position}));return await c.take(x=>x.id===id);
 }
 const highlight=async(uri,position)=>{const reply=await query(uri,position);assert.equal(reply.error,undefined);assert(Object.hasOwn(reply,'result'));return reply.result;};
 if(!onlyDefinition){const reply=await query(useUri,{line:0,character:0});assert.equal(reply.error.code,-32002);}
 c.send(request('highlight-init','initialize',{workspaceFolders:[{uri:pathToFileURL(project).href,name:'highlight'}]}));
 const init=await c.take(x=>x.id==='highlight-init');if(!onlyDefinition)assert.equal(init.result.capabilities.documentHighlightProvider,true);
 c.send(note('initialized'));c.send(note('textDocument/didOpen',{textDocument:{uri:useUri,languageId:'cangjie',version:1,text:use}}));
 assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===useUri&&x.params.version===1)).params.diagnostics,[]);
 const all=ranges(use),decl=ranges(definition);
 if(onlyDefinition){
  const result=await query(useUri,all[0].start,'textDocument/definition');assert.equal(result.result.uri,definitionUri,'HIGHLIGHT_DEFINITION_CONTROL');assert.deepEqual(result.result.range,decl[0]);
 }else{
  compare(await highlight(useUri,all[0].start),all.slice(0,2),'LSP_HIGHLIGHT_IDENTITY_TARGET');
  compare(await highlight(definitionUri,decl[0].start),decl,'LSP_HIGHLIGHT_REQUESTED_FILE_ONLY');
  compare(await highlight(useUri,all[2].start),all.slice(2),'LSP_HIGHLIGHT_SHADOW_PARAMETER');
  compare(await highlight(useUri,all[4].start),all.slice(2),'LSP_HIGHLIGHT_SHADOW_USE');
  compare(await highlight(useUri,{line:0,character:0}),[],'LSP_HIGHLIGHT_NO_TARGET');
  assert.equal((await query(pathToFileURL(path.join(project,'unknown.cj')).href,{line:0,character:0})).error.code,-32602);
  const bad=definition.replace('return 42','return true');
  c.send(note('textDocument/didOpen',{textDocument:{uri:definitionUri,languageId:'cangjie',version:1,text:bad}}));
  const diag=await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===definitionUri&&x.params.version===1);
  assert(diag.params.diagnostics.some(x=>x.severity===1),'LSP_HIGHLIGHT_ERROR_SNAPSHOT_REACHED');
  assert.equal(await highlight(useUri,all[0].start),null,'LSP_HIGHLIGHT_ERROR_SNAPSHOT_REJECT');
  c.send(note('textDocument/didChange',{textDocument:{uri:definitionUri,version:2},contentChanges:[{text:definition}]}));
  assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===definitionUri&&x.params.version===2)).params.diagnostics,[]);
  compare(await highlight(useUri,all[0].start),all.slice(0,2),'LSP_HIGHLIGHT_ERROR_REPAIR');
  fs.writeFileSync(definitionPath,bad);
  c.send(note('textDocument/didClose',{textDocument:{uri:definitionUri}}));
  assert.equal(await highlight(useUri,all[0].start),null,'LSP_HIGHLIGHT_CLOSED_DISK_REJECT');
  fs.writeFileSync(definitionPath,definition);
  c.send(note('workspace/didChangeWatchedFiles',{changes:[{uri:definitionUri,type:2}]}));
  compare(await highlight(useUri,all[0].start),all.slice(0,2),'LSP_HIGHLIGHT_DISK_REFRESH');
  const changed=use.replace('target() + target()','target() + target() + target()');
  c.send(note('textDocument/didChange',{textDocument:{uri:useUri,version:2},contentChanges:[{text:changed}]}));
  assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===useUri&&x.params.version===2)).params.diagnostics,[]);
  compare(await highlight(useUri,ranges(changed)[0].start),ranges(changed).slice(0,3),'LSP_HIGHLIGHT_CURRENT_BUFFER');
  c.send(note('textDocument/didOpen',{textDocument:{uri:definitionUri,languageId:'cangjie',version:3,text:definition}}));
  assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===definitionUri&&x.params.version===3)).params.diagnostics,[]);
  c.send(note('textDocument/didClose',{textDocument:{uri:useUri}}));
  compare(await highlight(useUri,all[0].start),all.slice(0,2),'LSP_HIGHLIGHT_CLOSE_RESTORES_DISK');
 }
 c.send(request('highlight-shutdown','shutdown'));assert.equal((await c.take(x=>x.id==='highlight-shutdown')).result,null);
 if(!onlyDefinition)assert.equal((await query(useUri,all[0].start)).error.code,-32600);
 c.send(note('exit'));c.end();
}
await client('document-highlight',c=>highlightCase(c),0);
if(mode==='highlight-control')await client('highlight-definition-control',c=>highlightCase(c,true),0);


if(mode==='analysis') {
 const useDir=path.join(directory,'use'),controlDir=path.join(directory,'control');fs.mkdirSync(useDir);fs.mkdirSync(controlDir);
 const source='package lsp_use\nimport lsp_leaf.*\npublic func use(): Int64 { return answer() }\n';
 const controlSource='package leaf_control\npublic func control(): Int64 { return 7 }\n';
 const useFile=useDir+'/use.cj',controlFile=controlDir+'/control.cj';fs.writeFileSync(useFile,source);fs.writeFileSync(controlFile,controlSource);
 const useUri=pathToFileURL(useFile).href,controlUri=pathToFileURL(controlFile).href;
 async function analysis(label,{selected=sdk,missing=false,noModules=false,typeCheck=false}={}) {
  await client(label,async c=>{
   c.send(request('init','initialize'));assert((await c.take(x=>x.id==='init')).result.capabilities);c.send(note('initialized'));
   const open=(uri,text)=>c.send(note('textDocument/didOpen',{textDocument:{uri,version:1,languageId:'cangjie',text}}));
   open(useUri,source);
   const initial=(await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===useUri&&x.params.version===1)).params.diagnostics;
   if(noModules) {
    assert(initial.some(x=>x.severity===1&&x.range.start.line===0&&x.range.start.character===0&&/home|module|path/i.test(x.message)),'LSP_ANALYSIS_CONFIGURATION_DIAGNOSTIC');
   } else if(missing) {
    assert(initial.some(x=>x.severity===1&&/lsp_leaf/.test(x.message)),'LSP_MISSING_LEAF_TARGET');
   } else assert.deepEqual(initial,[],'LSP_MAJOR1_LEAF_TARGET');
   if(!noModules) {
    open(controlUri,controlSource);
    assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===controlUri)).params.diagnostics,[],'LSP_CORE_CONTROL');
   }
   if(typeCheck) {
    c.send(note('textDocument/didChange',{textDocument:{uri:useUri,version:2},contentChanges:[{text:source.replace('use(): Int64','use(): Bool')}]}));
    const red=(await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===useUri&&x.params.version===2)).params.diagnostics;
    assert(red.some(x=>x.severity===1&&/Bool|Int64|type/.test(x.message)),'LSP_IMPORTED_TYPE_TARGET');
    c.send(note('textDocument/didChange',{textDocument:{uri:useUri,version:3},contentChanges:[{text:source}]}));
    assert.deepEqual((await c.take(x=>x.method==='textDocument/publishDiagnostics'&&x.params.uri===useUri&&x.params.version===3)).params.diagnostics,[],'LSP_IMPORTED_TYPE_RESTORED');
   }
   c.send(request('stop','shutdown'));assert.equal((await c.take(x=>x.id==='stop')).result,null);c.send(note('exit'));c.end();
  },0,selected);
  const result=cases.at(-1);assert.match(result.stderr,/LSP_ANALYSIS .*succeeded=/);
  if(!missing&&!noModules)assert.match(result.stderr,/LSP_ANALYSIS .*succeeded=true errors=0/);
 }
 await analysis('analysis-type',{typeCheck:true});
 const cjo=path.join(sdk,'modules/linux_x86_64_cjnative/lsp_leaf.cjo');
 assert(!fs.existsSync(cjo+'.analysis-held'));fs.renameSync(cjo,cjo+'.analysis-held');
 try {await analysis('analysis-missing',{missing:true});} finally {fs.renameSync(cjo+'.analysis-held',cjo);}
 await analysis('analysis-restored');
 const incomplete=path.join(directory,'no-modules');fs.mkdirSync(incomplete);fs.mkdirSync(incomplete+'/bin');
 fs.symlinkSync(fs.realpathSync(path.join(sdk,'bin/cjc')),incomplete+'/bin/cjc');
 await analysis('analysis-no-modules',{selected:incomplete,noModules:true});
}

console.log('LSP_SERVER_CLIENT_PASS processes='+cases.length+' mode='+(mode??'all'));
