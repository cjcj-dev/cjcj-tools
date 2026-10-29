#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {parseArgs} from 'node:util';
const {values:v}=parseArgs({options:{prefix:{type:'string'},work:{type:'string'}}});
assert(v.prefix&&v.work);const work=path.resolve(v.work),exe=path.resolve(v.prefix,'bin/cjlint');
fs.mkdirSync(work,{recursive:false});const commands=[],checks=[];
const env={...process.env};for(const k of ['CANGJIE_HOME','LD_LIBRARY_PATH','LD_PRELOAD','LD_AUDIT'])delete env[k];
const cases=[
 {name:'comment-same-line',source:'public let value = 1 // cjlint-ignore !G.DCL.02\n',count:0},
 {name:'string-is-not-comment',source:'public let value = "cjlint-ignore !G.DCL.02"\n',count:1},
 {name:'malformed-comment-control',source:'public let value = 1 // cjlint-ignorefoo !G.DCL.02\n',count:1},
 {name:'comment-region',source:'// cjlint-ignore -start !G.DCL.02\npublic let hidden = 1\n// cjlint-ignore -end\npublic let visible = 2\n',count:1},
 {name:'comment-rule-control',source:'public let value = 1 // cjlint-ignore !G.PKG.01\n',count:1},
 {name:'diagnostic-exclude',exclude:[{path:'main.cj',line:'1',column:'12'}],count:0},
 {name:'diagnostic-column-control',exclude:[{path:'main.cj',line:'1',column:'13'}],count:1},
 {name:'diagnostic-line-control',exclude:[{path:'main.cj',line:'2'}],count:1},
 {name:'file-exclude',args:['-e','main.cj'],count:0},
 {name:'file-reinclude',args:['-e','*.cj !main.cj'],count:1},
 {name:'default-cfg',cfg:'*.cj\n!main.cj\n',count:1},
 {name:'default-cfg-exclude',cfg:'main.cj\n',count:0},
 {name:'explicit-cfg',cfg:'main.cj\n',cfgName:'custom.cfg',args:['-e','custom.cfg'],count:0},
 {name:'parent-exclude-control',subdir:'nested',args:['-e','nested/ !nested/main.cj'],count:0},
 {name:'recursive-zero-components',args:['-e','**/main.cj'],count:0}
];
for(const c of cases){
 const root=path.join(work,c.name),src=path.join(root,'src');fs.mkdirSync(path.join(src,c.subdir??''),{recursive:true});
 fs.mkdirSync(path.join(root,'config'));fs.writeFileSync(path.join(root,'config/cjlint_rule_list.json'),' {"RuleList":["G.DCL.02"]} ');
 if(c.exclude)fs.writeFileSync(path.join(root,'config/exclude_lists.json'),JSON.stringify({'G.DCL.02':c.exclude}));
 if(c.cfg)fs.writeFileSync(path.join(src,c.cfgName??'cjlint_file_exclude.cfg'),c.cfg);
 fs.writeFileSync(path.join(src,c.subdir??'','main.cj'),c.source??'public let value = 1\n');
 const report=path.join(root,'report.json'),argv=[exe,'-f',src,'-c',root,'-o',report,...(c.args??[])];
 const r=spawnSync(exe,argv.slice(1),{cwd:work,env,encoding:'utf8',maxBuffer:1024*1024});
 fs.writeFileSync(path.join(root,'stdout'),r.stdout??'');fs.writeFileSync(path.join(root,'stderr'),r.stderr??'');
 commands.push({name:c.name,argv,cwd:work,rc:r.status,signal:r.signal,error:r.error?.message??null});
 fs.writeFileSync(path.join(work,'commands.json'),JSON.stringify(commands,null,2)+'\n');
 try{
   assert.equal(r.status,0,c.name);const findings=JSON.parse(fs.readFileSync(report,'utf8'));
   assert.equal(findings.length,c.count,c.name);
   checks.push({name:c.name,pass:true});
 }catch(e){checks.push({name:c.name,pass:false,error:e.message});throw e;}
 finally{fs.writeFileSync(path.join(work,'assertions.json'),JSON.stringify(checks,null,2)+'\n');}
}
console.log(JSON.stringify({commands:commands.length,passed:checks.filter(c=>c.pass).length}));
