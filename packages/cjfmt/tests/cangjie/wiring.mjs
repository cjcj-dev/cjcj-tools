#!/usr/bin/env zx
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const [fmt,work]=process.argv.slice(2);
await fs.mkdir(work,{recursive:true});
const commands=[],checks=[];
async function run(label,args){const argv=[fmt,...args],p=spawnSync(fmt,args,{encoding:'utf8',timeout:60000});commands.push({label,argv,rc:p.status,signal:p.signal});await fs.writeFile(path.join(work,label+'.log'),(p.stdout??'')+(p.stderr??''));return p;}
await fs.writeFile(work+'/input.cj','main(){println(7)}\n');
await fs.writeFile(work+'/format.toml','indentWidth = 4\n');
const target=await run('format',['-f',work+'/input.cj','-o',work+'/output.cj','-c',work+'/format.toml']);
const output=await fs.readFile(work+'/output.cj','utf8').catch(()=>null);
checks.push({label:'format-assertion-reached',pass:target.status===0&&output!==null});
checks.push({label:'native-layout-consumed',pass:output==='main() {\n    println(7)\n}\n',actual:output});
const version=await run('version',['-v']);checks.push({label:'version-control',pass:version.status===0&&version.stdout.includes('cjfmt Version:')});
await fs.writeFile(work+'/invalid.cj','main( {\n');
const invalid=await run('invalid',['-f',work+'/invalid.cj','-o',work+'/invalid-out.cj','-c',work+'/format.toml']);
checks.push({label:'parse-error-control',pass:invalid.status===0&&(await fs.readFile(work+'/invalid-out.cj','utf8').catch(()=>null))==='main( {\n'});
const result={elf:fmt,sha256:createHash('sha256').update(await fs.readFile(fmt)).digest('hex'),commands,checks};
await fs.writeFile(work+'/results.json',JSON.stringify(result,null,2));console.log(JSON.stringify(checks));process.exit(checks.every(c=>c.pass)?0:1);
