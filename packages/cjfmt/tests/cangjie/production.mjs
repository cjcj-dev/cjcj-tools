#!/usr/bin/env zx
// Real package CJPM producer and installed consumers; no mock compiler or old formatter.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {parseArgs} from 'node:util';
import {createHash} from 'node:crypto';
const {values:v}=parseArgs({options:{work:{type:'string'},products:{type:'string'},sdk:{type:'string'},'frontend-cjo':{type:'string'},'frontend-native':{type:'string'},'frontend-ref':{type:'string'},'source-ref':{type:'string'}}});
for(const name of ['work','products','sdk','frontend-cjo','frontend-native','frontend-ref','source-ref'])if(!v[name])throw Error('--'+name+' required');
const tool=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..'),work=path.resolve(v.work);
if(await fs.stat(work).catch(()=>null))throw Error('work must be fresh');
await fs.mkdir(work,{recursive:true});
const products=path.resolve(v.products);if(await fs.stat(products).catch(()=>null))throw Error('products must be fresh');await fs.mkdir(products,{recursive:true});
const sdk=path.resolve(v.sdk),build=path.join(products,'build'),prefix=path.join(products,'install');
if(await fs.stat(build).catch(()=>null))throw Error('first package build must be fresh');
const env={...process.env,CANGJIE_HOME:sdk,CJFMT_FRONTEND_CJO:v['frontend-cjo'],CJFMT_FRONTEND_LIB:v['frontend-cjo'],CJFMT_FRONTEND_NATIVE:v['frontend-native'],CJFMT_FRONTEND_REF:v['frontend-ref'],CJFMT_SOURCE_REF:v['source-ref'],CANGJIE_BUILD_JOBS:'4',LD_LIBRARY_PATH:[sdk+'/runtime/lib/linux_x86_64_cjnative',sdk+'/tools/lib',sdk+'/third_party/llvm/lib'].join(':')};
const commands=[],checks=[];
const hash=async file=>createHash('sha256').update(await fs.readFile(file)).digest('hex');
async function save(){await fs.writeFile(work+'/results.json',JSON.stringify({sourceRef:v['source-ref'],frontendRef:v['frontend-ref'],commands,checks},null,2));}
async function run(label,argv,expected=0){
 if(process.env.CJFMT_RESOURCE_ROOT){
  const dirs=[process.env.CJFMT_RESOURCE_ROOT,'/root/impl_cjfmt_cangjie_1027'];
  const sizes=spawnSync('du',['-B1','-s',...dirs],{encoding:'utf8'});if(sizes.status!==0)throw Error('resource measurement failed');
  const total=sizes.stdout.trim().split('\n').reduce((n,line)=>n+Number(line.split(/\s+/)[0]),0);
  const reserve=label==='default-build'?80000000:label==='legacy-explicit-release'?26000000:label==='cut-normal-build'?74000000:label.endsWith('-functional')?85000000:label.endsWith('-normal-install')||label==='legacy-install'||label==='fresh-unpack'?24000000:label==='same-install-package'?6500000:1000000;
  const snapshot={label,total,reserve,limit:Number(process.env.CJFMT_DISK_LIMIT)};
  await fs.appendFile(work+'/resource-admission.jsonl',JSON.stringify(snapshot)+'\n');
  if(total+reserve>snapshot.limit)throw Error('resource shortfall '+(total+reserve-snapshot.limit)+'B before '+label);
 }

 const p=spawnSync(argv[0],argv.slice(1),{env,cwd:tool,encoding:'utf8',maxBuffer:4*2**20});
 await fs.writeFile(work+'/'+label+'.log',(p.stdout??'')+(p.stderr??''));
 commands.push({label,argv,cwd:tool,rc:p.status,signal:p.signal,error:p.error?.message,expected});await save();
 console.log(label+' rc='+p.status);if(p.status!==expected)throw Error(label+' expected '+expected+' actual '+p.status);return p;
}
async function check(label,pass,detail){checks.push({label,pass,detail});await save();if(!pass)throw Error(label);}
async function producerEvidence(label,dir){for(const file of ['commands.json','inputs.json','cjfmt.log'])await fs.copyFile(dir+'/'+file,work+'/'+label+'-'+file);}
const entry=tool+'/build/build.mjs';
await run('install-before-build',[process.execPath,entry,'install','--build-dir',build,'--prefix',work+'/premature'],1);
await run('default-build',[process.execPath,entry,'build','--build-dir',build,'--jobs','4']);
await producerEvidence('default',build);
const release=JSON.parse(await fs.readFile(build+'/inputs.json','utf8'));
await check('default-is-release',release.buildType==='release');
await run('explicit-debug',[process.execPath,entry,'build','--build-dir',build,'-t','debug','--jobs','4']);
await producerEvidence('debug',build);
const debug=JSON.parse(await fs.readFile(build+'/inputs.json','utf8'));
await check('explicit-is-real-debug',debug.buildType==='debug'&&JSON.parse(await fs.readFile(work+'/debug-commands.json','utf8'))[0].argv.includes('-g'));
await run('explicit-release',[process.execPath,entry,'build','--build-dir',build,'-t','release','--jobs','4']);
await producerEvidence('release',build);
const rebuilt=JSON.parse(await fs.readFile(build+'/inputs.json','utf8'));
await check('warm-mode-changed',rebuilt.buildType==='release'&&rebuilt.sourceRef===v['source-ref']&&rebuilt.frontendRef===v['frontend-ref']);
const trace=work+'/cached-build.execve';
await run('cached-build',['strace','-f','-s','65536','-e','trace=execve','-o',trace,process.execPath,entry,'build','--build-dir',build,'-t','release','--jobs','4']);
const executed=(await fs.readFile(trace,'utf8')).split('\n').filter(line=>line.includes('execve(')&&line.endsWith('= 0'));
await check('cached-build-reuses-CJ-product',!executed.some(line=>line.includes('/bin/cjc"')&&!line.includes('"--scan-dependency"')&&!/\["[^"]+", "-v"\]/.test(line))&&await hash(build+'/cjfmt')===rebuilt.sha256,executed);
await run('normal-install',[process.execPath,entry,'install','--build-dir',build,'--prefix',prefix]);
await check('install-consumes-cangjie-product',await hash(prefix+'/bin/cjfmt')===rebuilt.sha256);
const loader=await run('installed-loader',['ldd',prefix+'/bin/cjfmt']);
await check('no-old-language-server-library',!loader.stdout.includes('libcangjie-lsp'));
async function functional(label,install){
 await run(label+'-functional',['node',tool+'/tests/cangjie/functional.mjs',install+'/bin/cjfmt',sdk+'/bin/cjc',work+'/'+label+'-functional',products+'/programs/'+label]);
 await run(label+'-macros',['node',tool+'/tests/cangjie/macros.mjs',install+'/bin/cjfmt',sdk+'/bin/cjc',work+'/'+label+'-macros',products+'/programs/'+label+'/macros']);
 await run(label+'-public-region',['node',tool+'/tests/public/region-comments.mjs',install+'/bin/cjfmt',sdk+'/bin/cjc',work+'/'+label+'-public-region']);
 await run(label+'-public-config',['node',tool+'/tests/public/configured-comments.mjs',install+'/bin/cjfmt',sdk+'/bin/cjc',install+'/config/cangjie-format.toml',work+'/'+label+'-public-config']);
}
await functional('installed',prefix);
// Exercise a controlled cut through the same package build entry.
const cutTool=products+'/cut/tool';
await fs.cp(tool,cutTool,{recursive:true,filter:src=>src!==build&&!src.startsWith(build+path.sep)});
const main=cutTool+'/src/Main.cj',original=await fs.readFile(main,'utf8'),anchor='formatted = formatSource(syntax, options, args)';
if(original.split(anchor).length!==2)throw Error('cut anchor not unique');
await fs.writeFile(main,original.replace(anchor,'formatted = text'));
const diff=await run('cut-diff',['diff','-u',tool+'/src/Main.cj',main],1);await fs.writeFile(work+'/cut.diff',diff.stdout);
const cutEntry=cutTool+'/build/build.mjs',cutBuild=products+'/cut/build',cutInstall=products+'/cut/install';
for(const arm of ['cut','restored']){
 if(arm==='restored')await fs.writeFile(main,original);
 await run(arm+'-normal-build',[process.execPath,cutEntry,'build','--build-dir',cutBuild,'-t','release','-j','4']);
 await producerEvidence(arm,cutBuild);
 await run(arm+'-normal-install',[process.execPath,cutEntry,'install','--build-dir',cutBuild,'--prefix',cutInstall]);
 await run(arm+'-layout',['node',tool+'/tests/cangjie/wiring.mjs',cutInstall+'/bin/cjfmt',work+'/'+arm+'-wiring'],arm==='cut'?1:0);
 if(arm==='cut'){
  const result=JSON.parse(await fs.readFile(work+'/cut-wiring/results.json','utf8'));
  await check('cut-fails-exactly-product-invariant',result.checks.filter(c=>!c.pass).map(c=>c.label).join(',')==='native-layout-consumed');
 }
}
await check('cut-source-restored',await fs.readFile(main,'utf8')===original&&await fs.readFile(tool+'/src/Main.cj','utf8')===original);
const archive=products+'/cjfmt-host-'+v['source-ref'].slice(0,8)+'.tar.gz',unpack=products+'/fresh-unpack';
await run('same-install-package',['tar','-czf',archive,'-C',prefix,'.']);await fs.mkdir(unpack);
await run('fresh-unpack',['tar','-xzf',archive,'-C',unpack]);
await check('fresh-unpack-identity',await hash(unpack+'/bin/cjfmt')===rebuilt.sha256);
await fs.writeFile(work+'/package-identity.json',JSON.stringify({sourceRef:v['source-ref'],frontendRef:v['frontend-ref'],sdk,archive,archiveSha256:await hash(archive),installedSha256:await hash(prefix+'/bin/cjfmt'),unpackedSha256:await hash(unpack+'/bin/cjfmt'),qualification:'host development; target runtime NOT_RUN'},null,2));
await functional('unpacked',unpack);
console.log('NORMAL_CANGJIE_PRODUCTION_COMPLETE');
