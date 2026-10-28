#!/usr/bin/env zx
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
let args=process.argv.slice(2),command=['build','install','clean'].includes(args[0])?args.shift():'build';
const split=args.indexOf('--'),cmakeArgs=split<0?[]:args.splice(split).slice(1);
const {values:v}=parseArgs({args,options:{
 'build-type':{type:'string',short:'t',default:'debug'},jobs:{type:'string',short:'j',default:process.env.CANGJIE_BUILD_JOBS||'4'},
 'build-dir':{type:'string'},prefix:{type:'string'},sdk:{type:'string'},
 'frontend-cjo':{type:'string'},'frontend-lib':{type:'string'},'frontend-native':{type:'string'},'frontend-ref':{type:'string'},'source-ref':{type:'string'},
 target:{type:'string',default:'native'},'code-coverage':{type:'boolean'},
 'gcc-toolchain':{type:'string'},'target-sysroot':{type:'string'},help:{type:'boolean',short:'h'},
}});
if(v.help){console.log('build.mjs [build [-t debug|release] [-j N] [--sdk SDK] [--frontend-cjo CJO] [--frontend-lib LIB] [--frontend-native OBJECT] [--frontend-ref SHA] [--source-ref SHA] [--target native|TRIPLE] [--code-coverage] [-- CMAKE_ARGS...] | install [--prefix DIR] | clean] [--build-dir DIR]');process.exit(0);}
const build=path.resolve(v['build-dir']||path.join(root,'build/build'));
const commands=[];
async function run(argv){
 const p=spawnSync(argv[0],argv.slice(1),{stdio:'inherit'});
 commands.push({argv,cwd:process.cwd(),rc:p.status,signal:p.signal,error:p.error?.message});
 await fs.writeFile(path.join(build,'entry-commands.json'),JSON.stringify(commands,null,2));
 if(p.status!==0)process.exit(p.status??1);
}
if(command==='clean'){
 // Only the selected build directory is removed, never the SDK/frontend inputs.
 if(build===root||build===path.parse(build).root||!build.startsWith(root+path.sep))throw Error('clean requires a build directory inside cjfmt');
 await fs.rm(build,{recursive:true,force:true});
}else{
 await fs.mkdir(build,{recursive:true});
 if(command==='install')await run(['cmake','--install',build,'--prefix',path.resolve(v.prefix||path.join(root,'dist'))]);
 else{
  if(!['debug','release'].includes(v['build-type']))throw Error('build type must be debug or release');
  if(!/^[1-9][0-9]*$/.test(v.jobs))throw Error('jobs must be a positive integer');
  if(v['gcc-toolchain']||v['target-sysroot'])throw Error('select the Cangjie SDK/frontend target closure; C/C++ toolchain overrides do not select a Cangjie compiler');
  const defs=['-DCMAKE_BUILD_TYPE='+v['build-type'],'-DCJFMT_JOBS='+v.jobs];
  const mapping={sdk:'CANGJIE_HOME','frontend-cjo':'CJFMT_FRONTEND_CJO','frontend-lib':'CJFMT_FRONTEND_LIB','frontend-native':'CJFMT_FRONTEND_NATIVE','frontend-ref':'CJFMT_FRONTEND_REF','source-ref':'CJFMT_SOURCE_REF'};
  for(const [key,name] of Object.entries(mapping))if(v[key])defs.push('-D'+name+'='+v[key]);
  if(v.target!=='native'){
   const target={'windows-x86_64':'x86_64-w64-mingw32','ohos-x86_64':'x86_64-unknown-linux-ohos','ohos-aarch64':'aarch64-unknown-linux-ohos'}[v.target]||v.target;
   defs.push('-DCJFMT_TARGET='+target);
  }
  defs.push('-DCJFMT_CODE_COVERAGE='+(v['code-coverage']?'ON':'OFF'));
  // Reconfigure warm trees as well: the caller's selected mode/closure must win.
  await run(['cmake','-S',root,'-B',build,...defs,...cmakeArgs]);
  await run(['cmake','--build',build,'--parallel',v.jobs]);
 }
}
