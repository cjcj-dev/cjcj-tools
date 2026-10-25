#!/usr/bin/env zx
// Installed public consumer for the selected JSON and httplib headers.
// Run under the admitted kkk2 workflow after normal build.py build/install.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import {spawn,spawnSync} from 'node:child_process';
import {parseArgs} from 'node:util';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
const entry=process.argv.findIndex((x,i)=>i>0&&path.resolve(x)===fileURLToPath(import.meta.url));
const {values:v}=parseArgs({args:process.argv.slice(entry+1),options:{
  prefix:{type:'string'},heap:{type:'string'},port:{type:'string'},work:{type:'string'},
}});
for(const name of ['prefix','heap','port','work'])assert.ok(v[name],`--${name} required`);
const port=Number(v.port);assert.ok(Number.isInteger(port)&&port>1024&&port<65535);
const prefix=path.resolve(v.prefix),work=path.resolve(v.work),exe=path.join(prefix,'bin/cjprof');
fs.mkdirSync(work,{recursive:false});
const heap=path.join(work,'heap.data');fs.copyFileSync(path.resolve(v.heap),heap);
const env={...process.env,LD_LIBRARY_PATH:[path.join(prefix,'lib'),process.env.LD_LIBRARY_PATH].filter(Boolean).join(':')};
delete env.LD_PRELOAD;delete env.LD_AUDIT;
const checks=[],commands=[];
function check(name,fn){
  try{fn();checks.push({name,pass:true});}
  catch(e){checks.push({name,pass:false,error:e.message});throw e;}
  finally{fs.writeFileSync(path.join(work,'assertions.json'),JSON.stringify(checks,null,2));}
}
function record(row){commands.push(row);fs.writeFileSync(path.join(work,'commands.json'),JSON.stringify(commands,null,2));}
function finite(name,argv){
  const r=spawnSync(argv[0],argv.slice(1),{cwd:work,env,encoding:'utf8',timeout:30000,maxBuffer:8*1024*1024});
  fs.writeFileSync(path.join(work,name+'.stdout'),r.stdout??'');fs.writeFileSync(path.join(work,name+'.stderr'),r.stderr??'');
  record({name,argv,cwd:work,rc:r.status,signal:r.signal,error:r.error?.message??null});
  assert.equal(r.status,0,name);return r;
}
finite('installed-identity',['sha256sum',exe,path.join(prefix,'lib/libcjprof.so')]);
const loader=finite('installed-loader',['ldd',exe]);
check('private prof library loaded',()=>assert.ok(loader.stdout.includes(path.join(prefix,'lib/libcjprof.so'))));
const baselineHelp=finite('help-independent-control',[exe,'--help']);
check('independent public help reached',()=>assert.ok(baselineHelp.stdout.includes('Usage: cjprof')));
let servingPort;
async function request(name,wire){
  fs.writeFileSync(path.join(work,name+'.request'),wire);
  const chunks=[];let failure;
  const bytes=await new Promise((resolve,reject)=>{
    const socket=net.createConnection({host:'127.0.0.1',port:servingPort});
    socket.setTimeout(10000,()=>socket.destroy(new Error('HTTP response timeout')));
    socket.on('connect',()=>socket.write(wire));socket.on('data',b=>chunks.push(b));
    socket.on('error',e=>{failure=e;});socket.on('close',()=>failure?reject(failure):resolve(Buffer.concat(chunks)));
  }).finally(()=>fs.writeFileSync(path.join(work,name+'.response'),Buffer.concat(chunks)));
  const end=bytes.indexOf('\r\n\r\n');assert.ok(end>=0,name+' complete headers');
  const headers=bytes.subarray(0,end).toString(),body=bytes.subarray(end+4);
  const status=Number(headers.match(/^HTTP\/1\.[01] (\d{3}) /)?.[1]);
  return {headers,body,status};
}
const get=(name,url,headers='')=>request(name,`GET ${url} HTTP/1.1\r\nHost: localhost\r\n${headers}Connection: close\r\n\r\n`);
async function until(predicate,label,child){
  const end=Date.now()+30000;
  while(Date.now()<end){if(predicate())return;if(child.exitCode!==null||child.signalCode!==null)throw Error(label+': server exited');await delay(100);}
  throw Error(label+': timeout');
}
let coldSnapshot;
for(const arm of ['first','cache']){
  servingPort=undefined;
  const argv=[exe,'heap','-i',heap,`--dump-report=${port}`],name=arm+'-server';
  const out=fs.openSync(path.join(work,name+'.stdout'),'wx'),err=fs.openSync(path.join(work,name+'.stderr'),'wx');
  const child=spawn(argv[0],argv.slice(1),{cwd:work,env,stdio:['ignore',out,err]});
  let spawnError;child.on('error',e=>{spawnError=e;});
  const ended=new Promise(resolve=>child.once('close',(rc,signal)=>{
    fs.closeSync(out);fs.closeSync(err);record({name,argv,cwd:work,pid:child.pid,rc,signal,error:spawnError?.message??null});resolve({rc,signal});
  }));
  const log=()=>fs.readFileSync(path.join(work,name+'.stdout'),'utf8')+fs.readFileSync(path.join(work,name+'.stderr'),'utf8');
  try{
    // The public producer selects an available port starting at --dump-report.
    // A separate Node bind is neither its reservation nor its reuse policy.
    // Keep the same requested port for both processes and consume each child's
    // actual advertised endpoint after the previous child's close has completed.
    const endpoint=()=>log().match(/Access URL: http:\/\/localhost:(\d+)\b/);
    await until(()=>endpoint()!==null,name+' public readiness',child);
    servingPort=Number(endpoint()[1]);
    fs.writeFileSync(path.join(work,name+'.endpoint.json'),JSON.stringify({
      pid:child.pid,requestedPort:port,servingPort,
    },null,2));
    check(arm+' public endpoint belongs to producer selection',()=>{
      assert.ok(Number.isInteger(servingPort)&&servingPort>=port&&servingPort<port+100&&servingPort<=65535);
      assert.ok(!log().includes('Failed to start HTTP server'));
      assert.equal(child.exitCode,null);assert.equal(child.signalCode,null);
    });
    // Readiness alone is insufficient: reach routing and JSON serialization.
    const snapshot=await get(arm+'-snapshot','/api/snapshot');
    check(arm+' snapshot reaches JSON producer',()=>{
      assert.equal(snapshot.status,200);assert.match(snapshot.headers,/content-type: application\/json/i);
      const j=JSON.parse(snapshot.body);for(const key of ['heap_total_size','object_count','gc_root_count','used_size'])assert.equal(typeof j[key],'number');
      assert.ok(j.object_count>0);assert.ok(j.heap_total_size>=j.used_size);
      if(arm==='first')coldSnapshot=j;else assert.deepEqual(j,coldSnapshot);
    });
    const overview=await get(arm+'-overview','/api/fragment/overview');
    check(arm+' JSON numbers agree across handlers',()=>{
      assert.equal(overview.status,200);const j=JSON.parse(overview.body);
      assert.equal(j.heap_limit,coldSnapshot.heap_total_size);assert.equal(j.used_size,coldSnapshot.used_size);assert.equal(typeof j.utilization,'number');
    });
    const root=await get(arm+'-index','/');
    check(arm+' installed static content',()=>{assert.equal(root.status,200);assert.deepEqual(root.body,fs.readFileSync(path.join(prefix,'config/static/html/index.html')));});
    const bad=await get(arm+'-query','/api/dominance/children?parent_id=%6eot-a-number');
    check(arm+' decoded parameter reaches product rejection',()=>{assert.equal(bad.status,400);assert.equal(JSON.parse(bad.body).error,'Invalid parent_id');});
    // Fixed upstream fbd3e2 rejects unsupported transfer codings before routing.
    const framed=await request(arm+'-unsupported-transfer',`GET /api/snapshot HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip, chunked\r\nConnection: close\r\n\r\n0\r\n\r\n`);
    check(arm+' unsupported transfer coding rejected',()=>assert.equal(framed.status,501));
    const after=await get(arm+'-after-rejection','/api/snapshot');
    check(arm+' normal consumer survives rejection',()=>{assert.equal(after.status,200);assert.deepEqual(JSON.parse(after.body),coldSnapshot);});
    if(arm==='first')await until(()=>log().includes('Background cache save done:'),name+' completed cache write',child);
    else check('second process reaches cache producer',()=>assert.ok(log().includes('DatabaseCache::load:')));
    finite(arm+'-help-control',[exe,'--help']);
  }finally{
    // Only the exact child we created; normal release exits by SIGTERM.
    if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');
    let timer;const result=await Promise.race([ended,new Promise(resolve=>{timer=setTimeout(()=>resolve(null),10000);})]);clearTimeout(timer);
    if(result===null){child.kill('SIGKILL');await ended;throw Error(name+' did not stop after SIGTERM');}
    check(arm+' server stopped as requested',()=>assert.ok((result.rc===null&&result.signal==='SIGTERM')||(result.rc===0&&result.signal===null)));
  }
}
