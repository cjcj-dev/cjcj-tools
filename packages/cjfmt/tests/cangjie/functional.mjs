#!/usr/bin/env zx
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const [fmt,cjc,work,productDirectory=work]=process.argv.slice(2);
if(!fmt||!cjc||!work)throw Error('usage: functional.mjs installed-cjfmt cjc work');
await fs.mkdir(work,{recursive:true});
await fs.mkdir(productDirectory,{recursive:true});
const commands=[],checks=[];
async function record(){await fs.writeFile(path.join(work,'results.json'),JSON.stringify({commands,checks},null,2));}
async function run(label,argv,expected=0,env=process.env){
 const p=spawnSync(argv[0],argv.slice(1),{cwd:work,env,encoding:'utf8',maxBuffer:2**20,timeout:60000});
 await fs.writeFile(path.join(work,label+'.log'),(p.stdout??'')+(p.stderr??''));
 commands.push({label,argv,rc:p.status,signal:p.signal,error:p.error?.message});await record();
 await check(label+'-rc',()=>assert.equal(p.status,expected));return p;
}
async function check(label,fn){try{await fn();checks.push({label,executed:true,pass:true});}catch(e){checks.push({label,executed:true,pass:false,error:e.message});}await record();}
const defaultConfig='indentWidth = 4\nlinelimitLength = 120\nlineBreakType = "LF"\nallowMultiLineMethodChain = false\nmultipleLineMethodChainLevel = 5\nmultipleLineMethodChainOverLineLength = true\n';
await fs.writeFile(work+'/default.toml',defaultConfig);
await fs.writeFile(work+'/two.toml',defaultConfig.replace('indentWidth = 4','indentWidth = 2'));
await fs.writeFile(work+'/crlf.toml',defaultConfig.replace('"LF"','"CRLF"'));
await fs.writeFile(work+'/chains.toml',defaultConfig.replace('false','true').replace('Level = 5','Level = 2'));
await fs.writeFile(work+'/narrow.toml',defaultConfig.replace('Length = 120','Length = 25'));
await fs.writeFile(work+'/zero-indent.toml',defaultConfig.replace('indentWidth = 4','indentWidth = 0'));
await fs.writeFile(work+'/chain-threshold.toml',defaultConfig.replace('false','true'));
await fs.writeFile(work+'/chain-length.toml',defaultConfig.replace('Length = 120','Length = 25'));
await fs.writeFile(work+'/chain-disabled.toml',defaultConfig.replace('Length = 120','Length = 25').replace('OverLineLength = true','OverLineLength = false'));
const chainInput='class A{func next():A{return this}\nfunc value():Int64{return 7}}\nmain(){let a=A()\nprintln(a.next().next().value())}\n';
const cases=[
 {name:'enum-inline',input:'enum E{| A | B}\nmain(){println(7)}\n',expected:'enum E {\n    | A | B\n}\n\nmain() {\n    println(7)\n}\n',output:'7'},
 {name:'enum-multiline',input:'enum E{\n| A\n| B\n}\nmain(){println(7)}\n',pattern:/\| A\n    \| B/,output:'7'},
 {name:'builtin-annotation',input:'@When[os == "Linux"] func value():Int64{return 7}\nmain(){println(value())}\n',pattern:/@When\[os == "Linux"\]\nfunc value/,output:'7'},
 {name:'features',input:'features{}\nmain(){println(7)}\n',output:'7',pattern:/features \{/},
 {name:'primary-constructor',input:'class Primary{Primary(let value:Int64){}\nfunc get():Int64{return value}}\nmain(){println(Primary(7).get())}\n',output:'7',pattern:/Primary\(let value: Int64\)/},
 {name:'this-paren-type',input:'open class Box{public func self():This{return this}}\nmain(){let n:(Int64)=7\nprintln(n)}\n',output:'7',pattern:/self\(\): This/},
 {name:'type-pattern',input:'class Box{}\nmain(){let x:Object=Box()\nlet n=match(x){case _:Box=>7 case _=>0}\nprintln(n)}\n',output:'7',pattern:/case _: Box => 7/},
 {name:'boolean-match',input:'main(){let n=match{case false=>0 case _=>7}\nprintln(n)}\n',output:'7',pattern:/case _ => 7/},
 {name:'optional-chain',input:'class Box{let value:Int64=7}\nmain(){let box:?Box=Some(Box())\nprintln(box?.value??0)}\n',output:'7',pattern:/box\?\.value \?\? 0/},
 {name:'trailing-closure',input:'func apply(f:()->Int64):Int64{return f()}\nmain(){println(apply(){=>7})}\n',output:'7',pattern:/apply\(\) \{/},
 {name:'qualified-type',input:'import std.collection\nfunc count(values:collection.ArrayList<Int64>):Int64{return values.size}\nmain(){let a=collection.ArrayList<Int64>()\nfor(i in 0..7){a.add(i)}\nprintln(count(a))}\n',output:'7',pattern:/collection.ArrayList<Int64>/},
 {name:'macro-declaration',input:'import std.unittest.*\nimport std.unittest.testmacro.*\n@Test class Example{\n@TestCase func example():Unit{@Expect(3+4,7)}\n}\nmain(){println(7)}\n',output:'7',pattern:/@Test\nclass Example \{\n    @TestCase\n    func example\(\): Unit \{/},
 {name:'basic',input:'main(){println(7)}\n',expected:'main() {\n    println(7)\n}\n',output:'7'},
 {name:'comments',input:'// header\nmain(){\n/*comment\n*body\n*/\nlet x=7 // inline\nprintln(x)\n}\n',expected:'// header\nmain() {\n    /* comment\n     * body\n     */\n    let x = 7 // inline\n    println(x)\n}\n',output:'7'},
 {name:'two-space',input:'main(){\n/*comment\n*body\n*/\nprintln(7)\n}\n',config:'two.toml',expected:'main() {\n  /* comment\n   * body\n   */\n  println(7)\n}\n',output:'7'},
 {name:'crlf',input:'main(){println(7)}\n',config:'crlf.toml',expected:'main() {\r\n    println(7)\r\n}\r\n',output:'7'},
 {name:'region',input:'main() {\n    /*repeat\n*body\n*/\n    println(7)\n    /*repeat\n*body\n*/\n}\n',region:'6:8',expected:'main() {\n    /*repeat\n*body\n*/\n    println(7)\n    /* repeat\n     * body\n     */\n}\n',output:'7'},
 {name:'nested-region',input:'main() {\n    if (true) {\n        /*nested\n*body\n*/\n        println(7)\n    }\n}\n',region:'3:5',expected:'main() {\n    if (true) {\n        /* nested\n         * body\n         */\n        println(7)\n    }\n}\n',output:'7'},
 {name:'declarations',input:'func id<T>(x:T):T{return x}\nstruct Box{let n:Int64\ninit(n:Int64){this.n=n}\nfunc get():Int64{return n}}\nmain(){let b=Box(id<Int64>(7))\nprintln(b.get())}\n',output:'7',pattern:/func id<T>\(x: T\): T/},
 {name:'control',input:'main(){var n=0\nfor(i in 0..4){if(i%2==0){n+=i}else{n+=1}}\nwhile(n<7){n++}\nprintln(n)}\n',output:'7',pattern:/if \(i % 2 == 0\) \{/},
 {name:'literal',input:'main(){let s="a // b /* x */ ${1+2}"\nprintln(s)}\n',output:'a // b /* x */ 3',pattern:/"a \/\/ b \/\* x \*\/ \$\{1 \+ 2\}"/},
 {name:'nested-interpolation',input:'main(){let s="result ${"v=${3+4}"}"\nprintln(s)}\n',output:'result v=7',pattern:/\$\{3 \+ 4\}/},
 {name:'lambda',input:'main(){let f={x:Int64=>x+1}\nprintln(f(6))}\n',output:'7'},
 {name:'enum-match',input:'enum E{| A | B}\nmain(){let e=E.A\nlet n=match(e){case E.A=>7 case E.B=>9}\nprintln(n)}\n',output:'7'},
 {name:'array',input:'main(){let a=[\n1,\n2,\n4\n]\nprintln(a[0]+a[1]+a[2])}\n',output:'7',pattern:/\[\n        1,\n        2,\n        4\n    \]/},
 {name:'chains',input:'class A{func next():A{return this}\nfunc value():Int64{return 7}}\nmain(){let a=A()\nprintln(a.next().next().value())}\n',config:'chains.toml',output:'7',pattern:/a\n\s+\.next\(\)\n\s+\.next\(\)\n\s+\.value\(\)/},
 {name:'long-list',input:'func add(a:Int64,b:Int64,c:Int64):Int64{return a+b+c}\nmain(){println(add(1000000000,2000000000,3000000000))}\n',config:'narrow.toml',output:'6000000000',pattern:/add\(\n/},
 {name:'nested-comment',input:'main(){/* outer /* nested */ end */println(7)}\n',output:'7',pattern:/\/\* outer \/\* nested \*\/ end \*\//},
 {name:'bom',input:'\uFEFFmain(){println(7)}\n',expected:'\uFEFFmain() {\n    println(7)\n}\n',output:'7'},
 {name:'members',input:'interface Value{func get():Int64}\nclass Box <: Value{let n:Int64=7\npublic func get():Int64{return n}}\nmain(){println(Box().get())}\n',output:'7',pattern:/let n: Int64 = 7\n    public func get/},
 {name:'top-level',input:'let x=3\nlet y=4\nfunc sum():Int64{return x+y}\nmain(){println(sum())}\n',output:'7',pattern:/let x = 3\nlet y = 4\n\nfunc sum/},
 {name:'exceptions',input:'main(){try{throw Exception("expected")}catch(e:Exception){println(7)}finally{}}\n',output:'7',pattern:/catch \(e: Exception\) \{/},
 {name:'do-while',input:'main(){var n=0\ndo{n++}while(n<7)\nprintln(n)}\n',output:'7',pattern:/n\+\+/},
 {name:'tuple-pattern',input:'main(){let t=(3,4)\nlet n=match(t){case (a,b)=>a+b}\nprintln(n)}\n',output:'7'},
 {name:'optional',input:'main(){let x:?Int64=Some(7)\nif(let Some(n)<-x){println(n)}}\n',output:'7',pattern:/x: \?Int64/},
 {name:'raw-string',input:'main(){let s=#"a /* b */ // c"#\nprintln(s)}\n',output:'a /* b */ // c',pattern:/#"a \/\* b \*\/ \/\/ c"#/},
 {name:'multiline-string',input:'main(){let s="""\na // b\n"""\nprintln(s)}\n',output:'a // b'},
 {name:'collection',input:'import std.collection.*\nmain(){let a=ArrayList<Int64>()\na.add(3)\na.add(4)\nprintln(a[0]+a[1])}\n',output:'7',pattern:/import std.collection.\*\n\nmain/},
 {name:'unary',input:'main(){let b=false\nif(!b){println(-(-7))}}\n',output:'7',pattern:/if \(!b\)/},
 {name:'empty-comments',input:'/**/\nmain(){/* */println(7)}\n',output:'7',pattern:/\/\*\*\//},
 {name:'binary-wrap',input:'main(){let n=1000000000+2000000000+3000000000\nprintln(n)}\n',config:'narrow.toml',output:'6000000000',pattern:/\+\n\s+2000000000/},
 {name:'operator-line',input:'main(){let n=3\n+4\nprintln(n)}\n',output:'7',pattern:/3\n\s+\+ 4/},
 {name:'partial-comment-region',input:'main() {\n    /*nested\n*body\n*/\n    println(7)\n}\n',region:'3:3',expected:'main() {\n    /* nested\n     * body\n     */\n    println(7)\n}\n',output:'7'},
 {name:'multiline-lambda',input:'main(){let f={x:Int64=>\nlet y=x+1\ny}\nprintln(f(6))}\n',output:'7',pattern:/=>\n\s+let y = x \+ 1\n\s+y/},
 {name:'property',input:'class A{prop value:Int64{get(){return 7}}}\nmain(){println(A().value)}\n',output:'7',pattern:/prop value: Int64 \{\n\s+get\(\)/},
 {name:'range-step',input:'main(){var n=0\nfor(i in 0..7:2){n+=i}\nprintln(n-5)}\n',output:'7',pattern:/0\.\.7 : 2/},
 {name:'ambiguous-operators',input:'main(){var n=28\nn>>=2\nlet x:?Int64=None\nif(n>=7&&n<=7){println(x??(n>>0))}}\n',output:'7',pattern:/n >>= 2/},
 {name:'nested-generics',input:'import std.collection.*\nmain(){let a=ArrayList<ArrayList<Int64>>()\nlet b=ArrayList<Int64>()\nb.add(7)\na.add(b)\nprintln(a[0][0])}\n',output:'7',pattern:/ArrayList<ArrayList<Int64>>/},
 {name:'named-argument',input:'func value(n!:Int64=7):Int64{return n}\nmain(){println(value(n:7))}\n',output:'7',pattern:/n!: Int64 = 7/},
 {name:'blank-line',input:'main(){let n=7\n\n\nprintln(n)}\n',expected:'main() {\n    let n = 7\n\n    println(n)\n}\n',output:'7'},
 {name:'annotated-import',input:'import std.collection.*\n@When[os == "Windows"]\nimport std.unittest.*\nmain(){println(7)}\n',output:'7',pattern:/import std.collection.\*\n@When/},
 {name:'foreign-block',input:'foreign{func abs(n:Int32):Int32\nfunc labs(n:Int64):Int64}\nmain(){unsafe{println(abs(-7))}}\n',output:'7',pattern:/foreign \{\n\s+func abs/},
 {name:'chain-threshold',input:chainInput,config:'chain-threshold.toml',output:'7',pattern:/a\.next\(\)\.next\(\)\.value\(\)/},
 {name:'chain-length',input:chainInput,config:'chain-length.toml',output:'7',pattern:/a\n\s+\.next/},
 {name:'chain-disabled',input:chainInput,config:'chain-disabled.toml',output:'7',pattern:/a\.next\(\)\.next\(\)\.value\(\)/},
 {name:'zero-indent',input:'main(){println(7)}\n',config:'zero-indent.toml',expected:'main() {\nprintln(7)\n}\n',output:'7'},
 {name:'comment-gap',input:'// header\n\n\nmain(){// body\n\n\nprintln(7)}\n',expected:'// header\n\nmain() {\n    // body\n\n    println(7)\n}\n',output:'7'},
 {name:'binary-region',input:'main() {\nlet n=3+\n4\n    println(n)\n}\n',region:'3:3',expected:'main() {\n    let n = 3 + 4\n    println(n)\n}\n',output:'7'},
 {name:'arguments-region',input:'func sum(a:Int64,b:Int64):Int64{return a+b}\nmain() {\n    let n = sum(\n3,\n4\n)\n    println(n)\n}\n',region:'4:5',expected:'func sum(a:Int64,b:Int64):Int64{return a+b}\nmain() {\n    let n = sum(\n        3,\n        4\n)\n    println(n)\n}\n',output:'7'},
];
for(const item of cases){
 const src=path.join(work,item.name+'.cj'),first=path.join(work,item.name+'-first.cj'),second=path.join(work,item.name+'-second.cj');
 await fs.writeFile(src,item.input);
 const opts=['-c',path.join(work,item.config??'default.toml'),...(item.region?['-l',item.region]:[])];
 const formatted=await run(item.name+'-format',[fmt,'-f',src,'-o',first,...opts]);
 if(formatted.status!==0)continue;
 const out=await fs.readFile(first,'utf8');
 await check(item.name+'-format-reached',()=>assert.doesNotMatch(formatted.stdout,/original source retained/));
 await check(item.name+'-content',()=>{if(item.expected!==undefined)assert.equal(out,item.expected);if(item.pattern)assert.match(out,item.pattern);});
 await run(item.name+'-idempotence',[fmt,'-f',first,'-o',second,...opts]);
 await check(item.name+'-idempotent',async()=>assert.equal(await fs.readFile(second,'utf8'),out));
 const executable=path.join(productDirectory,item.name+'-program');
 const compiled=await run(item.name+'-compile',[cjc,first,'--set-runtime-rpath','-o',executable]);
 if(compiled.status===0){const p=await run(item.name+'-run',[executable]);await check(item.name+'-semantics',()=>assert.equal(p.stdout.trim(),item.output));}
}
await run('help',[fmt,'-h']);await run('version',[fmt,'-v']);
for(const [name,args] of [['no-input',[]],['unknown',['-x']],['missing-option-value',['-f']],['missing-file',['-f',work+'/absent.cj']],['wrong-extension',['-f',work+'/wrong.txt']],['bad-region',['-f',work+'/basic.cj','-l','3:1']],['region-overflow',['-f',work+'/basic.cj','-l','1:99999999999999999999999999']]])await run(name,[fmt,...args],1);
const malformed='main( {\n';await fs.writeFile(work+'/malformed.cj',malformed);
await run('parse-failure-preserved',[fmt,'-f',work+'/malformed.cj','-o',work+'/malformed-out.cj']);
await check('parse-failure-original',async()=>assert.equal(await fs.readFile(work+'/malformed-out.cj','utf8'),malformed));
const invalidUtf8=Buffer.from([0xff,0xfe,0x0a]);await fs.writeFile(work+'/invalid-utf8.cj',invalidUtf8);
await run('invalid-utf8',[fmt,'-f',work+'/invalid-utf8.cj','-o',work+'/invalid-utf8-out.cj']);
await check('invalid-utf8-preserved',async()=>assert.deepEqual(await fs.readFile(work+'/invalid-utf8-out.cj'),invalidUtf8));
for(const [name,value] of [['unclosed-string','main(){let s="unterminated\n'],['unclosed-comment','main(){/* unterminated\n'],['bad-expression','main(){let n=+}\n']]){
 await fs.writeFile(work+'/'+name+'.cj',value);await run(name,[fmt,'-f',work+'/'+name+'.cj','-o',work+'/'+name+'-out.cj']);
 await check(name+'-preserved',async()=>assert.equal(await fs.readFile(work+'/'+name+'-out.cj','utf8'),value));
}
await fs.mkdir(work+'/tree/nested',{recursive:true});await fs.writeFile(work+'/tree/nested/a.cj','main(){println(7)}\n');await fs.writeFile(work+'/tree/keep.txt','keep');
await run('directory',[fmt,'-d',work+'/tree','-o',work+'/tree-out','-c',work+'/two.toml']);
await check('directory-formatted',async()=>assert.equal(await fs.readFile(work+'/tree-out/nested/a.cj','utf8'),'main() {\n  println(7)\n}\n'));
await check('directory-non-cj',async()=>assert.equal(await fs.stat(work+'/tree-out/keep.txt').catch(()=>null),null));
await run('directory-in-place',[fmt,'-d',work+'/tree','-c',work+'/two.toml']);
await check('directory-in-place-content',async()=>assert.equal(await fs.readFile(work+'/tree/nested/a.cj','utf8'),'main() {\n  println(7)\n}\n'));
await run('output-extension',[fmt,'-f',work+'/basic.cj','-o',work+'/no-extension','-c',work+'/default.toml']);
await check('output-extension-file',async()=>assert.equal(await fs.readFile(work+'/no-extension.cj','utf8'),'main() {\n    println(7)\n}\n'));
await run('attached-options',[fmt,'-f'+work+'/basic.cj','-o'+work+'/attached.cj','-c'+work+'/two.toml','-l0:100']);
await check('attached-content',async()=>assert.equal(await fs.readFile(work+'/attached.cj','utf8'),'main() {\n  println(7)\n}\n'));
await run('help-immediate',[fmt,'unused','-hv']);
await run('end-options',[fmt,'--','-h'],1);
await run('stray-argument',[fmt,'-f',work+'/basic.cj','unused'],1);
await run('empty-stray-argument',[fmt,'-f',work+'/basic.cj',''],1);
await run('region-int32-overflow',[fmt,'-f',work+'/basic.cj','-l','1:2147483648'],1);
await run('empty-region',[fmt,'-f',work+'/basic.cj','-l',':'],1);
await run('zero-region',[fmt,'-f',work+'/basic.cj','-o',work+'/zero.cj','-l','0:0']);
await check('zero-region-unchanged',async()=>assert.equal(await fs.readFile(work+'/zero.cj','utf8'),'main(){println(7)}\n'));
await run('invalid-directory-path',[fmt,'-d',work+'/tree','-o',work+'/invalid?'],1);
await fs.mkdir(work+'/home/tools/config',{recursive:true});await fs.writeFile(work+'/home/tools/config/cangjie-format.toml',defaultConfig.replace('indentWidth = 4','indentWidth = 2'));
const fallbackEnv={...process.env,CANGJIE_HOME:work+'/home'};
for(const [name,config] of [['missing',work+'/absent.toml'],['unreadable',work+'/tree']]){
 await run('config-'+name,[fmt,'-f',work+'/basic.cj','-o',work+'/'+name+'.cj','-c',config],0,fallbackEnv);
 await check('config-'+name+'-fallback',async()=>assert.equal(await fs.readFile(work+'/'+name+'.cj','utf8'),'main() {\n  println(7)\n}\n'));
}
const builtinEnv={...process.env};delete builtinEnv.CANGJIE_HOME;
await run('builtins',[fmt,'-f',work+'/basic.cj','-o',work+'/builtin.cj'],0,builtinEnv);
await check('builtins-content',async()=>assert.equal(await fs.readFile(work+'/builtin.cj','utf8'),'main() {\n    println(7)\n}\n'));
await fs.writeFile(work+'/duplicate.toml',defaultConfig+'indentWidth = 2\nindentWidth = "bad"\n');
await run('duplicate-invalid-config',[fmt,'-f',work+'/basic.cj','-o',work+'/duplicate.cj','-c',work+'/duplicate.toml']);
await check('duplicate-invalid-default',async()=>assert.equal(await fs.readFile(work+'/duplicate.cj','utf8'),'main() {\n    println(7)\n}\n'));
await fs.symlink(work+'/tree',work+'/tree/nested/cycle');
await run('directory-output-subtree',[fmt,'-d',work+'/tree','-o',work+'/tree/generated','-c',work+'/two.toml','-l','1:1']);
await check('directory-output-subtree-content',async()=>assert.equal(await fs.readFile(work+'/tree/generated/nested/a.cj','utf8'),'main() {\n  println(7)\n}\n'));
await check('directory-no-output-recursion',async()=>assert.equal(await fs.stat(work+'/tree/generated/generated').catch(()=>null),null));
await fs.mkdir(work+'/external',{recursive:true});await fs.writeFile(work+'/external/linked.cj','main(){println(7)}\n');
await fs.symlink(work+'/external',work+'/tree/alias');await fs.symlink(work+'/external/linked.cj',work+'/tree/link.cj');
await run('directory-follow-links',[fmt,'-d',work+'/tree','-o',work+'/linked-output','-c',work+'/two.toml']);
for(const name of ['alias/linked.cj','link.cj'])await check('directory-follow-'+name,async()=>assert.equal(await fs.readFile(work+'/linked-output/'+name,'utf8'),'main() {\n  println(7)\n}\n'));
await fs.writeFile(work+'/order.cj','main(){println(7)}\n');
await run('output-before-file',[fmt,'-o',work+'/unused-output','-f',work+'/order.cj','-c',work+'/two.toml']);
await check('output-before-file-in-place',async()=>assert.equal(await fs.readFile(work+'/order.cj','utf8'),'main() {\n  println(7)\n}\n'));
await check('output-before-file-unused',async()=>assert.equal(await fs.stat(work+'/unused-output.cj').catch(()=>null),null));
await run('directory-priority',[fmt,'-d',work+'/tree','-f',work+'/absent.cj','-c',work+'/two.toml']);
await run('output-parent-missing',[fmt,'-f',work+'/basic.cj','-o',work+'/absent/output.cj'],1);
await run('directory-missing',[fmt,'-d',work+'/absent-directory'],1);
await fs.writeFile(work+'/invalid-options.toml','indentWidth = 9\nlinelimitLength = 0\nlineBreakType = 1\nallowMultiLineMethodChain = "true"\nmultipleLineMethodChainLevel = 11\nmultipleLineMethodChainOverLineLength = "false"\n');
await run('invalid-scalar-config',[fmt,'-f',work+'/basic.cj','-o',work+'/invalid-scalar.cj','-c',work+'/invalid-options.toml']);
await check('invalid-scalar-defaults',async()=>assert.equal(await fs.readFile(work+'/invalid-scalar.cj','utf8'),'main() {\n    println(7)\n}\n'));
console.log(JSON.stringify({checks:checks.length,failed:checks.filter(c=>!c.pass)},null,2));
process.exit(checks.every(c=>c.pass)?0:1);
