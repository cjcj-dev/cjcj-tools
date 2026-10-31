#!/usr/bin/env zx
// Public dispatcher contract. Fixture producers test argv/rc/layout, not tool algorithms.
import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import assert from 'node:assert/strict';import {spawnSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'..'),work=fs.mkdtempSync(path.join(process.env.TMPDIR??os.tmpdir(),'tools-entry-'));
const names=['cjpm','cjfmt','hle','lsp','cjcov','cjtrace-recover','cjlint','cjprof','cjcompat','cjhead'];
function invoke(base,args,rc=0){const p=spawnSync(process.execPath,[base+'/build.mjs',...args],{cwd:work,encoding:'utf8'});assert.equal(p.status,rc,p.stderr);return p;}
assert.deepEqual(invoke(root,['list']).stdout.trim().split('\n'),names);
invoke(root,['build'],1);invoke(root,['list','--tool','unknown'],1);invoke(root,['list','--tool','cjpm,cjpm'],1);
for(const name of names){assert(fs.statSync(root+'/packages/'+name+'/src').isDirectory());assert(fs.statSync(root+'/packages/'+name+'/build/build.mjs').isFile());}
for(const old of ['cjpm','cjfmt','cangjie-language-server','hyperlangExtension'])assert(!fs.existsSync(root+'/'+old));
const fixture=work+'/fixture';fs.mkdirSync(fixture);fs.copyFileSync(root+'/build.mjs',fixture+'/build.mjs');
const producer=`import fs from 'node:fs';import path from 'node:path';
const args=process.argv.slice(2),name=path.basename(path.resolve(import.meta.dirname,'..')),phase=name==='lsp'?args[1]:args[0];
fs.appendFileSync(process.env.RECORD,JSON.stringify({name,phase,args,cwd:process.cwd(),sdk:process.env.SELECTED_HOST})+'\\n');
if(process.env.FAIL_TOOL===name)process.exit(37);
if(phase==='install'){const key=name==='lsp'?'--install':'--prefix',prefix=args[args.indexOf(key)+1];const bin=['cjpm','cjcov','hle'].includes(name)?prefix:path.join(prefix,'bin');fs.mkdirSync(bin,{recursive:true});fs.writeFileSync(path.join(bin,name==='lsp'?'cangjie-lsp':name),'finite '+name);if(name==='cjpm')fs.writeFileSync(path.join(bin,'cangjie-repo.toml'),'finite config');}
`;
const record=work+'/records.jsonl',inputs={};for(const name of names){const dir=fixture+'/packages/'+name+'/build';fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(dir+'/build.mjs',producer);inputs[name]={env:{RECORD:record,SELECTED_HOST:'host-'+name},build:['--jobs','2']};}
const input=work+'/inputs.json';fs.writeFileSync(input,JSON.stringify(inputs));
invoke(fixture,['build','--inputs',input,'--build-root',work+'/build']);
let rows=fs.readFileSync(record,'utf8').trim().split('\n').map(JSON.parse);assert.equal(rows.length,10);
for(const row of rows){assert.equal(row.sdk,'host-'+row.name);assert.equal(row.cwd,fixture+'/packages/'+row.name);const key=row.name==='lsp'?'--build':'--build-dir';assert.equal(row.args[row.args.indexOf(key)+1],work+'/build/'+row.name);}
invoke(fixture,['install','--inputs',input,'--build-root',work+'/build','--prefix',work+'/installed']);
for(const name of names)assert.equal(fs.readFileSync(work+'/installed/'+name+'/bin/'+(name==='lsp'?'cangjie-lsp':name),'utf8'),'finite '+name);
assert(fs.existsSync(work+'/installed/cjpm/config/cangjie-repo.toml'));
invoke(fixture,['package','--prefix',work+'/installed','--archive',work+'/tools.tar.gz']);
fs.renameSync(work+'/installed/lsp/bin/cangjie-lsp',work+'/missing-lsp');invoke(fixture,['package','--prefix',work+'/installed','--archive',work+'/missing.tar.gz'],1);
fs.renameSync(work+'/missing-lsp',work+'/installed/lsp/bin/cangjie-lsp');invoke(fixture,['package','--prefix',work+'/installed','--archive',work+'/restored.tar.gz']);
inputs.cjfmt.env.FAIL_TOOL='cjfmt';fs.writeFileSync(input,JSON.stringify(inputs));invoke(fixture,['build','--inputs',input],37);
invoke(fixture,['build','--tool','cjpm','--inputs',input]);delete inputs.cjfmt.env.FAIL_TOOL;fs.writeFileSync(input,JSON.stringify(inputs));invoke(fixture,['build','--tool','cjfmt','--inputs',input]);
console.log('PUBLIC_ENTRY_CONTRACT_OK '+work);
// Keep the bootstrap dependency contract on the existing public test entry.
await import('./bootstrap-cjpm.mjs');
await import('./cjcompat-frontend.mjs');
await import('../packages/cjtrace-recover/tests/public/prepare-source.mjs');
