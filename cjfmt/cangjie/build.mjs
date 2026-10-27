#!/usr/bin/env zx
// Build the Cangjie formatter library against the selected compiler packages.
// The frontend is a fixed, read-only input; its source is not copied or forked.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
const {values:o}=parseArgs({options:Object.fromEntries(['frontend','sdk','cjpm','build','jobs'].map(k=>[k,{type:'string'}]))});
for(const key of ['frontend','sdk','cjpm','build'])if(!o[key])throw Error('Missing --'+key);
const root=path.dirname(fileURLToPath(import.meta.url));
const frontend=path.resolve(o.frontend),build=path.resolve(o.build),sdk=path.resolve(o.sdk);
const jobs=o.jobs??'4';
if(!/^[1-9][0-9]*$/.test(jobs))throw Error('Invalid --jobs');
fs.mkdirSync(build,{recursive:true});
const manifest=fs.readFileSync(root+'/cjpm.toml.in','utf8')
 .replaceAll('@SOURCE@',path.join(root,'src').replaceAll('\\','/'))
 .replaceAll('@FRONTEND@',frontend.replaceAll('\\','/'));
fs.writeFileSync(build+'/cjpm.toml',manifest);
const env={...process.env,CANGJIE_HOME:sdk,PATH:path.join(sdk,'bin')+path.delimiter+process.env.PATH};
const argv=[o.cjpm,'build','--target-dir',path.join(build,'target'),'-j',jobs,'-V'];
const started=new Date().toISOString();
const r=spawnSync(argv[0],argv.slice(1),{cwd:build,env,stdio:'inherit'});
fs.writeFileSync(build+'/build-command.json',JSON.stringify({argv,cwd:build,started,ended:new Date().toISOString(),rc:r.status,signal:r.signal,error:r.error?.message??null},null,2));
process.exitCode=r.status??1;
