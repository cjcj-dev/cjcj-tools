#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {parseArgs} from 'node:util';
import {createHash} from 'node:crypto';
const tool=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const {positionals,values:v}=parseArgs({allowPositionals:true,options:{sdk:{type:'string'},'compiler-source':{type:'string'},'frontend-ref':{type:'string'},'compiler-libs':{type:'string'},'tools-revision':{type:'string'},'runtime-config':{type:'string'},shim:{type:'string'},llvm:{type:'string'},'build-dir':{type:'string'},prefix:{type:'string'},output:{type:'string'},type:{type:'string',default:'release'},jobs:{type:'string',default:'4'}}});
const command=positionals[0],build=path.resolve(v['build-dir']??path.join(tool,'build/cangjie-build'));
fs.mkdirSync(build,{recursive:true});
const records=[];
function run(argv,cwd=tool,env=process.env){
 const start=new Date().toISOString(); const p=spawnSync(argv[0],argv.slice(1),{cwd,env,stdio:'inherit'});
 records.push({argv,cwd,start,end:new Date().toISOString(),rc:p.status,signal:p.signal,error:p.error?.message??null});
 fs.writeFileSync(path.join(build,command+'-commands.json'),JSON.stringify(records,null,2)+'\n');
 if(p.error||p.signal||p.status!==0)process.exit(p.status??1);
}
function required(name){if(!v[name])throw Error('--'+name+' is required');return path.resolve(v[name]);}
if(command==='build'){
 const sdk=required('sdk'),source=required('compiler-source'),libs=required('compiler-libs'),shim=required('shim'),llvm=required('llvm');
 if(!['release','debug'].includes(v.type)||!/^\d+$/.test(v.jobs)||Number(v.jobs)<1)throw Error('invalid build type/jobs');
 const frontendRef=v['frontend-ref']??'523a2dbec18cae73c83f1553d938f4eff0664508';
 if(!/^[0-9a-f]{40}$/.test(frontendRef))throw Error('frontend-ref must be a full source commit');
 const revision=spawnSync('git',['rev-parse','HEAD'],{cwd:source,encoding:'utf8'});
 if(revision.status!==0||revision.signal||revision.stdout.trim()!==frontendRef)throw Error('compiler source must be fixed '+frontendRef);
 const env={...process.env,CANGJIE_HOME:sdk,TMPDIR:process.env.TMPDIR??build,
 LD_LIBRARY_PATH:[sdk+'/runtime/lib/linux_x86_64_cjnative',sdk+'/tools/lib',path.dirname(llvm)].join(':')};
 delete env.LD_PRELOAD;delete env.LD_AUDIT;
 const argv=[path.join(sdk,'bin/cjc'),'-p',path.join(tool,'src'),'--import-path='+libs,'-j'+v.jobs,'--error-count-limit','all',v.type==='debug'?'-g':'-O2'];
 // Link the compiler's existing Cangjie libraries, including subpackages.
 // Native support is exactly the compiler's preexisting LLVM/OS shim; there
 // is no C++ cjcompat, libcangjie-lsp or compatibility business layer.
 const archives=[];
 const excluded=new Set(['compiler_unittest@cjcj','driver@cjcj','frontend_tool@cjcj']);
 for(const entry of fs.readdirSync(libs,{withFileTypes:true}).sort((a,b)=>a.name.localeCompare(b.name))){
  if(!entry.isDirectory()||!entry.name.endsWith('@cjcj')||excluded.has(entry.name))continue;
  const dir=path.join(libs,entry.name);argv.push('-L',dir);
  for(const file of fs.readdirSync(dir).filter(f=>/^lib.*\.a$/.test(f)).sort()){
   archives.push(path.join(dir,file));
  }
 }
 const runtime=path.resolve(v['runtime-config']??path.join(source,'runtime_shim/cjc_runtime_config.o'));
 const links=['--start-group',...archives,'--end-group',runtime,shim,llvm,'-lstdc++'];
 argv.push('--link-options',links.join(' '),'-o',path.join(build,'cjcompat'));
 const ownRevision=spawnSync('git',['rev-parse','HEAD'],{cwd:tool,encoding:'utf8'});
 const toolsRevision=v['tools-revision']??(ownRevision.status===0?ownRevision.stdout.trim():null);
 if(toolsRevision!==null&&!/^[0-9a-f]{40}$/.test(toolsRevision))throw Error('tools revision must be a full Git SHA');
 const inputs={toolsRevision,compilerSource:source,compilerRevision:revision.stdout.trim(),libs,sdk,runtime,shim,llvm,archives,type:v.type,jobs:Number(v.jobs),scope:'host; target runtime rebuild separate'};
 fs.writeFileSync(path.join(build,'inputs.json'),JSON.stringify(inputs,null,2)+'\n');
 run(argv,tool,env);
 const executable=path.join(build,'cjcompat');
 inputs.executable={bytes:fs.statSync(executable).size,sha256:createHash('sha256').update(fs.readFileSync(executable)).digest('hex')};
 fs.writeFileSync(path.join(build,'inputs.json'),JSON.stringify(inputs,null,2)+'\n');
}else if(command==='install'){
 const prefix=required('prefix');fs.mkdirSync(path.join(prefix,'bin'),{recursive:true});
 fs.copyFileSync(path.join(build,'cjcompat'),path.join(prefix,'bin/cjcompat'));fs.chmodSync(path.join(prefix,'bin/cjcompat'),0o755);
 fs.mkdirSync(path.join(prefix,'share/cjcompat'),{recursive:true});
 fs.copyFileSync(path.join(build,'inputs.json'),path.join(prefix,'share/cjcompat/build-inputs.json'));
}else if(command==='package'){
 const prefix=required('prefix'),output=required('output');
 if(output===prefix||output.startsWith(prefix+path.sep))throw Error('archive must be outside installation');
 run(['tar','-czf',output,'-C',prefix,'.']);
}else{throw Error('usage: build.mjs build|install|package --sdk ... --compiler-source ... --compiler-libs ... --shim ... --llvm ... --build-dir ... --prefix ... --output ...');}
