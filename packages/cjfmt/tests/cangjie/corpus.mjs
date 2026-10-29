#!/usr/bin/env zx
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const [fmt,input,work,config,...selected]=process.argv.slice(2);
if(!config)throw Error('usage: corpus.mjs installed-cjfmt fixed-input-directory work config');
const files=[];
async function walk(dir){for(const entry of await fs.readdir(dir,{withFileTypes:true})){const file=path.join(dir,entry.name);if(entry.isDirectory())await walk(file);else if(entry.isFile()&&file.endsWith('.cj'))files.push(file);}}
await walk(input);files.sort();await fs.mkdir(work,{recursive:true});
const excluded=files.filter(file=>selected.length&&!selected.includes(path.relative(input,file)));
const tested=files.filter(file=>!excluded.includes(file));
const records=[];
const hash=text=>createHash('sha256').update(text).digest('hex');
for(const file of tested){
 const relative=path.relative(input,file),out=path.join(work,'first',relative),twice=path.join(work,'second',relative);
 await fs.mkdir(path.dirname(out),{recursive:true});await fs.mkdir(path.dirname(twice),{recursive:true});
 const record={file,relative,input:hash(await fs.readFile(file)),commands:[],checks:[]};
 for(const [label,source,target] of [['first',file,out],['second',out,twice]]){
  const argv=[fmt,'-f',source,'-o',target,'-c',config];
  const p=spawnSync(argv[0],argv.slice(1),{encoding:'utf8',timeout:60000,maxBuffer:2**20});
  record.commands.push({label,argv,rc:p.status,signal:p.signal,error:p.error?.message,stdout:p.stdout,stderr:p.stderr});
  record.checks.push({label:label+'-rc',pass:p.status===0},{label:label+'-formatted',pass:!p.stdout?.includes('original source retained')});
  if(p.status!==0)break;
 }
 const first=await fs.readFile(out).catch(()=>null),second=await fs.readFile(twice).catch(()=>null);
 record.output=first&&hash(first);record.checks.push({label:'idempotence',pass:!!first&&!!second&&first.equals(second)});
 records.push(record);
 await fs.writeFile(path.join(work,'results.json'),JSON.stringify({input,files:tested.length,excluded,records},null,2));
}
const failed=records.filter(r=>r.checks.some(c=>!c.pass));
console.log(JSON.stringify({files:tested.length,failed:failed.map(r=>({file:r.relative,checks:r.checks.filter(c=>!c.pass),diagnostics:r.commands.map(c=>c.stdout+c.stderr).join('\n').slice(0,1200)}))},null,2));
process.exit(tested.length>0&&failed.length===0?0:1);
