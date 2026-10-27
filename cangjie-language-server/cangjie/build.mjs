#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
const {values:o}=parseArgs({options:Object.fromEntries(['frontend','frontend-packages','runtime-config','sdk','cjpm','build','jobs'].map(k=>[k,{type:'string'}]))});
for(const k of ['sdk','cjpm','build'])if(!o[k])throw Error('Missing --'+k);
if(Boolean(o.frontend)===Boolean(o['frontend-packages']))throw Error('Select source --frontend or shared --frontend-packages');
const root=path.dirname(fileURLToPath(import.meta.url)),build=path.resolve(o.build),frontend=o.frontend?path.resolve(o.frontend):null,sdk=path.resolve(o.sdk);
const jobs=o.jobs??'4';if(!/^[1-9][0-9]*$/.test(jobs))throw Error('Invalid jobs');
fs.mkdirSync(build,{recursive:true});
// CJPM requires src-dir inside its module. This is the normal build workspace
// copy of this tool's source; dependency packages remain the selected input.
fs.cpSync(root+'/src',build+'/src',{recursive:true});
fs.cpSync(root+'/protocol',build+'/protocol',{recursive:true});
let manifest=fs.readFileSync(root+'/cjpm.toml.in','utf8');
if(frontend){manifest=manifest.replaceAll('@FRONTEND@',frontend.replaceAll('\\','/'));}
else {
 manifest=manifest.replace(/^"cjcj::.*$/gm,'');
 const dirs=['basic','utils','lex','option','ast','parse'].map(name=>path.resolve(o['frontend-packages'],name+'@cjcj').replaceAll('\\','/'));
 manifest+='\n[target.x86_64-unknown-linux-gnu.bin-dependencies]\npath-option = '+JSON.stringify(dirs)+'\n';
}
if(o['runtime-config'])manifest=manifest.replace('output-type = "static"','output-type = "static"\nlink-option = '+JSON.stringify(path.resolve(o['runtime-config']).replaceAll('\\','/')));
fs.writeFileSync(build+'/cjpm.toml',manifest);
const argv=[o.cjpm,'build','--target-dir',build+'/target','-j',jobs,'-V'];
const started=new Date().toISOString();
const r=spawnSync(argv[0],argv.slice(1),{cwd:build,env:{...process.env,CANGJIE_HOME:sdk,PATH:sdk+'/bin'+path.delimiter+process.env.PATH},stdio:'inherit'});
fs.writeFileSync(build+'/build-command.json',JSON.stringify({argv,cwd:build,started,ended:new Date().toISOString(),rc:r.status,signal:r.signal,error:r.error?.message??null},null,2));
process.exitCode=r.status??1;
