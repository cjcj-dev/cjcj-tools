#!/usr/bin/env zx
// Public installed CLI tests. Retained-size oracle uses graph reachability after
// deletion, independent of the product's immediate-dominator algorithm.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const binary=path.resolve(process.argv[2]), work=path.resolve(process.argv[3]);
const fixtures=path.dirname(fileURLToPath(import.meta.url));
fs.mkdirSync(work,{recursive:true});
const commands=[],checks=[];
function check(name,condition){checks.push({name,executed:true,pass:!!condition});fs.writeFileSync(path.join(work,'assertions.json'),JSON.stringify(checks,null,2));assert.ok(condition,name);}
function run(name,args,expected=0){
 const p=spawnSync(binary,args,{encoding:'utf8',timeout:20000,maxBuffer:8*1024*1024});
 fs.writeFileSync(path.join(work,name+'.stdout'),p.stdout??'');fs.writeFileSync(path.join(work,name+'.stderr'),p.stderr??'');
 commands.push({name,argv:[binary,...args],rc:p.status,signal:p.signal,error:p.error?.message});
 fs.writeFileSync(path.join(work,'commands.json'),JSON.stringify(commands,null,2));
 check(name+' process rc',p.status===expected);return p.stdout;
}
const be=(x,n)=>{let y=BigInt(x), b=Buffer.alloc(n);for(let i=n-1;i>=0;i--){b[i]=Number(y&255n);y>>=8n;}return b;};
const cat=(...parts)=>Buffer.concat(parts);
function profile({version=2,width=8,objects,roots=[],strings=['Class'],size=8,extra=[]}){
 const m=version===1?8:4,id=n=>be(n,version===1?8:width),meta=n=>be(n,m);
 const record=(tag,b)=>cat(be(tag,1),be(b.length,8),b);
 const str=(i,s)=>{const b=cat(meta(i),Buffer.from(s));return cat(be(1,1),be(b.length,m),b);};
 const cls=version===1?record(2,cat(meta(1),meta(1))):cat(be(2,1),meta(1),meta(1),be(size,4));
 const dump=[cat(be(32,1),meta(1),...(version===2?[meta(1)]:[]),be(size,4))];
 for(const n of roots)dump.push(cat(be(1,1),id(n)));
 for(const o of objects){
  const tag=o.tag??33,shape=tag===37?33:tag>=42?tag-9:tag>=38?tag-5:tag;
  let body;
  if(shape===33)body=cat(meta(1),be(o.refs.length,4),...o.refs.map(id));
  else if(shape===35)body=cat(be(o.num??3,4),be(o.type??4,1));
  else body=cat(...(shape===36?[be(o.components??5,4)]:[]),be(o.refs.length,4),meta(1),...o.refs.map(id));
  dump.push(cat(be(tag,1),id(o.id),body));
 }
 return cat(Buffer.from('CANGJIE PROFILE 1.0.'+version+'\0'),be(width,4),be(123,8),...strings.map((s,i)=>str(i+1,s)),cls,record(12,cat(...dump)),...extra.map(x=>record(x[0],x[1])));
}
function put(name,data){const f=path.join(work,name+'.data');fs.writeFileSync(f,data);return f;}
function analyze(name,data){const f=put(name,data);return JSON.parse(run(name,['heap','-i',f,'--json']));}
for(const file of ['heap.data','heap_multi_ref.data']){
 const json=JSON.parse(run(file,['heap','-i',path.join(fixtures,file),'--json']));
 check(file+' actual nonempty object/class consumption',json.objects.length>0&&json.constructors.length>0);
 check(file+' retained nonconstant positive',json.objects.some(x=>x.retainedSize>x.shallowSize));
 run(file+'-threads',['heap','-i',path.join(fixtures,file),'--show-thread']);
 run(file+'-incoming',['heap','-i',path.join(fixtures,file),'--show-reference','--incoming-reference','--depth','2']);
}
const diamond=[{id:1,refs:[2,3,2,0]},{id:2,refs:[4]},{id:3,refs:[4]},{id:4,refs:[]}];
for(const version of [1,2])for(const width of [4,8]){
 const p=analyze('diamond-'+version+'-'+width,profile({version,width,objects:diamond,roots:[1],strings:['包:类']}));
 const byId=new Map(p.objects.map(x=>[x.id,x]));
 check('diamond retained V'+version+'/'+width,byId.get(1).retainedSize===32&&byId.get(2).retainedSize===8&&byId.get(4).dominator===1);
 check('diamond duplicate/null refs removed V'+version+'/'+width,byId.get(1).children.length===2&&byId.get(4).references.length===2);
 check('UTF8 class name V'+version+'/'+width,p.constructors[0].name==='包::类');
}
for(let tag=33;tag<=45;tag++){
 const shape=tag===37?33:tag>=42?tag-9:tag>=38?tag-5:tag;
 const p=analyze('category-'+tag,profile({objects:[{id:1,tag,refs:[],num:3,type:4}],roots:[1]}));
 check('category '+tag,p.objects[0].category===([0,1,3,2,4,5,5,5,5,6,6,6,6][tag-33]));
 check('array/instance size '+tag,p.objects[0].shallowSize===(shape===33?8:shape===35?24:shape===36?56:16));
}
for(const [type,size]of [[4,24],[9,24],[10,32],[11,40]]){
 const p=analyze('primitive-'+type,profile({objects:[{id:1,tag:35,type,num:3,refs:[]}]}));check('primitive width '+type,p.objects[0].shallowSize===size);
}
let seed=0x713476;
function random(n){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;}
for(let trial=0;trial<24;trial++){
 const n=5+random(16),objects=Array.from({length:n},(_,i)=>({id:i+1,refs:[]}));
 for(const o of objects)for(let j=0,k=random(5);j<k;j++)o.refs.push(random(n)+1);
 const explicit=[random(n)+1,random(n)+1];
 const roots=new Set(explicit);for(const o of objects)if(!objects.some(p=>p.refs.includes(o.id)))roots.add(o.id);
 const reachable=(removed)=>{const seen=new Set(),q=[...roots].filter(x=>x!==removed);for(let i=0;i<q.length;i++){const x=q[i];if(seen.has(x))continue;seen.add(x);for(const y of objects[x-1].refs)if(y!==removed&&!seen.has(y))q.push(y);}return seen;};
 const live=reachable(0),p=analyze('graph-'+trial,profile({objects,roots:explicit}));
 for(const o of p.objects){const after=reachable(o.id);const expected=live.has(o.id)?[...live].filter(x=>!after.has(x)).length*8:8;check('retained deletion oracle trial '+trial+' object '+o.id,o.retainedSize===expected);}
}
const high=BigInt('0xffff000000000001');
const p=analyze('wide-id',profile({objects:[{id:high,refs:[]}],roots:[high]}));
// JSON numbers remain textual UInt64 values; inspect raw instead of JS Number.
check('wide UInt64 identity serialized without Double',fs.readFileSync(path.join(work,'wide-id.stdout'),'utf8').includes(high.toString()));
const valid=profile({objects:diamond,roots:[1]});
for(const n of [0,21,25,33,valid.length-1])run('truncated-'+n,['heap','-i',put('truncated-'+n,valid.subarray(0,n))],1);
const badId=Buffer.from(valid);be(3,4).copy(badId,22);run('bad-id',['heap','-i',put('bad-id',badId)],1);
run('missing-file',['heap','-i',path.join(work,'missing.data')],1);
run('missing-option-value',['heap','-i'],1);
run('help',['--help']);run('version',['--version']);
check('version preserved',fs.readFileSync(path.join(work,'version.stdout'),'utf8').includes('1.3.0-alpha.08'));
for(const version of [1,2])for(const width of [4,8]){
 const m=version===1?8:4,meta=n=>be(n,m);
 const extras=[
  [4,cat(meta(1),meta(2),meta(0),be(12,4))],
  [4,cat(meta(2),meta(3),meta(0),be(24,4))],
  [5,cat(be(1,4),be(7,4),be(2,4),meta(1),meta(2))],
  [5,cat(be(2,4),be(7,4),be(1,4),meta(2))],
  [13,cat(be(1000,4),be(2,4),be(10,4),be(1,4),be(5,4),be(2,4))]
 ];
 const input=put('samples-'+version+'-'+width,profile({version,width,objects:[],strings:['Class','叶<&','root'],extra:extras}));
 const text=run('report-flat-'+version+'-'+width,['report','-i',input]);
 check('flat leaf/self percentages '+version+'/'+width,text.includes('66.67%')&&text.includes('33.33%')&&text.includes('叶<&')&&text.includes('root'));
 const svg=path.join(work,'flame-'+version+'-'+width+'.svg');
 run('report-flame-'+version+'-'+width,['report','-i',input,'--flame-graph','-o',svg]);
 const output=fs.readFileSync(svg,'utf8');
 check('flame real frames/escaped labels/interactivity '+version+'/'+width,output.includes('叶&lt;&amp;')&&output.includes('10 samples, 66.67%')&&output.includes('15 samples, 100.00%')&&output.includes('function zoom')&&output.includes('function search')&&!output.includes('${frames}'));
}
run('report-no-samples',['report','-i',path.join(fixtures,'heap.data')],1);
run('report-help',['report','--help'],1);
console.log('PASS '+commands.length+' processes / '+checks.length+' assertions');
