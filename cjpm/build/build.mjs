#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
const build=path.dirname(fileURLToPath(import.meta.url)), root=path.dirname(build);
const argv=process.argv.slice(2);
for(let i=0;i<argv.length-1;i++)if(['-j','--jobs'].includes(argv[i])&&/^-[0-9]/.test(argv[i+1]))argv.splice(i,2,'--jobs='+argv[i+1]);
let parsed;
try { parsed=parseArgs({args:argv,allowPositionals:true,options:{
 'build-type':{type:'string',short:'t'},target:{type:'string'},'set-rpath':{type:'string'},
 'native-only':{type:'boolean'},jobs:{type:'string',short:'j'},prefix:{type:'string'},help:{type:'boolean',short:'h'}
}}); }catch(error){console.error(error.message);process.exit(2);}
const {positionals,values:o}=parsed;
function run(argv){
 console.log(JSON.stringify({argv,cwd:build}));
 const p=spawnSync(argv[0],argv.slice(1),{cwd:build,stdio:'inherit',env:{...process.env,ZERO_AR_DATE:'1'}});
 if(p.error)throw p.error;
 if(p.signal){process.kill(process.pid,p.signal);throw Error('child signal '+p.signal);}
 if(p.status!==0)process.exit(p.status??1);
}
function copy(from,to){fs.mkdirSync(path.dirname(to),{recursive:true});fs.copyFileSync(from,to);fs.chmodSync(to,fs.statSync(from).mode);}
try {
 const command=positionals[0], dist=path.join(root,'dist'), out=path.join(build,'bin/cjpm');
 if(o.help||!command){console.log('build -t release|debug [--target native|windows-x86_64|ohos-x86_64|ohos-aarch64] [-j N] [--set-rpath PATH]; install [--prefix DIR]; clean');}
 else if(command==='clean'){
   for(const p of [path.join(build,'bin'),dist])fs.rmSync(p,{recursive:true,force:true});
 } else if(command==='install'){
   const binaries=['cjpm','cjpm.exe'].filter(n=>fs.existsSync(path.join(dist,n)));
   if(!binaries.length)throw Error('no cjpm output; build first');
   if(o.prefix)for(const name of [...binaries,'cangjie-repo.toml'])copy(path.join(dist,name),path.resolve(o.prefix,name));
 } else if(command==='build'){
   const sdk=process.env.CANGJIE_HOME,stdx=process.env.CANGJIE_STDX_PATH;
   if(!sdk||!stdx)throw Error('CANGJIE_HOME and CANGJIE_STDX_PATH are required');
   if(!['release','debug'].includes(o['build-type']))throw Error('build-type must be release or debug');
   const requestedJobs=Number(o.jobs??process.env.CANGJIE_BUILD_JOBS??os.availableParallelism());
   if(!Number.isSafeInteger(requestedJobs)||requestedJobs<1){console.error('jobs must be a positive integer');process.exit(2);}
   const jobs=Math.min(requestedJobs,os.availableParallelism());
   const target=o.target??'native', cross=target!=='native';
   if(cross&&(process.platform!=='linux'||!['windows-x86_64','ohos-x86_64','ohos-aarch64'].includes(target)))throw Error('unsupported cross target '+target);
   const windows=process.platform==='win32'||target==='windows-x86_64',darwin=process.platform==='darwin';
   const ohos=target.startsWith('ohos-');
   // There is no native watcher producer. Keep this public phase as an empty
   // dependency phase; never build or ship the retired C++/libuv watcher.
   if(o['native-only']){console.log('cjpm native-only: no native tool sources');process.exit(0);}
   fs.mkdirSync(out,{recursive:true});fs.mkdirSync(dist,{recursive:true});
   const cjc=path.join(sdk,'bin',process.platform==='win32'?'cjc.exe':'cjc');
   const common=['-j'+jobs,'--trimpath='+build,'--import-path',path.join(build,'bin')];
   if(o['build-type']==='debug')common.push('-g');
   if(target==='windows-x86_64')common.push('--target=x86_64-windows-gnu');
   if(ohos){const arch=target.slice(5);common.push('--target='+arch+'-linux-ohos','--toolchain='+path.join(sdk,'lib','linux_ohos_'+arch+'_cjnative'));}
   const packages=['toml','util','config','watcher','implement','command'];
   for(const name of packages)run([cjc,...common,'-p',path.join(root,'src',name),'--import-path',stdx,'--output-type=staticlib','--output-dir',out,'-o','libcjpm.'+name+'.a']);
   const links=['-L',out,...[...packages].reverse().map(n=>'-lcjpm.'+n),'-L',stdx];
   for(const n of ['encoding.json','serialization.serialization','net.tls','net.http','net.tls.common','logger','log','encoding.url','encoding.json.stream','crypto.x509','crypto.keys','encoding.hex','crypto.crypto','crypto.digest','crypto.common','encoding.base64','compress','compress.zlib','compress.tar'])links.push('-lstdx.'+n);
   const extra=[];
   if(o['set-rpath']&&!windows)extra.push('--link-options='+(darwin?'-rpath '+o['set-rpath']:'--disable-new-dtags -rpath='+o['set-rpath']));
   if(windows){
     if(!process.env.MINGW_PATH)throw Error('MINGW_PATH is required');
     links.push('-L',path.join(process.env.MINGW_PATH,'x86_64-w64-mingw32/lib'),'-lcrypt32','-liphlpapi','-ldbghelp','-luserenv','-lole32','-lc++','-lunwind','-lpthread');
     extra.push('--link-options=--no-insert-timestamp'+(cross?' -static':''));
   }else if(darwin){links.push('-lc++','-ldl','-lpthread');}
   else {links.push('-lstdc++','-lgcc_s','-ldl','-lpthread');extra.push('--link-options=-z noexecstack -z relro -z now -s');}
   const binary=windows?'cjpm.exe':'cjpm';
   run([cjc,...common,'--import-path',stdx,...links,...extra,'-p',path.join(root,'src'),'-O2','--output-dir',out,'-o',binary]);
   copy(path.join(out,binary),path.join(dist,binary));copy(path.join(root,'config/cangjie-repo.toml'),path.join(dist,'cangjie-repo.toml'));
 }else throw Error('unknown command '+command);
}catch(error){console.error(error.stack);process.exitCode=1;}
