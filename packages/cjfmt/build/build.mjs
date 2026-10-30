#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const args=process.argv.slice(2),phase=args.shift();
const {values:v}=parseArgs({args,options:{'build-dir':{type:'string'},prefix:{type:'string'},sdk:{type:'string'},'cjpm-sdk':{type:'string'},'frontend-cjo':{type:'string'},'frontend-lib':{type:'string'},'frontend-native':{type:'string'},'frontend-ref':{type:'string'},'source-ref':{type:'string'},'build-type':{type:'string',short:'t',default:'release'},jobs:{type:'string',short:'j',default:'4'},target:{type:'string',default:'native'},'code-coverage':{type:'boolean'}}});
const build=path.resolve(v['build-dir']??path.join(root,'target'));
if(!['build','install'].includes(phase))throw Error('usage: build.mjs build|install --build-dir DIR [--prefix DIR]');
const argv=[process.execPath,path.join(root,'build/cangjie.mjs'),phase,'--build-dir',build];
if(phase==='install')argv.push('--prefix',path.resolve(v.prefix??path.join(root,'dist')));
else {
 const options={sdk:'CANGJIE_HOME','frontend-cjo':'CJFMT_FRONTEND_CJO','frontend-lib':'CJFMT_FRONTEND_LIB','frontend-native':'CJFMT_FRONTEND_NATIVE','frontend-ref':'CJFMT_FRONTEND_REF','source-ref':'CJFMT_SOURCE_REF'};
 for(const [key,env]of Object.entries(options))if(v[key]??process.env[env])argv.push('--'+key,v[key]??process.env[env]);
 if(v['cjpm-sdk'])argv.push('--cjpm-sdk',v['cjpm-sdk']);
 argv.push('--build-type',v['build-type'],'--jobs',v.jobs);
 if(v.target!=='native')argv.push('--target',({'windows-x86_64':'x86_64-w64-mingw32','ohos-x86_64':'x86_64-unknown-linux-ohos','ohos-aarch64':'aarch64-unknown-linux-ohos'})[v.target]??v.target);
 if(v['code-coverage'])argv.push('--coverage');
}
const p=spawnSync(argv[0],argv.slice(1),{cwd:root,stdio:'inherit'});
if(p.error)throw p.error;if(p.signal){process.kill(process.pid,p.signal);throw Error(p.signal);}process.exitCode=p.status??1;
