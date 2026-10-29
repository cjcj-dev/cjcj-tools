#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const [binary,input,out]=process.argv.slice(2);
fs.mkdirSync(out,{recursive:true});
const assertions=[],commands=[];
function run(name,args){const p=spawnSync(binary,args,{encoding:'utf8',timeout:10000});commands.push({argv:[binary,...args],rc:p.status,signal:p.signal,error:p.error?.message});fs.writeFileSync(path.join(out,name+'.stdout'),p.stdout??'');fs.writeFileSync(path.join(out,name+'.stderr'),p.stderr??'');fs.writeFileSync(path.join(out,'commands.json'),JSON.stringify(commands,null,2));return p;}
function check(name,pass){assertions.push({name,executed:true,pass});fs.writeFileSync(path.join(out,'assertions.json'),JSON.stringify(assertions,null,2));if(!pass){console.error('ASSERTION FAILED: '+name);process.exit(1);}}
const help=run('independent-help',['--help']);check('independent CLI help remains available',help.status===0&&help.stdout.includes('Usage:'));
const p=run('analysis',['heap','-i',input,'--json']);check('heap parser and analysis executed',p.status===0);
const data=JSON.parse(p.stdout),byId=new Map(data.objects.map(x=>[x.id,x]));
check('independent shallow size and multi-reference graph',data.objects.length===4&&data.objects.every(x=>x.shallowSize===8)&&byId.get(4).references.length===2);
check('retained root includes exclusively dominated diamond',byId.get(1).retainedSize===32&&byId.get(2).retainedSize===8&&byId.get(3).retainedSize===8);
console.log('PASS retained probe');
