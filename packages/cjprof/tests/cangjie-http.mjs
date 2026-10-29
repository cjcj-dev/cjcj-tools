#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import {spawn} from 'node:child_process';
import assert from 'node:assert/strict';
import {setTimeout as delay} from 'node:timers/promises';
const [prefix,input,work]=process.argv.slice(2).map(x=>path.resolve(x));fs.mkdirSync(work,{recursive:true});
const heap=path.join(work,'input.data');fs.copyFileSync(input,heap);fs.rmSync(heap+'.cjprof.db',{force:true});
const checks=[],commands=[];
function check(name,condition){checks.push({name,executed:true,pass:!!condition});fs.writeFileSync(path.join(work,'assertions.json'),JSON.stringify(checks,null,2));assert.ok(condition,name);}
async function request(port,name,target,extra=''){
 const chunks=[];const wire=`GET ${target} HTTP/1.1\r\nHost: localhost\r\n${extra}Connection: close\r\n\r\n`;
 fs.writeFileSync(path.join(work,name+'.request'),wire);
 await new Promise((resolve,reject)=>{const s=net.createConnection({host:'127.0.0.1',port});s.setTimeout(10000,()=>s.destroy(new Error('timeout')));s.on('connect',()=>s.write(wire));s.on('data',x=>chunks.push(x));s.on('error',reject);s.on('close',resolve);});
 const bytes=Buffer.concat(chunks);fs.writeFileSync(path.join(work,name+'.response'),bytes);
 const end=bytes.indexOf('\r\n\r\n'),head=bytes.subarray(0,end).toString(),body=bytes.subarray(end+4);
 check(name+' complete HTTP framing',end>=0&&Number(head.match(/Content-Length: (\d+)/i)?.[1])===body.length);
 return {status:Number(head.match(/^HTTP\/1.1 (\d+)/)?.[1]),head,body};
}
const reserved=net.createServer();await new Promise(resolve=>reserved.listen(0,'127.0.0.1',resolve));const wanted=reserved.address().port;
let snapshot;
for(const arm of ['first','reentry']){
 if(arm==='first')check('cold cache initially absent',!fs.existsSync(heap+'.cjprof.db'));
 const argv=[path.join(prefix,'bin/cjprof'),'heap','-i',heap,'--dump-report='+wanted];
 const child=spawn(argv[0],argv.slice(1),{stdio:['ignore','pipe','pipe']});let log='';child.stdout.on('data',x=>{log+=x});child.stderr.on('data',x=>{log+=x});
 const ended=new Promise(resolve=>child.on('close',(rc,signal)=>{commands.push({name:arm,argv,pid:child.pid,rc,signal});fs.writeFileSync(path.join(work,'commands.json'),JSON.stringify(commands,null,2));resolve();}));
 try{
  const deadline=Date.now()+10000;
  while(!/Access URL: http:\/\/localhost:(\d+)/.test(log)){
   if(child.exitCode!==null||child.signalCode!==null||Date.now()>deadline)throw Error('HTTP not ready: '+log);
   await delay(50);
  }
  check(arm+' actual cache branch',arm==='first'?log.includes('Cache save done:'):log.includes('DatabaseCache::load:'));
  const port=Number(log.match(/Access URL: http:\/\/localhost:(\d+)/)[1]);check(arm+' requested occupied port advances',port>wanted&&port<wanted+100);
  let r=await request(port,arm+'-snapshot','/api/snapshot');check(arm+' snapshot JSON producer',r.status===200&&JSON.parse(r.body).object_count===4);
  if(!snapshot)snapshot=JSON.parse(r.body);else check('same-input process reentry snapshot',JSON.stringify(JSON.parse(r.body))===JSON.stringify(snapshot));
  r=await request(port,arm+'-tree','/api/dominance/tree');const tree=JSON.parse(r.body);check(arm+' actual dominance tree',r.status===200&&tree.nodes.length===4&&tree.nodes.find(n=>n.id===4).parent_id===1);
  r=await request(port,arm+'-children','/api/dominance/children?parent_id=1');check(arm+' dominance children',JSON.parse(r.body).nodes.length===3);
  r=await request(port,arm+'-types','/api/dominance/tree-by-type');const types=JSON.parse(r.body).nodes;check(arm+' type aggregation by logical parent',types.length===2&&types.some(x=>x.instance_count===3));
  for(const type of types){r=await request(port,arm+'-typechildren-'+type.id,'/api/dominance/children-by-type?node_id='+type.id);const kids=JSON.parse(r.body).nodes;check(arm+' type shared child set '+type.id,JSON.stringify(kids.map(x=>x.id).sort())===JSON.stringify(type.child_types.sort()));}
  r=await request(port,arm+'-cluster','/api/dominance/cluster-expand?instance_ids=2,4,invalid');check(arm+' cluster expansion selects objects',JSON.stringify(JSON.parse(r.body).nodes.map(x=>x.id))==='[2,4]');
  r=await request(port,arm+'-top','/api/dominance/top10');check(arm+' retained ranking',JSON.parse(r.body).items[0].object_id===1&&JSON.parse(r.body).items[0].retained_size===32);
  r=await request(port,arm+'-overview','/api/fragment/overview');check(arm+' fragment accounting',JSON.parse(r.body).used_size===32);
  r=await request(port,arm+'-layout','/api/fragment/layout');check(arm+' categories and free accounting',JSON.parse(r.body).categories.reduce((n,x)=>n+x.size,0)===536870912);
  r=await request(port,arm+'-summary','/api/fragment/summary');check(arm+' category summary',JSON.parse(r.body).instance_object_total===32);
  r=await request(port,arm+'-distribution','/api/fragment/distribution');const dist=JSON.parse(r.body);check(arm+' address distribution consumes sizes',dist.rows.length===1&&dist.rows[0].segments[0].type==='INSTANCE_OBJECT'&&dist.rows[0].size===11);
  r=await request(port,arm+'-static','/');check(arm+' installed exact HTML',r.status===200&&r.body.equals(fs.readFileSync(path.join(prefix,'config/static/html/index.html'))));
  r=await request(port,arm+'-bad-param','/api/dominance/children?parent_id=%6eot-a-number');check(arm+' decoded numeric rejection',r.status===400&&JSON.parse(r.body).error==='Invalid parent_id');
  r=await request(port,arm+'-bad-transfer','/api/snapshot','Transfer-Encoding: gzip, chunked\r\n');check(arm+' unsupported transfer rejection',r.status===501);
  r=await request(port,arm+'-traversal','/static/%2e%2e/secrets');check(arm+' traversal rejected',r.status===400);
  r=await request(port,arm+'-after','/api/snapshot');check(arm+' normal consumer survives rejection',r.status===200&&JSON.stringify(JSON.parse(r.body))===JSON.stringify(snapshot));
 }finally{child.kill('SIGTERM');await ended;fs.writeFileSync(path.join(work,arm+'.log'),log);}
}
await new Promise(resolve=>reserved.close(resolve));
console.log('PASS HTTP '+checks.length+' assertions / '+commands.length+' server processes');
