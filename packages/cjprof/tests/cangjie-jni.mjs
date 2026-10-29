#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const [prefix,jdk,fixtures,work]=process.argv.slice(2).map(x=>path.resolve(x));
fs.mkdirSync(work,{recursive:true});
const commands=[];
const sdk=JSON.parse(fs.readFileSync(path.join(prefix,'build-facts.json'),'utf8')).sdk;
const env={...process.env,CANGJIE_HOME:sdk,LD_LIBRARY_PATH:path.join(sdk,'runtime/lib/linux_x86_64_cjnative')+':'+path.join(sdk,'tools/lib')};
function run(name,argv){
 const childEnv=name==='functional'?{...env,LD_PRELOAD:path.join(jdk,'lib','libjsig.so')}:env;
 if(name==='functional'&&!fs.existsSync(childEnv.LD_PRELOAD))throw Error('selected JDK must provide lib/libjsig.so for JVM/runtime signal chaining');
 const p=spawnSync(argv[0],argv.slice(1),{env:childEnv,encoding:'utf8',timeout:90000,maxBuffer:16*1024*1024});
 fs.writeFileSync(path.join(work,name+'.stdout'),p.stdout??'');fs.writeFileSync(path.join(work,name+'.stderr'),p.stderr??'');
 commands.push({name,argv,LD_PRELOAD:childEnv.LD_PRELOAD,rc:p.status,signal:p.signal,error:p.error?.message});fs.writeFileSync(path.join(work,'commands.json'),JSON.stringify(commands,null,2));
 console.log(name+' rc='+p.status+' signal='+p.signal+'\n'+((p.stdout??'')+(p.stderr??'')).split('\n').slice(-25).join('\n'));
 if(p.status!==0)process.exit(p.status??1);
 if(name==='functional' && /WARNING in native method|FATAL ERROR in native method|handler modified/.test((p.stdout??'')+(p.stderr??''))) throw Error('JVM JNI or signal contract diagnostics');
}
run('compile',[path.join(jdk,'bin','javac'),'-cp',path.join(prefix,'share/java/cjprof.jar'),'-d',work,path.join(root,'tests','CangjieJniFunctional.java')]);
run('functional',[path.join(jdk,'bin','java'),'-Xmx512m','-Xcheck:jni','-Djava.library.path='+path.join(prefix,'lib'),'-cp',work+':'+path.join(prefix,'share/java/cjprof.jar'),'CangjieJniFunctional',fixtures,path.join(root,'tests','heap.data'),path.join(root,'tests','heap_multi_ref.data')]);
