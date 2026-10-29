#!/usr/bin/env zx
// Normal HLE package graph. Node runs this adapter; cjc builds the tool body.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const source=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const [verb,...args]=process.argv.slice(2),options={};
for(let i=0;i<args.length;i++) {
  const key=args[i]==='-t'?'--build-type':args[i];
  if(!['--build-type','--target','--build-dir','--prefix','--dependencies'].includes(key)||!args[i+1])throw Error('HLE_BUILD_ARGUMENT '+args[i]);
  options[key]=args[++i];
}
const build=path.resolve(options['--build-dir']??path.join(source,'target'));
const target=options['--target']??'native',type=options['--build-type']??'release';
if(!['native','windows-x86_64'].includes(target)||!['debug','release'].includes(type))throw Error('HLE_BUILD_TARGET_TYPE');
const windows=process.platform==='win32'||target==='windows-x86_64',suffix=windows?'.exe':'';
const commands=[];
function run(argv) {
  const started=new Date().toISOString();console.log('HLE_BUILD_COMMAND '+JSON.stringify(argv));
  const r=spawnSync(argv[0],argv.slice(1),{stdio:'inherit',env:{...process.env,ZERO_AR_DATE:'1'}});
  commands.push({argv,cwd:process.cwd(),started,ended:new Date().toISOString(),rc:r.status,signal:r.signal,error:r.error?.message??null});
  fs.writeFileSync(path.join(build,'commands.json'),JSON.stringify(commands,null,2));
  if(r.error||r.signal||r.status!==0) {process.exitCode=r.status||1;throw Error('HLE_BUILD_COMMAND_FAILED '+JSON.stringify(commands.at(-1)));}
}
try {
 if(verb==='clean') {if(build===source||build===path.parse(build).root)throw Error('HLE_BUILD_DIRECTORY');fs.rmSync(build,{recursive:true,force:true});}
 else if(verb==='build') {
  const sdk=process.env.CANGJIE_HOME,stdx=process.env.CANGJIE_STDX_PATH;
  if(!sdk||!stdx)throw Error('CANGJIE_HOME and CANGJIE_STDX_PATH are required');
  if(target!=='native'&&process.platform!=='linux')throw Error('HLE_CROSS_HOST');
  fs.mkdirSync(path.join(build,'bin'),{recursive:true});fs.mkdirSync(path.join(build,'hle'),{recursive:true});
  const cjc=path.join(sdk,'bin','cjc'+(process.platform==='win32'?'.exe':''));
  const common=[cjc,'-j1','--trimpath='+source,...(type==='debug'?['-g']:[]),...(target!=='native'?['--target=x86_64-windows-gnu']:[]),'--import-path',build,'--import-path',path.join(build,'hle'),'--import-path',stdx];
  for(const pkg of ['dtsparser','tool','entry'])run([...common,'-O2','--strip-all','--no-sub-pkg','-p',path.join(source,'src',pkg),'--output-type=staticlib','--output-dir',path.join(build,'hle'),'-o','libhle.'+pkg+'.a']);
  run([...common,...(windows?['--link-options=--no-insert-timestamp']:process.platform==='linux'?['--link-options=-z noexecstack -z relro -z now -s -rpath=$ORIGIN/../lib']:['--link-options=-rpath @executable_path/../lib']),'-L',path.join(build,'hle'),'-lhle.dtsparser','-lhle.tool','-lhle.entry','-L',stdx,...['logger','log','encoding.json.stream','serialization.serialization','encoding.json','encoding.url'].map(x=>'-lstdx.'+x),'-p',path.join(source,'src'),'-O2','--output-dir',path.join(build,'bin'),'-o','main'+suffix]);
  fs.writeFileSync(path.join(build,'product.json'),JSON.stringify({target,suffix,sdk,stdx,executable:path.join(build,'bin','main'+suffix)},null,2));
 } else if(verb==='install') {
  const product=JSON.parse(fs.readFileSync(path.join(build,'product.json'),'utf8'));
  if(options['--prefix']) {
   const bin=path.resolve(options['--prefix']),prefix=path.dirname(bin);
   const inputFile=options['--dependencies']??process.env.CJCJ_HLE_DEPENDENCIES;
   if(!inputFile)throw Error('HLE_DEPENDENCIES_REQUIRED');
   const input=JSON.parse(fs.readFileSync(inputFile,'utf8'));
   const selected={};for(const key of ['node','modules','cjbind']) {
    if(!input[key]?.source||!input[key]?.version||!input[key]?.path)throw Error('HLE_DEPENDENCY_SOURCE '+key);
    selected[key]=path.resolve(path.dirname(inputFile),input[key].path);
   }
   const platform=product.suffix?'windows_x86_64':(process.platform==='darwin'?'darwin_':'linux_')+(process.arch==='arm64'?'aarch64':'x86_64');
   if(input.platform!==platform)throw Error('HLE_DEPENDENCIES_PLATFORM');
   const parser=path.join(source,'src/dtsparser'),deps=JSON.parse(fs.readFileSync(path.join(parser,'package.json'),'utf8')).dependencies;
   for(const [name,wanted]of Object.entries(deps)){
    const actual=JSON.parse(fs.readFileSync(path.join(selected.modules,name,'package.json'),'utf8'));
    if(actual.name!==name||actual.version!==wanted.replace(/^npm:[^@]+@/,''))throw Error('HLE_DEPENDENCY_VERSION '+name);
   }
   fs.mkdirSync(bin,{recursive:true});
   fs.copyFileSync(product.executable,path.join(bin,'hle'+product.suffix));fs.chmodSync(path.join(bin,'hle'+product.suffix),0o755);
   const destination=path.join(prefix,'share/hle/dtsparser');fs.mkdirSync(destination,{recursive:true});
   for(const name of fs.readdirSync(parser))if(!name.endsWith('.cj')&&name!=='node_modules')fs.cpSync(path.join(parser,name),path.join(destination,name),{recursive:true});
   fs.cpSync(selected.modules,path.join(destination,'node_modules'),{recursive:true,filter:p=>path.basename(p)!=='.bin'});
   fs.mkdirSync(path.join(destination,'node_modules/.bin'),{recursive:true});
   for(const [from,to]of [[selected.node,path.join(bin,'node'+product.suffix)],[selected.cjbind,path.join(destination,'node_modules/.bin/cjbind'+product.suffix)]]){fs.copyFileSync(from,to);fs.chmodSync(to,0o755);}
   const tuple=platform+'_cjnative';fs.cpSync(path.join(product.sdk,'runtime/lib',tuple),path.join(prefix,product.suffix?'bin':'lib'),{recursive:true});
   fs.writeFileSync(path.join(prefix,'share/hle/dependencies.json'),JSON.stringify(input,null,2));
  }
  else fs.accessSync(product.executable);
 } else throw Error('Usage: build.mjs build|install|clean [--build-dir path] [--prefix path] [-t release|debug] [--target native|windows-x86_64]');
} catch(error) {console.error(error.stack);process.exitCode ||=1;}
