#!/usr/bin/env zx
// Normal public production; input file supplies the already selected per-tool closure.
// This is an admitted integration gate, not part of the lightweight dispatcher test.
import fs from 'node:fs';import path from 'node:path';import assert from 'node:assert/strict';import {spawnSync} from 'node:child_process';
const cfg=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const root=path.resolve(import.meta.dirname,'..'),work=path.resolve(cfg.work),build=work+'/build',prefix=work+'/install';
fs.mkdirSync(work,{recursive:true});const commands=[];
function run(name,argv,{rc=0,env=process.env}={}){
 const started=new Date().toISOString(),p=spawnSync(argv[0],argv.slice(1),{cwd:root,env,encoding:'utf8',maxBuffer:32*1024*1024});
 fs.writeFileSync(work+'/'+name+'.stdout',p.stdout??'');fs.writeFileSync(work+'/'+name+'.stderr',p.stderr??'');
 commands.push({name,argv,cwd:root,started,ended:new Date().toISOString(),rc:p.status,signal:p.signal,error:p.error?.message??null});
 fs.writeFileSync(work+'/commands.json',JSON.stringify(commands,null,2));assert.equal(p.status,rc,name+': '+p.stderr);return p;
}
const selected='cjlint,cjprof',entry=[process.execPath,root+'/build.mjs'];
run('normal-build',[...entry,'build','--tool',selected,'--inputs',cfg.inputs,'--build-root',build]);
run('normal-install',[...entry,'install','--tool',selected,'--inputs',cfg.inputs,'--build-root',build,'--prefix',prefix]);
for(const f of ['bin/cjprof','lib/libcjprof-cangjie.so','lib/libcjprof-jni.so','share/java/cjprof.jar','config/static'])assert(fs.existsSync(prefix+'/cjprof/'+f));
function consume(install,tag){
 for(const name of ['cjlint','cjprof']){
  assert(Array.isArray(cfg.consumers[name])&&cfg.consumers[name].length>0,'actual business consumer required: '+name);
  run(tag+'-'+name,cfg.consumers[name].map(arg=>arg.replaceAll('{install}',install+'/'+name).replaceAll('{work}',work+'/'+tag+'-'+name)));
 }
}
consume(prefix,'installed');
const jni=build+'/cjprof/libcjprof-jni.so',saved=jni+'.cut';fs.renameSync(jni,saved);
try{
 const p=run('missing-jni',[...entry,'install','--tool','cjprof','--build-root',build,'--prefix',work+'/rejected'],{rc:1});
 assert.match(p.stderr,/ENOENT.*libcjprof-jni|libcjprof-jni.*ENOENT/s);assert(!fs.existsSync(jni));
 run('independent-lint',cfg.consumers.cjlint.map(arg=>arg.replaceAll('{install}',prefix+'/cjlint').replaceAll('{work}',work+'/control-lint')));
}finally{fs.renameSync(saved,jni);}
run('restore-install',[...entry,'install','--tool','cjprof','--build-root',build,'--prefix',prefix+'/cjprof']);
run('package',[...entry,'package','--tool',selected,'--prefix',prefix,'--archive',work+'/tools.tar.gz']);
fs.mkdirSync(work+'/unpacked');run('unpack',['tar','-xf',work+'/tools.tar.gz','-C',work+'/unpacked']);run('same-bytes',['diff','-qr',prefix,work+'/unpacked']);
fs.renameSync(prefix,prefix+'-hidden');try{consume(work+'/unpacked','unpacked');}finally{fs.renameSync(prefix+'-hidden',prefix);}
console.log('CANGJIE_PRODUCER_INSTALL_PACKAGE_COMPLETE');
