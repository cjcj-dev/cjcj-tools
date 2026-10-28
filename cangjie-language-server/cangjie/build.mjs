#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
const {values:o}=parseArgs({options:Object.fromEntries(['phase','frontend','frontend-packages','runtime-config','sdk','cjpm','build','jobs','server','json-build','llvm-shim','llvm-library','install'].map(k=>[k,{type:'string'}]))});
if(o.phase && !['build','install'].includes(o.phase))throw Error('Invalid --phase');
function install(build,prefix) {
 const facts=JSON.parse(fs.readFileSync(build+'/server-build-command.json','utf8'));
 if(facts.rc!==0||!facts.inputs?.sdk||!facts.inputs?.llvmLibrary)throw Error('No successful normal server build with install inputs');
 fs.mkdirSync(prefix+'/bin',{recursive:true});fs.mkdirSync(prefix+'/lib',{recursive:true});
 fs.copyFileSync(build+'/server/target/release/bin/main',prefix+'/bin/cangjie-lsp');fs.chmodSync(prefix+'/bin/cangjie-lsp',0o755);
 fs.cpSync(facts.inputs.sdk+'/runtime/lib/linux_x86_64_cjnative',prefix+'/lib',{recursive:true,dereference:true});
 fs.copyFileSync(fs.realpathSync(facts.inputs.llvmLibrary),prefix+'/lib/'+path.basename(facts.inputs.llvmLibrary));
}
if(o.phase==='install') {
 if(!o.build||!o.install)throw Error('Install requires --build and --install');
 install(path.resolve(o.build),path.resolve(o.install));process.exit(0);
}
for(const k of ['sdk','cjpm','build'])if(!o[k])throw Error('Missing --'+k);
if(Boolean(o.frontend)===Boolean(o['frontend-packages']))throw Error('Select source --frontend or shared --frontend-packages');
const root=path.dirname(fileURLToPath(import.meta.url)),build=path.resolve(o.build),frontend=o.frontend?path.resolve(o.frontend):null,sdk=path.resolve(o.sdk);
const jobs=o.jobs??'4';if(!/^[1-9][0-9]*$/.test(jobs))throw Error('Invalid jobs');
fs.mkdirSync(build,{recursive:true});
// CJPM requires src-dir inside its module. This is the normal build workspace
// copy of this tool's source; dependency packages remain the selected input.
function copySource(from,to) {
 fs.mkdirSync(to,{recursive:true});
 for(const e of fs.readdirSync(from,{withFileTypes:true})) {
  const a=path.join(from,e.name),b=path.join(to,e.name);
  if(e.isDirectory())copySource(a,b);
  else if(!fs.existsSync(b)||!fs.readFileSync(a).equals(fs.readFileSync(b)))fs.copyFileSync(a,b);
 }
 for(const e of fs.readdirSync(to))if(!fs.existsSync(path.join(from,e)))fs.rmSync(path.join(to,e),{recursive:true,force:true});
}
copySource(root+'/src',build+'/src');copySource(root+'/protocol',build+'/protocol');
let manifest=fs.readFileSync(root+'/cjpm.toml.in','utf8');
if(frontend){manifest=manifest.replaceAll('@FRONTEND@',frontend.replaceAll('\\','/'));}
else {
 manifest=manifest.replace(/^"cjcj::.*$/gm,'');
 const dirs=['basic','utils','lex','option','ast','parse','flatbuffers','conditional_compilation','modules','macro_pkg','meta_transformation','mangle','sema','chir','codegen','incremental_compilation','frontend'].map(name=>path.resolve(o['frontend-packages'],name+'@cjcj').replaceAll('\\','/'));
 manifest+='\n[target.x86_64-unknown-linux-gnu.bin-dependencies]\npath-option = '+JSON.stringify(dirs)+'\n';
}
if(o['runtime-config'])manifest=manifest.replace('output-type = "static"','output-type = "static"\nlink-option = '+JSON.stringify(path.resolve(o['runtime-config']).replaceAll('\\','/')));
fs.writeFileSync(build+'/cjpm.toml',manifest);
const argv=[o.cjpm,'build','--target-dir',build+'/target','-j',jobs,'-V'];
const started=new Date().toISOString();
const r=spawnSync(argv[0],argv.slice(1),{cwd:build,env:{...process.env,CANGJIE_HOME:sdk,PATH:sdk+'/bin'+path.delimiter+process.env.PATH},stdio:'inherit'});
fs.writeFileSync(build+'/build-command.json',JSON.stringify({argv,cwd:build,started,ended:new Date().toISOString(),rc:r.status,signal:r.signal,error:r.error?.message??null},null,2));
if(r.status!==0)process.exit(r.status??1);
if(o.server){
 for(const key of ['frontend-packages','runtime-config','json-build','llvm-shim','llvm-library'])if(!o[key])throw Error('Server requires --'+key);
 const app=build+'/server';fs.mkdirSync(app,{recursive:true});copySource(root+'/server',app+'/src');
 const names=['basic','utils','lex','option','ast','parse','flatbuffers','conditional_compilation','modules','macro_pkg','meta_transformation','mangle','sema','chir','codegen','incremental_compilation','frontend'];
 const bins=names.map(name=>path.resolve(o['frontend-packages'],name+'@cjcj'));
 bins.push(build+'/target/release/cangjie_lsp_core',build+'/target/release/cangjie_lsp_protocol',path.resolve(o['json-build'],'modules/linux_x86_64_cjnative/stdx'));
 fs.writeFileSync(app+'/runtime-link.rsp','-rpath "$ORIGIN/../lib"\n');
 const link=[o['runtime-config'],o['llvm-shim'],o['llvm-library'],'-lstdc++',
 path.resolve(o['json-build'],'lib/linux_x86_64_cjnative/libstdx.encoding.json.a'),
 path.resolve(o['json-build'],'lib/linux_x86_64_cjnative/libstdx.serialization.serialization.a'),'@'+app+'/runtime-link.rsp'];
 fs.writeFileSync(app+'/cjpm.toml','[package]\nname = "cangjie_lsp"\nversion = "0.1.0"\ncjc-version = "1.1.0"\noutput-type = "executable"\nsrc-dir = "src"\nlink-option = '+JSON.stringify(link.join(' '))+'\n[target.x86_64-unknown-linux-gnu.bin-dependencies]\npath-option = '+JSON.stringify(bins)+'\n');
 const argv=[o.cjpm,'build','--target-dir',app+'/target','-j',jobs,'-V'],started=new Date().toISOString();
 const r=spawnSync(argv[0],argv.slice(1),{cwd:app,env:{...process.env,CANGJIE_HOME:sdk,PATH:sdk+'/bin'+path.delimiter+process.env.PATH},stdio:'inherit'});
 fs.writeFileSync(build+'/server-build-command.json',JSON.stringify({argv,cwd:app,started,ended:new Date().toISOString(),rc:r.status,signal:r.signal,error:r.error?.message??null,inputs:{sdk,frontendPackages:path.resolve(o['frontend-packages']),llvmLibrary:path.resolve(o['llvm-library']),runtimeConfig:path.resolve(o['runtime-config']),jsonBuild:path.resolve(o['json-build']),llvmShim:path.resolve(o['llvm-shim'])}},null,2));
 if(r.status!==0)process.exit(r.status??1);
 if(o.install)install(build,path.resolve(o.install));
}
