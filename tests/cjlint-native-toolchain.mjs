#!/usr/bin/env zx
// Run on the allocated native host, in a private source checkout. No mock compiler.
// --state warm requires an existing build configured with a different GCC selection.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
const {values:v}=parseArgs({options:{sdk:{type:'string'},dependencies:{type:'string'},
  'gcc-toolchain':{type:'string'},work:{type:'string'},jobs:{type:'string'},state:{type:'string'}}});
for(const name of ['sdk','dependencies','gcc-toolchain','work','jobs','state'])assert.ok(v[name],`--${name} required`);
assert.equal(process.platform,'linux');
assert.match(v.jobs,/^[1-9][0-9]*$/);
assert.ok(['cold','warm'].includes(v.state));
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const sdk=path.resolve(v.sdk),gcc=path.resolve(v['gcc-toolchain']),work=path.resolve(v.work);
const source=path.join(root,'cjlint'),build=path.join(source,'build/build'),cache=path.join(build,'CMakeCache.txt');
const prior=fs.existsSync(cache)?fs.readFileSync(cache,'utf8'):null;
if(v.state==='cold')assert.equal(prior,null,'cold must reach first configure');
else {
  assert.notEqual(prior,null,'warm must reuse the existing CMake build');
  assert.notEqual(prior.match(/^GCC_TOOLCHAIN_FLAG:[^=]*=(.*)$/m)?.[1],gcc,
  'warm must change the prior toolchain selection');
}
fs.mkdirSync(work,{recursive:false});
fs.writeFileSync(path.join(work,'cache-before.txt'),prior??'<no prior cache>\n');
const prefix=path.join(work,'install'),commands=[],checks=[];
const env={...process.env,CANGJIE_HOME:sdk,CANGJIE_BUILD_JOBS:v.jobs,
  PATH:path.join(sdk,'bin')+path.delimiter+process.env.PATH,
  LD_LIBRARY_PATH:[path.join(prefix,'lib'),path.join(sdk,'runtime/lib/linux_x86_64_cjnative'),
    path.join(sdk,'lib/linux_x86_64_cjnative'),path.join(sdk,'tools/lib')].join(path.delimiter)};
delete env.LD_PRELOAD;delete env.LD_AUDIT;
function run(name,argv,cwd=source){
  const r=spawnSync(argv[0],argv.slice(1),{cwd,env,encoding:'utf8',maxBuffer:64*1024*1024});
  fs.writeFileSync(path.join(work,name+'.stdout'),r.stdout??'');
  fs.writeFileSync(path.join(work,name+'.stderr'),r.stderr??'');
  commands.push({name,argv,cwd,rc:r.status,signal:r.signal,error:r.error?.message??null});
  fs.writeFileSync(path.join(work,'commands.json'),JSON.stringify(commands,null,2));
  assert.equal(r.status,0,`${name}: see original stdout/stderr`);return r;
}
function check(name,fn){
  try{fn();checks.push({name,pass:true});}
  catch(e){checks.push({name,pass:false,error:e.message});throw e;}
  finally{fs.writeFileSync(path.join(work,'assertions.json'),JSON.stringify({checks},null,2));}
}
const entry=['python3',path.join(source,'build/build.py')];
run('normal-build',[...entry,'build','-t','release','--target','native','--jobs',v.jobs,
  '--gcc-toolchain',gcc,'--dependencies',path.resolve(v.dependencies)]);
fs.copyFileSync(cache,path.join(work,'cache-after.txt'));
const invocations=JSON.parse(fs.readFileSync(path.join(build,'compile_commands.json'),'utf8'));
check('every native compilation selects the supplied GCC installation',()=>{
  assert.ok(invocations.length>0);
  for(const c of invocations){
    assert.ok(c.command.includes('--gcc-toolchain='+gcc),c.file);
    assert.equal(c.command.split('--gcc-toolchain=').length-1,1,'no stale compiler ARG1: '+c.file);
  }
});
// Ninja deps records the headers actually read by compilation, not only a CMake variable.
const deps=run('actual-header-deps',['ninja','-C',build,'-t','deps']);
check('actual optional header comes from selected GCC installation',()=>
  assert.ok(deps.stdout.split('\n').some(l=>l.includes(gcc+'/')&&l.trim().endsWith('/optional'))));
const graph=run('native-commands',['ninja','-C',build,'-t','commands']);
check('shared library and executable link use the selected toolchain',()=>{
  const links=graph.stdout.split('\n').filter(l=>/ -o (lib\/libcjlint\.so|bin\/cjlint)( |$)/.test(l));
  assert.equal(links.length,2);
  for(const l of links)assert.ok(l.includes('--gcc-toolchain='+gcc),l);
});
run('normal-install',[...entry,'install','--prefix',prefix]);
const exe=path.join(prefix,'bin/cjlint');
run('installed-identity',['sha256sum',exe,path.join(prefix,'lib/libcjlint.so')]);
const loader=run('installed-loader',['ldd',exe]);
check('consumer loads private lint and the selected official LSP',()=>{
  assert.ok(loader.stdout.includes(path.join(prefix,'lib/libcjlint.so')));
  assert.ok(loader.stdout.includes(path.join(sdk,'tools/lib/libcangjie-lsp.so')));
});
run('help-control',[exe,'-h'],prefix);
for(const [name,keyword] of [['mutable','var'],['immutable','let']]){
  const dir=path.join(work,name);fs.mkdirSync(dir);
  fs.writeFileSync(path.join(dir,'main.cj'),`main(): Int64 {\n    ${keyword} value: Int64 = 42\n    return value\n}\n`);
  run(name+'-compile',[path.join(sdk,'bin/cjc'),path.join(dir,'main.cj'),'-o',path.join(dir,'program')]);
  const report=path.join(work,name+'-report');
  run(name+'-lint',[exe,'-f',dir,'-c',prefix,'-m',sdk,'-o',report,'-r','json'],prefix);
  check(name+' actual G.VAR.01 consumption',()=>{
    const output=JSON.parse(fs.readFileSync(report+'.json','utf8'));
    assert.ok(Array.isArray(output));
    assert.equal(output.some(x=>x.description?.includes('G.VAR.01')&&x.description.includes("'value'")),name==='mutable');
  });
}
