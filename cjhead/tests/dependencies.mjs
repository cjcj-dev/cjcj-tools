#!/usr/bin/env zx
import {$} from 'zx';
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
const here=path.dirname(fileURLToPath(import.meta.url));
const args=process.argv.slice(process.argv.findIndex(arg=>path.resolve(arg)===fileURLToPath(import.meta.url))+1);
const {values:v}=parseArgs({args,options:{binary:{type:'string'},cjc:{type:'string'},evidence:{type:'string'},only:{type:'string'}}});
if(!v.binary||!v.cjc||!v.evidence)throw Error('--binary --cjc --evidence required');
const evidence=path.resolve(v.evidence),fixture=path.join(here,'fixtures');await fs.mkdir(evidence,{recursive:true});
const rows=[];
const run=async(name,argv)=>{
 const p=await $({cwd:evidence,quiet:true,nothrow:true})`${argv}`;
 rows.push({name,argv,rc:p.exitCode,signal:p.signal??null});
 await fs.writeFile(path.join(evidence,name+'.stdout'),p.stdout);await fs.writeFile(path.join(evidence,name+'.stderr'),p.stderr);
 await fs.writeFile(path.join(evidence,'commands.json'),JSON.stringify(rows,null,2));return p;
};
const ok=p=>assert.equal(p.exitCode,0,p.stdout+p.stderr);
let failure=null;
try{
 if(!v.only||v.only==='imports'){
  ok(await run('dependency-build',[v.cjc,'-p',path.join(fixture,'imports-dep'),'--output-type=staticlib','-o',path.join(evidence,'libdependency.a')]));
  const out=path.join(evidence,'imports-output');await fs.mkdir(out);
  ok(await run('imports',[v.binary,'-i',path.join(fixture,'imports-use'),'-o',out,'--import-path',evidence,'--import-path',evidence]));
  const s=await fs.readFile(path.join(out,'api.cj.d'),'utf8');
  for(const word of ['import dependency.one','public import dependency.two','protected import dependency.three','internal import dependency.four','private import dependency.five','External as Renamed','func sum'])assert.ok(s.includes(word),'Missing '+word);
  const invariants=[];
  const check=(name,fn)=>{try{fn();invariants.push({name,pass:true});}catch(e){invariants.push({name,pass:false,error:e.message});}};
  check('R1-complete-multi-import',()=>{
   const lines=s.split('\n').filter(line=>line.startsWith('public import dependency.{'));
   assert.deepEqual(lines,['public import dependency.{External as Renamed, Contract}'],'complete multi-import including alias and closing delimiter');
  });
  check('R2-foreign-extension-members',()=>{
   const block=s.match(/^extend Renamed[^\n]*\{\n[\s\S]*?^}/m)?.[0];
   assert.equal(block,'extend Renamed <: LocalContract {\n    public func required(): Int64\n}','public implementation must reach its foreign extension block; unrelated/internal members must be absent there');
  });
  await fs.writeFile(path.join(evidence,'output-invariants.json'),JSON.stringify(invariants,null,2));
  const failures=invariants.filter(row=>!row.pass);
  assert.equal(failures.length,0,JSON.stringify(failures));
  assert.ok(!s.includes('notInherited'),'unrelated cross-package extension member must be hidden');assert.ok(!s.includes('333444'));
  assert.ok(!s.includes('internalRequirement'),'implementation of an internal cross-package interface must be hidden');
  assert.ok(!s.includes('InternalContract'),'internal interface must not leak in extension inheritance');
  console.log('PASS imports');
 }
 if(!v.only||v.only==='macro'){
  ok(await run('macro-definition',[v.cjc,'--compile-macro','-p',path.join(fixture,'macro-def')]));
  const definitionOut=path.join(evidence,'macro-definition-output');await fs.mkdir(definitionOut);
  ok(await run('macro-header',[v.binary,'-i',path.join(fixture,'macro-def'),'-o',definitionOut]));
  const definition=await fs.readFile(path.join(definitionOut,'def.cj.d'),'utf8');
  assert.ok(definition.includes('public macro Keep(input: Tokens): Tokens'));assert.ok(!definition.includes('{ input }'));
  const out=path.join(evidence,'macro-output');await fs.mkdir(out);
  ok(await run('macro-expansion',[v.binary,'-i',path.join(fixture,'macro-use'),'-o',out,'--macro-path',evidence,'--macro-path',evidence]));
  const s=await fs.readFile(path.join(out,'use.cj.d'),'utf8');assert.ok(s.includes('public func expanded()'),'macro-generated function reaches declaration output');assert.ok(!s.includes('838383'));
  assert.ok(s.includes('Expanded declaration documentation'),'macro declaration comment reaches output');
  console.log('PASS macro');
 }
 if(!v.only||v.only==='protected'){
  const hidden=path.join(fixture,'protected/root/hidden');
  ok(await run('protected-dependency',[v.cjc,'-p',hidden,'--output-type=staticlib','-o',path.join(evidence,'libexported.hidden.a')]));
  const out=path.join(evidence,'protected-output');await fs.mkdir(out);
  ok(await run('protected',[v.binary,'-i',path.join(fixture,'protected/root'),'-o',out,'--import-path',evidence]));
  const s=await fs.readFile(path.join(out,'hidden/api.cj.d'),'utf8');assert.ok(s.includes('class Selected'));assert.ok(!s.includes('class Unselected'));
  console.log('PASS protected');
 }
}catch(e){failure=e.stack;console.log('FAIL '+e.message);}
await fs.writeFile(path.join(evidence,'result.json'),JSON.stringify({failure,commands:rows.length},null,2));
if(failure)process.exitCode=1;
