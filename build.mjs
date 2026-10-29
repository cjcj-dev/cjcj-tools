#!/usr/bin/env zx
// One public entry; each package retains its actual compiler/dependency closure.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';

const root=path.dirname(fileURLToPath(import.meta.url));
export const tools=['cjpm','cjfmt','hle','lsp','cjcov','cjtrace-recover','cjlint','cjprof','cjcompat','cjhead'];
const binaries={lsp:'cangjie-lsp'};
const args=process.argv.slice(2),phase=args.shift();
const separator=args.indexOf('--'),extra=separator<0?[]:args.splice(separator).slice(1);
const {values:o}=parseArgs({args,options:{tool:{type:'string',default:'all'},inputs:{type:'string'},'build-root':{type:'string'},prefix:{type:'string'},archive:{type:'string'},suite:{type:'string'},help:{type:'boolean'}}});
if(o.help||!phase){console.log('node build.mjs build|install|test|package|list --tool all|NAME[,NAME] [--inputs inputs.json] [--build-root target] [--prefix dist] [--archive file.tar.gz] [--suite tests/entry.mjs] [-- package arguments...]');process.exit(0);}
if(!['build','install','test','package','list'].includes(phase))throw Error('Unknown phase '+phase);
const selected=o.tool==='all'?tools:o.tool.split(',');
if(new Set(selected).size!==selected.length||selected.some(n=>!tools.includes(n)))throw Error('Unknown or duplicate tool '+o.tool);
if(phase==='list'){console.log(selected.join('\n'));process.exit(0);}
const inputs=o.inputs?JSON.parse(fs.readFileSync(path.resolve(o.inputs),'utf8')):{};
if(extra.length&&selected.length!==1)throw Error('Package arguments require one selected tool; use per-tool inputs for all');
const buildRoot=path.resolve(o['build-root']??path.join(root,'target'));
const prefix=path.resolve(o.prefix??path.join(root,'dist'));
function input(name){const row=inputs[name]??{};if(!row||typeof row!=='object'||Array.isArray(row))throw Error('Invalid inputs for '+name);return row;}
function installRoot(name){return selected.length===1?prefix:path.join(prefix,name);}
function option(argv,key,value){if(!argv.includes(key)&&!argv.some(a=>a.startsWith(key+'=')))argv.push(key,value);}
function run(argv,cwd,env){const r=spawnSync(argv[0],argv.slice(1),{cwd,env,stdio:'inherit'});if(r.error)throw r.error;if(r.signal){process.kill(process.pid,r.signal);throw Error('child signal '+r.signal);}if(r.status!==0)process.exit(r.status??1);}
// Multi-host input is explicit. Never apply one SDK override to all ten tools.
if(phase==='build'&&selected.length>1)for(const name of selected)if(!inputs[name])throw Error('Missing per-tool build inputs: '+name);
if(phase==='package'){
 if(!o.archive)throw Error('package requires --archive');
 const archive=path.resolve(o.archive);
 if(archive===prefix||archive.startsWith(prefix+path.sep))throw Error('archive must be outside installation');
 for(const name of selected)fs.accessSync(path.join(installRoot(name),'bin',(binaries[name]??name)+(process.platform==='win32'?'.exe':'')));
 fs.mkdirSync(path.dirname(archive),{recursive:true});
 run(['tar','-czf',archive,'-C',prefix,'.'],root,process.env);
 process.exit(0);
}
for(const name of selected){
 const row=input(name),source=path.join(root,'packages',name),build=path.join(buildRoot,name);
 const env={...process.env,...row.env};
 const forwarded=[...(row[phase]??[]),...extra];
 if(!Array.isArray(row[phase]??[])||forwarded.some(a=>typeof a!=='string'))throw Error('Expected argument array for '+name+'.'+phase);
 if(phase==='test'){
  const suite=o.suite??row.suite;
  if(!suite)throw Error('Select the actual consumer --suite for '+name);
  const script=path.resolve(source,suite);
  if(!script.startsWith(source+path.sep)||!script.endsWith('.mjs'))throw Error('Test suite must be a package .mjs entry');
  run([process.execPath,script,...forwarded],source,env);continue;
 }
 const argv=[process.execPath,path.join(source,'build/build.mjs')];
 if(name==='lsp'){
  argv.push('--phase',phase,...forwarded);option(argv,'--build',build);
  if(phase==='install')option(argv,'--install',installRoot(name));
 }else{
  argv.push(phase,...forwarded);option(argv,'--build-dir',build);
  if(phase==='install')option(argv,'--prefix',['cjpm','cjcov','hle'].includes(name)?path.join(installRoot(name),'bin'):installRoot(name));
 }
 run(argv,source,env);
 if(phase==='install'&&name==='cjpm'){
  const p=installRoot(name);fs.mkdirSync(path.join(p,'config'),{recursive:true});
  fs.renameSync(path.join(p,'bin/cangjie-repo.toml'),path.join(p,'config/cangjie-repo.toml'));
 }
}
