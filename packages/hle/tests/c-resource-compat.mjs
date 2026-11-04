#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const [prefix,sdk,work]=process.argv.slice(2);fs.mkdirSync(work,{recursive:true});
const commands=[],checks=[];
const save=()=>fs.writeFileSync(work+'/results.json',JSON.stringify({commands,checks},null,2));
function run(label,argv,expected=0){
 const env={...process.env};for(const k of ['LD_LIBRARY_PATH','LD_PRELOAD','LD_AUDIT','CANGJIE_HOME','CANGJIE_PATH'])delete env[k];
 const started=new Date().toISOString(),r=spawnSync(argv[0],argv.slice(1),{cwd:work,env,encoding:'utf8',timeout:120000});
 fs.writeFileSync(work+'/'+label+'.stdout',r.stdout??'');fs.writeFileSync(work+'/'+label+'.stderr',r.stderr??'');commands.push({label,argv,started,ended:new Date().toISOString(),rc:r.status,signal:r.signal,error:r.error?.message??null});save();assert.equal(r.status,expected,label+' '+r.stdout+' '+r.stderr);return r;
}
const hle=prefix+'/bin/hle',binding=prefix+'/share/hle/dtsparser/node_modules/.bin/cjbind';
const header=work+'/fixture.h';
fs.writeFileSync(header,'// generated comment control\n#define X16_MACRO 16\n#define X17_MACRO 17\nenum Color { Color_RED=0, Color_GREEN, Color_BLUE=5, Color_YELLOW };\nstatic const int fixed_value=9;\n// The generated declaration must keep this comment.\nint binding_answer(int input);\n');
fs.writeFileSync(work+'/fixture.c','#include "fixture.h"\nint binding_answer(int input){return input+Color_BLUE+Color_YELLOW+fixed_value;}\n');
for(const [label,extra]of [['default',[]],['explicit',['-b',binding]]]){
 try{
  const output=work+'/'+label;fs.mkdirSync(output,{recursive:true});
  run(label+'-generate',[hle,'-c','-i',header,'-o',output,'--module-name','fixture',...extra]);
  const generated=fs.readFileSync(output+'/fixture.cj','utf8');checks.push({label:label+'-generated-target-reached',pass:true});save();
  for(const pattern of [/public const X16_MACRO/,/public const X17_MACRO/,/Color_BLUE/,/Color_YELLOW/,/fixed_value/,/binding_answer/,/generated declaration must keep this comment/])assert.match(generated,pattern);
  if(label==='explicit')assert.equal(generated,fs.readFileSync(work+'/default/fixture.cj','utf8'),'explicit and installed default consume identical frozen cjbind');
  fs.writeFileSync(output+'/main.cj','package fixture\nmain(){let n=Int32(X16_MACRO+X17_MACRO)-Int32(Color_Color_BLUE)-Int32(Color_Color_YELLOW)+fixed_value-9\nunsafe{println(binding_answer(n))}}\n');
  run(label+'-c-compile',['cc','-c',work+'/fixture.c','-o',output+'/fixture.o']);
  run(label+'-cj-compile',[sdk+'/bin/cjc','-p',output,output+'/fixture.o','--set-runtime-rpath','-o',output+'/program']);
  const result=run(label+'-run',[output+'/program']);assert.equal(result.stdout.trim(),'42');checks.push({label,pass:true});
 }catch(e){checks.push({label,pass:false,error:e.stack});}save();
}
run('help-control',[hle,'--help']);
console.log(JSON.stringify(checks));process.exitCode=checks.every(x=>x.pass)?0:1;
