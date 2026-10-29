#!/usr/bin/env zx
// Targeted real producer cache regression; unrelated formatter matrices are separate.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {parseArgs} from 'node:util';
import {createHash} from 'node:crypto';
const {values:v}=parseArgs({options:{work:{type:'string'},inputs:{type:'string'},trace:{type:'string'},'resume-build':{type:'string'}}});
function compilerCommands(file) {
 return fs.readFileSync(file,'utf8').split('\n').filter(line=>line.includes('execve(')&&line.endsWith('= 0')&&line.includes('/bin/cjc"'));
}
function producing(file) {
 return compilerCommands(file).filter(line=>!line.includes('"--scan-dependency"')&&!/\["[^"]+", "-v"\]/.test(line));
}
if(v.trace){const rows=producing(v.trace);console.log(JSON.stringify({marker:rows.length?'FMT_CACHE_RECOMPILED':'FMT_CACHE_REUSED',producing:rows}));process.exit(rows.length?41:0);}
assert(v.work&&v.inputs,'--work and --inputs required');
const tool=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..'),root=path.resolve(tool,'../..'),work=path.resolve(v.work),inputs=path.resolve(v.inputs);
assert(!fs.existsSync(work),'work must be new');fs.mkdirSync(work,{recursive:true});
const ev=path.join(work,'evidence'),source=path.join(work,'source'),build=path.resolve(v['resume-build']??path.join(work,'build')),install=path.join(work,'install'),unpack=path.join(work,'unpack');fs.mkdirSync(ev);fs.mkdirSync(path.join(source,'packages'),{recursive:true});
fs.copyFileSync(path.join(root,'build.mjs'),path.join(source,'build.mjs'));fs.cpSync(tool,path.join(source,'packages/cjfmt'),{recursive:true});
const script=path.join(source,'packages/cjfmt/build/cangjie.mjs'),main=path.join(source,'packages/cjfmt/src/Main.cj'),original=fs.readFileSync(script,'utf8'),mainOriginal=fs.readFileSync(main,'utf8');
const entry=path.join(source,'build.mjs'),suite=path.join(tool,'tests/cangjie/cache.mjs'),node=process.execPath;
const config=JSON.parse(fs.readFileSync(inputs,'utf8')).cjfmt,env={...process.env,...config.env};
const sdk=config.env?.CANGJIE_HOME??process.env.CANGJIE_HOME;assert(sdk,'fmt execution SDK required');
const commands=[],checks=[];function save(){fs.writeFileSync(ev+'/result.json',JSON.stringify({commands,checks},null,2));}
function run(label,argv,expected=0){const started=new Date().toISOString(),out=fs.openSync(ev+'/'+label+'.stdout','wx'),err=fs.openSync(ev+'/'+label+'.stderr','wx');const r=spawnSync(argv[0],argv.slice(1),{cwd:work,env,stdio:['ignore',out,err]});fs.closeSync(out);fs.closeSync(err);commands.push({label,argv,cwd:work,started,ended:new Date().toISOString(),rc:r.status,signal:r.signal,error:r.error?.message??null,expected});save();assert.equal(r.status,expected,label);assert.equal(r.signal,null,label);return fs.readFileSync(ev+'/'+label+'.stdout','utf8');}
function check(name,pass,detail){checks.push({name,pass,detail});save();assert(pass,name);}
function hash(file){return createHash('sha256').update(fs.readFileSync(file)).digest('hex');}
function buildArm(label,extra=[]){const trace=ev+'/'+label+'.execve';run(label,['strace','-f','-s','65536','-e','trace=execve','-o',trace,node,entry,'build','--tool','cjfmt','--inputs',inputs,'--build-root',build,...extra]);const cache=build+'/cjfmt/target/release/incremental-cache.json';if(fs.existsSync(cache))fs.copyFileSync(cache,ev+'/'+label+'-incremental-cache.json');return trace;}
function cacheArm(label,extra=[]){const trace=buildArm(label,extra);run(label+'-target',[node,suite,'--trace',trace]);return trace;}
function staged(){const w=build+'/cjfmt/workspace';return ['src/Main.cj','frontend-binaries/parse@cjcj/parse@cjcj.cjo','cjpm.toml','cangjie-repo.toml'].map(n=>({name:n,mtime:fs.statSync(w+'/'+n,{bigint:true}).mtimeNs.toString()}));}
function functional(label,bin){const src=work+'/'+label+'.cj',formatted=work+'/'+label+'-formatted.cj',exe=work+'/'+label+'-program';fs.writeFileSync(src,'main(){println(7)}\n');run(label+'-format',[bin,'-f',src,'-o',formatted]);check(label+'-layout',fs.readFileSync(formatted,'utf8')==='main() {\n    println(7)\n}\n');run(label+'-compile',[sdk+'/bin/cjc',formatted,'-o',exe]);check(label+'-run',run(label+'-run',[exe]).trim()==='7');}
try {
 if(!v['resume-build']){
 const first=buildArm('first');check('first-real-CJ-compile',producing(first).length>0);
 const before=staged(),elf=hash(build+'/cjfmt/cjfmt');fs.writeFileSync(ev+'/first-staged-inputs.json',JSON.stringify({inputs:before,elf}));
 cacheArm('same-default');check('unchanged-staging',JSON.stringify(staged())===JSON.stringify(before));check('cached-ELF',hash(build+'/cjfmt/cjfmt')===elf);
 cacheArm('same-explicit',['--','--build-type','release','--jobs','4']);
 // Actual changed source must still invalidate the normal CJPM input graph.
 fs.writeFileSync(main,mainOriginal+'\n// cache source-change control\n');const change=buildArm('source-change');check('source-change-recompiled',producing(change).length>0);
 fs.writeFileSync(main,mainOriginal);const sourceRestore=buildArm('source-restored');check('source-restored-recompiled',producing(sourceRestore).length>0);cacheArm('source-restored-cache');
 }else{fs.writeFileSync(ev+'/reused-build.json',JSON.stringify({build,inputs:JSON.parse(fs.readFileSync(build+'/cjfmt/inputs.json','utf8')),scope:'reuse completed first/default/explicit/changed/restored arms; continue source-add/delete onward'}));}
 const added=path.join(source,'packages/cjfmt/src/CacheRemovalControl.cj');fs.writeFileSync(added,'package cjfmt\nfunc cacheRemovalControl(): Int64 { return 1 }\n');check('source-added-recompiled',producing(buildArm('source-added')).length>0);
 fs.unlinkSync(added);check('source-deleted-recompiled',producing(buildArm('source-deleted')).length>0);check('stale-source-removed',!fs.existsSync(build+'/cjfmt/workspace/src/CacheRemovalControl.cj'));cacheArm('source-deleted-cache');
 const anchor='if(previous?.equals(bytes))return;';assert.equal(original.split(anchor).length,2);
 fs.writeFileSync(script,original.replace(anchor,'if(false)return; // isolated same-byte staging cut'));
 fs.writeFileSync(ev+'/cut-source.mjs',fs.readFileSync(script));
 const cut=buildArm('cut-cache');run('cut-exact-target',[node,suite,'--trace',cut],41);functional('cut-independent-control',build+'/cjfmt/cjfmt');
 fs.writeFileSync(script,original);cacheArm('restored-cache');
 run('normal-install',[node,entry,'install','--tool','cjfmt','--inputs',inputs,'--build-root',build,'--prefix',install]);functional('installed',install+'/bin/cjfmt');
 const archive=work+'/cjfmt-cache-fixed.tar.gz';run('same-install-package',[node,entry,'package','--tool','cjfmt','--prefix',install,'--archive',archive]);fs.mkdirSync(unpack);run('fresh-unpack',['tar','-xzf',archive,'-C',unpack]);run('package-diff',['diff','-qr',install,unpack]);
 // All previous consumers are synchronous and have exited; only this new prefix is hidden.
 fs.renameSync(install,install+'-hidden');try{functional('unpacked',unpack+'/bin/cjfmt');}finally{fs.renameSync(install+'-hidden',install);}
 fs.writeFileSync(ev+'/terminal.json',JSON.stringify({rc:0,archive,size:fs.statSync(archive).size,sha256:hash(archive),installedSha256:hash(install+'/bin/cjfmt'),unpackedSha256:hash(unpack+'/bin/cjfmt'),scope:'fmt normal producer cache; Linux H development only'}));
}finally{fs.writeFileSync(script,original);fs.writeFileSync(main,mainOriginal);save();}
