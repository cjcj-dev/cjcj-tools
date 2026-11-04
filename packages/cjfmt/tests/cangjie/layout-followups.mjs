#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const [fmt,cjc,work,filter='all']=process.argv.slice(2);
fs.mkdirSync(work,{recursive:true});
const commands=[],checks=[];
const save=()=>fs.writeFileSync(work+'/results.json',JSON.stringify({commands,checks},null,2));
function run(label,argv,expected=0){
 const started=new Date().toISOString(),p=spawnSync(argv[0],argv.slice(1),{cwd:work,encoding:'utf8',timeout:120000});
 fs.writeFileSync(work+'/'+label+'.stdout',p.stdout??'');fs.writeFileSync(work+'/'+label+'.stderr',p.stderr??'');
 commands.push({label,argv,started,ended:new Date().toISOString(),rc:p.status,signal:p.signal,error:p.error?.message??null});save();
 assert.equal(p.status,expected,label+' '+p.stderr);return p;
}
const cases=[
 {name:'fill-arguments',width:32,input:'func f(a:Int64,b:Int64,c:Int64,d:Int64):Int64{a+b+c+d}\nmain(){let n=f(10000,20000,30000,40000)\nprintln(n)}\n',output:'100000',pattern:/f\(10000, 20000,\n\s+30000, 40000\)/},
 {name:'exact-width-control',width:32,input:'func f(a:Int64,b:Int64,c:Int64):Int64{a+b+c}\nmain(){println(f(1000,2000,3000))}\n',output:'6000',pattern:/    println\(f\(1000, 2000, 3000\)\)/},
 {name:'suffix-budget',width:25,input:'main(){println((100+200+300+400))}\n',output:'1000'},
 {name:'assignment-choice',width:28,input:'main(){let veryLongName=1234567890\nprintln(veryLongName)}\n',output:'1234567890',pattern:/veryLongName =\n\s+1234567890/},
 {name:'tuple-generic-if',width:32,input:'func id<T>(x:T):T{x}\nmain(){let t=(10000,20000,30000)\nif(t[0]+t[1]+t[2]==60000){println(id<Int64>(t[0]+t[1]+t[2]))}}\n',output:'60000'},
 {name:'binary-priority',width:34,input:'main(){let a=100\nlet b=200\nif(a+200+b+100==600&&a+b==300){println(7)}}\n',output:'7'},
 {name:'trailing-comment',width:32,input:'main(){let n=100+200+300 // sum\nprintln(n)}\n',output:'600',pattern:/300 \/\/ sum\n/},
 {name:'list-comment',width:32,input:'func f(a:Int64,b:Int64):Int64{a+b}\nmain(){println(f(100, // first\n200))}\n',output:'300',pattern:/100, \/\/ first\n/},
 {name:'nested-comment',width:32,input:'main(){/* outer /* inner */ end */println(7)}\n',output:'7',pattern:/\/\* outer \/\* inner \*\/ end \*\//,unbounded:true},
 {name:'raw-interpolation',width:32,input:'main(){let raw=#"a  /*b*/ // c"#\nlet s="result ${"two  spaces ${3+4}"}"\nprintln(raw)\nprintln(s)}\n',output:'a  /*b*/ // c\nresult two  spaces 7',pattern:/two  spaces/,unbounded:true},
 {name:'multiline-string',width:32,input:'main(){let s="""\n  literal  . text\n${3+4}\n"""\nprintln(s)}\n',output:'  literal  . text\n7',unbounded:true},
 {name:'chain',width:32,input:'class A{func next():A{this}\nfunc value():Int64{7}}\nmain(){println(A().next().next().value())}\n',output:'7',pattern:/\.next\(\)\n\s+\.next\(\)/},
 {name:'wide-control',width:120,input:'main(){println(100+200+300)}\n',output:'600',expected:'main() {\n    println(100 + 200 + 300)\n}\n'},
];
for(const item of cases.filter(x=>filter==='all'||filter.split(',').includes(x.name))){
 try{
  const dir=path.join(work,item.name);fs.mkdirSync(dir,{recursive:true});const input=dir+'/input.cj',first=dir+'/first.cj',second=dir+'/second.cj',config=dir+'/format.toml';
  fs.writeFileSync(input,item.input);fs.writeFileSync(config,`indentWidth = 4\nlinelimitLength = ${item.width}\nmultipleLineMethodChainOverLineLength = true\n`);
  const formatted=run(item.name+'-format',[fmt,'-f',input,'-o',first,'-c',config]);
  assert.doesNotMatch(formatted.stdout,/original source retained/,'real layout passed sameProgram');
  const output=fs.readFileSync(first,'utf8');
  // The target checks execute after the public formatter has emitted its file.
  checks.push({label:item.name+'-target-reached',pass:true});save();
  if(item.pattern)assert.match(output,item.pattern,item.name+' layout target');
  if(item.expected)assert.equal(output,item.expected);
  if(!item.unbounded)for(const line of output.trimEnd().split('\n'))assert(line.length<=item.width,item.name+' width target '+JSON.stringify(line));
  run(item.name+'-again',[fmt,'-f',first,'-o',second,'-c',config]);assert.equal(fs.readFileSync(second,'utf8'),output,'idempotence');
  const exe=dir+'/program';run(item.name+'-compile',[cjc,first,'--set-runtime-rpath','-o',exe]);const result=run(item.name+'-run',[exe]);assert.equal(result.stdout.trimEnd(),item.output);
  checks.push({label:item.name,pass:true});
 }catch(error){checks.push({label:item.name,pass:false,error:error.stack});}
 save();
}
console.log(JSON.stringify(checks));process.exitCode=checks.every(x=>x.pass)?0:1;
