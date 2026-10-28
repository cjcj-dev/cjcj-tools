#!/usr/bin/env zx
// Format constants are from fixed Hprof.h and ObjectCategory.h, not tag arithmetic.
import fs from 'node:fs';import path from 'node:path';import net from 'node:net';import {spawn,spawnSync} from 'node:child_process';import {setTimeout as delay} from 'node:timers/promises';
const [prefix,work]=process.argv.slice(2).map(x=>path.resolve(x));fs.mkdirSync(work,{recursive:true});
const sdk=JSON.parse(fs.readFileSync(prefix+'/build-facts.json')).sdk,env={...process.env,CANGJIE_HOME:sdk,LD_LIBRARY_PATH:sdk+'/runtime/lib/linux_x86_64_cjnative:'+sdk+'/tools/lib'};
const checks=[],commands=[];function check(name,pass){checks.push({name,executed:true,pass:!!pass});fs.writeFileSync(work+'/assertions.json',JSON.stringify(checks,null,2));console.log((pass?'PASS ':'FAIL ')+name);}
const be=(x,n)=>{const b=Buffer.alloc(n);let v=BigInt(x);for(let i=n-1;i>=0;i--){b[i]=Number(v&255n);v>>=8n;}return b;},cat=(...a)=>Buffer.concat(a);
const instance=()=>cat(be(1,4),be(0,4)),objectArray=()=>cat(be(1,4),be(1,4),be(0,8)),primitive=()=>cat(be(3,4),be(4,1)),struct=()=>cat(be(5,4),be(1,4),be(1,4),be(0,8));
// Explicit wire tags, public category IDs, and manually calculated byte sizes.
const rows=[
 [0x21,0x1000,instance(),0,8,'instance'],[0x22,0x20000,objectArray(),1,24,'object array'],
 [0x23,0x40000,primitive(),3,24,'primitive array'],[0x24,0x60000,struct(),2,56,'struct array'],
 [0x25,0x80000,instance(),4,8,'pinned'],
 [0x26,0xa0000,instance(),5,8,'large instance'],[0x27,0xc0000,objectArray(),5,24,'large object array'],[0x28,0xe0000,primitive(),5,24,'large primitive array'],[0x29,0x100000,struct(),5,56,'large struct array'],
 [0x2a,0x120000,instance(),6,8,'unmovable instance'],[0x2b,0x140000,objectArray(),6,24,'unmovable object array'],[0x2c,0x160000,primitive(),6,24,'unmovable primitive array'],[0x2d,0x180000,struct(),6,56,'unmovable struct array']];
const heapParts=[cat(be(0x20,1),be(1,4),be(1,4),be(8,4))];for(const [tag,id,body]of rows)heapParts.push(cat(be(1,1),be(id,8)),cat(be(tag,1),be(id,8),body));
const str=cat(be(1,4),Buffer.from('Structure')),data=cat(Buffer.from('CANGJIE PROFILE 1.0.2\0'),be(8,4),be(123,8),be(1,1),be(str.length,4),str,be(2,1),be(1,4),be(1,4),be(8,4),be(12,1),be(cat(...heapParts).length,8),cat(...heapParts));
// A prior run intentionally leaves a valid cache and a damaged original heap.
// Keep that evidence and generate a new cold input for each invocation.
const input=fs.mkdtempSync(work+'/input-')+'/categories.data';fs.writeFileSync(input,data);
const argv=[prefix+'/bin/cjprof','heap','-i',input,'--json'],p=spawnSync(argv[0],argv.slice(1),{env,encoding:'utf8'});commands.push({name:'CLI',argv,rc:p.status,signal:p.signal});fs.writeFileSync(work+'/cli.stdout',p.stdout??'');fs.writeFileSync(work+'/cli.stderr',p.stderr??'');check('CLI parser reaches actual objects',p.status===0);
const objects=JSON.parse(p.stdout).objects;for(const [,id,,category,size,name]of rows){const o=objects.find(x=>x.id===id);check('CLI '+name+' category',o?.category===category);check('CLI '+name+' byte size',o?.shallowSize===size);}
const names=['INSTANCE_OBJECT','OBJECT_ARRAY','STRUCT_ARRAY','PRIMITIVE_ARRAY','PINNED_OBJECT','LARGE_OBJECT','UNMOVABLE_OBJECT'];const totals=[8,24,56,24,8,112,112];
async function request(port,name,route){let text='';await new Promise((resolve,reject)=>{const s=net.createConnection(port,'127.0.0.1');s.setTimeout(5000,()=>s.destroy(Error('timeout')));s.on('connect',()=>s.write('GET '+route+' HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'));s.on('data',b=>text+=b);s.on('close',resolve);s.on('error',reject);});fs.writeFileSync(work+'/'+name+'.response',text);return JSON.parse(text.split('\r\n\r\n')[1]);}
for(const arm of ['cold','cache']){
 const reserved=net.createServer();await new Promise(r=>reserved.listen(0,'127.0.0.1',r));const port=reserved.address().port;await new Promise(r=>reserved.close(r));
 if(arm==='cache')fs.writeFileSync(input,'invalid input proves cache actually supplies objects');
 const args=[prefix+'/bin/cjprof','heap','-i',input,'--dump-report='+port],child=spawn(args[0],args.slice(1),{env,stdio:['ignore','pipe','pipe']});let output='';child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);const done=new Promise(r=>child.on('close',(rc,signal)=>{commands.push({name:arm,argv:args,pid:child.pid,rc,signal});r();}));
 try{
  const end=Date.now()+8000;while(!output.includes('Access URL:')&&child.exitCode===null&&Date.now()<end)await delay(25);if(!output.includes('Access URL:'))throw Error('server did not reach consumer: '+output);
  check(arm+' actual branch',output.includes(arm==='cold'?'Cache save done:':'DatabaseCache::load:'));
  const layout=await request(port,arm+'-layout','/api/fragment/layout'),summary=await request(port,arm+'-summary','/api/fragment/summary');
  for(let i=0;i<7;i++){check(arm+' HTTP layout '+names[i],layout.categories.find(x=>x.type===names[i])?.size===totals[i]);check(arm+' HTTP summary '+names[i],summary[names[i].toLowerCase()+'_total']===totals[i]);}
  const distribution=await request(port,arm+'-distribution','/api/fragment/distribution');const segments=distribution.rows.flatMap(x=>x.segments);
  check(arm+' HTTP primitive address classification',segments.some(x=>x.type==='PRIMITIVE_ARRAY'&&BigInt(x.start_address)<=0x40000n&&BigInt(x.end_address)>0x40000n));
  check(arm+' HTTP struct address classification',segments.some(x=>x.type==='STRUCT_ARRAY'&&BigInt(x.start_address)<=0x60000n&&BigInt(x.end_address)>0x60000n));
 }finally{child.kill('SIGTERM');await done;fs.writeFileSync(work+'/'+arm+'.log',output);fs.writeFileSync(work+'/commands.json',JSON.stringify(commands,null,2));}
 if(arm==='cold'){
  const bytes=fs.readFileSync(input+'.cjprof.db'),offset=Number(bytes.readBigUInt64LE(48)),count=Number(bytes.readBigUInt64LE(56));check('packed cache object count',count===13);
  for(let i=0;i<count;i++){const at=offset+i*51,id=Number(bytes.readBigUInt64LE(at)),row=rows.find(r=>r[1]===id);check('cache wire '+row[5]+' category',bytes[at+32]===row[3]);}
 }
}
const failed=checks.filter(x=>!x.pass);console.log('categories '+checks.length+' assertions; failed='+failed.length);process.exitCode=failed.length?1:0;
