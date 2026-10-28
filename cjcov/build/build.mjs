#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
const build=path.dirname(fileURLToPath(import.meta.url)),root=path.dirname(build);
const {values:o,positionals}=parseArgs({allowPositionals:true,options:{'build-type':{type:'string',short:'t'},target:{type:'string'},'set-rpath':{type:'string'},prefix:{type:'string'},jobs:{type:'string',short:'j'}}});
const command=positionals[0],dist=path.join(root,'dist');
function run(args){const r=spawnSync(args[0],args.slice(1),{cwd:build,env:{...process.env,ZERO_AR_DATE:'1'},stdio:'inherit'});if(r.error)throw r.error;if(r.signal){process.kill(process.pid,r.signal);throw Error(r.signal);}if(r.status!==0)process.exit(r.status??1);}
try {
 if(command==='clean'){for(const p of [path.join(build,'bin'),dist])fs.rmSync(p,{recursive:true,force:true});}
 else if(command==='install') {
  const name=process.platform==='win32'?'cjcov.exe':'cjcov',src=path.join(dist,name);
  if(!fs.statSync(src,{throwIfNoEntry:false})?.isFile())throw Error('No successful cjcov output');
  if(o.prefix){fs.mkdirSync(o.prefix,{recursive:true});fs.copyFileSync(src,path.join(o.prefix,name));fs.chmodSync(path.join(o.prefix,name),0o755);}
 } else if(command==='build') {
  if(!['release','debug'].includes(o['build-type']))throw Error('build-type must be release or debug');
  const sdk=process.env.CANGJIE_HOME,stdx=process.env.CANGJIE_STDX_PATH;
  if(!sdk||!stdx)throw Error('CANGJIE_HOME and CANGJIE_STDX_PATH required');
  const target=o.target??'native',win=process.platform==='win32'||target==='windows-x86_64',darwin=process.platform==='darwin';
  if(target!=='native'&&(process.platform!=='linux'||target!=='windows-x86_64'))throw Error('Unsupported cjcov target '+target);
  const jobs=o.jobs??'1';if(!/^[1-9][0-9]*$/.test(jobs))throw Error('Invalid jobs');
  const out=path.join(build,'bin/cjcov');fs.mkdirSync(out,{recursive:true});fs.mkdirSync(dist,{recursive:true});
  const cjc=path.join(sdk,'bin',process.platform==='win32'?'cjc.exe':'cjc');
  const common=['-j'+jobs,'--trimpath='+build,'--import-path',path.join(build,'bin'),'--import-path',stdx,'--output-dir',out,...(o['build-type']==='debug'?['-g']:[]),...(target==='windows-x86_64'?['--target=x86_64-windows-gnu']:[])];
  for(const name of ['util','core'])run([cjc,...common,'--output-type=staticlib','-p',path.join(root,'src',name),'-o','libcjcov.'+name+'.a']);
  const libs=['logger','log','encoding.json.stream','serialization.serialization','encoding.json'];
  const link=['-L',out,'-lcjcov.util','-lcjcov.core','-L',stdx,...libs.map(x=>'-lstdx.'+x)];
  if(o['set-rpath']&&!win)link.push('--link-options='+(darwin?'-rpath ':'--disable-new-dtags -rpath=')+o['set-rpath']);
  if(win)link.push('--link-options=--no-insert-timestamp');else if(!darwin)link.push('--link-options=-z noexecstack -z relro -z now -s');
  const name=win?'cjcov.exe':'cjcov';run([cjc,...common,...link,'-p',path.join(root,'src'),'-o',name]);
  fs.copyFileSync(path.join(out,name),path.join(dist,name));fs.chmodSync(path.join(dist,name),0o755);
 }else throw Error('Usage: build -t release|debug | install --prefix DIR | clean');
}catch(e){console.error(e.stack);process.exitCode=1;}
