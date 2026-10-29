#!/usr/bin/env zx
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const [fmt,cjc,work,products]=process.argv.slice(2);
await fs.mkdir(work,{recursive:true});await fs.mkdir(products,{recursive:true});
const commands=[],checks=[];
const env={...process.env,LD_LIBRARY_PATH:products+':'+(process.env.LD_LIBRARY_PATH??'')};
async function save(){await fs.writeFile(work+'/results.json',JSON.stringify({commands,checks},null,2));}
async function check(label,fn){try{await fn();checks.push({label,executed:true,pass:true});}catch(e){checks.push({label,executed:true,pass:false,error:e.message});}await save();}
async function run(label,argv){const p=spawnSync(argv[0],argv.slice(1),{cwd:work,env,encoding:'utf8',timeout:60000,maxBuffer:2**20});commands.push({label,argv,rc:p.status,signal:p.signal,error:p.error?.message});await fs.writeFile(work+'/'+label+'.log',(p.stdout??'')+(p.stderr??''));await check(label+'-rc',()=>assert.equal(p.status,0));return p;}
async function format(name,input,pattern){
 const source=path.join(work,name+'.cj'),first=path.join(work,name+'-first.cj'),second=path.join(work,name+'-second.cj');await fs.writeFile(source,input);
 const p=await run(name+'-format',[fmt,'-f',source,'-o',first]);
 await check(name+'-format-reached',()=>assert.doesNotMatch(p.stdout,/original source retained/));
 if(p.status!==0)return null;
 const output=await fs.readFile(first,'utf8');await check(name+'-content',()=>assert.match(output,pattern));
 await run(name+'-format-again',[fmt,'-f',first,'-o',second]);
 await check(name+'-idempotent',async()=>assert.equal(await fs.readFile(second,'utf8'),output));return first;
}
const macro=await format('macro-definition','macro package formattingMacros\nimport std.ast.*\npublic macro Pass(input:Tokens):Tokens{return input}\npublic macro Attr(attrs:Tokens,input:Tokens):Tokens{return input}\npublic macro Seven(input:Tokens):Tokens{return quote(7)}\n',/public macro Pass\(input: Tokens\): Tokens \{\n    return input/);
if(macro){
 const compiled=await run('macro-compile',[cjc,macro,'--compile-macro','--output-dir',products]);
 if(compiled.status===0){
  const consumer=await format('macro-consumer','import formattingMacros.*\n@Attr[3+4] func value(@Pass n:Int64):Int64{return n}\n@Attr[arbitrary tokens] func extra():Int64{return 7}\n@Attr[\n3+4\n] func multiline():Int64{return 7}\nmain(){let n=@Seven()\nprintln(value(n))}\n',/@Attr\[3 \+ 4\]\nfunc value\(@Pass n: Int64\): Int64 \{/);
  if(consumer)await check('arbitrary-macro-attributes-preserved',async()=>assert.match(await fs.readFile(consumer,'utf8'),/@Attr\[arbitrary tokens\]\nfunc extra/));
  if(consumer)await check('multiline-macro-attributes',async()=>assert.match(await fs.readFile(consumer,'utf8'),/@Attr\[\n    3 \+ 4\n\]\nfunc multiline/));
  if(consumer){const built=await run('consumer-compile',[cjc,consumer,'--import-path',products,'--set-runtime-rpath','-o',products+'/macro-program']);if(built.status===0){const p=await run('consumer-run',[products+'/macro-program']);await check('consumer-semantics',()=>assert.equal(p.stdout.trim(),'7'));}}
 }
}
console.log(JSON.stringify({checks:checks.length,failed:checks.filter(c=>!c.pass)},null,2));process.exit(checks.every(c=>c.pass)?0:1);
