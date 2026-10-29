#!/usr/bin/env zx
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {parseArgs} from 'node:util';
import {createHash} from 'node:crypto';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const {positionals,values}=parseArgs({allowPositionals:true,options:{sdk:{type:'string'},cjpm:{type:'string'},'frontend-cjo':{type:'string'},'frontend-lib':{type:'string'},'frontend-native':{type:'string'},'frontend-ref':{type:'string'},'source-ref':{type:'string'},'build-dir':{type:'string'},jobs:{type:'string',default:'4'},'build-type':{type:'string',default:'release'},target:{type:'string',default:'x86_64-unknown-linux-gnu'},coverage:{type:'boolean'},output:{type:'string'},prefix:{type:'string'}}});
const build=path.resolve(values['build-dir']||path.join(root,'build-cangjie'));
const command=positionals[0];
// CJPM tracks staged dependency files. Leave unchanged inputs untouched so a
// normal repeated build can reuse its graph; changed bytes still invalidate it.
async function writeChanged(destination, bytes) {
 const previous=await fs.readFile(destination).catch(error=>{if(error.code==='ENOENT')return null;throw error;});
 if(previous?.equals(bytes))return;
 await fs.writeFile(destination,bytes);
}
async function stageFile(source,destination){await writeChanged(destination,await fs.readFile(source));}

if(command==='build'){
 if(!values.sdk||!values['frontend-cjo']||!values['frontend-lib'])throw Error('build requires --sdk, --frontend-cjo and --frontend-lib from one fixed frontend closure');
 if(!['debug','release'].includes(values['build-type']))throw Error('invalid --build-type');
 if(!/^[a-zA-Z0-9_-]+$/.test(values.target))throw Error('invalid --target');
 if(!/^[1-9][0-9]*$/.test(values.jobs))throw Error('invalid --jobs');
 for(const option of ['frontend-ref','source-ref'])if(values[option]&&!/^[0-9a-f]{40}$/.test(values[option]))throw Error('invalid --'+option);
 const sdk=path.resolve(values.sdk),cjo=path.resolve(values['frontend-cjo']),lib=path.resolve(values['frontend-lib']);
 const cjpm=values.cjpm||path.join(sdk,'tools/bin/cjpm');
 const workspace=path.join(build,'workspace');await fs.mkdir(path.join(workspace,'src'),{recursive:true});
 const sources=(await fs.readdir(path.join(root,'src'))).filter(name=>name.endsWith('.cj'));
 for(const name of sources)await stageFile(path.join(root,'src',name),path.join(workspace,'src',name));
 for(const name of await fs.readdir(path.join(workspace,'src')))if(name.endsWith('.cj')&&!sources.includes(name))await fs.unlink(path.join(workspace,'src',name));
 const archives=[];
 const packageOptions=[];
 // Public package archives, with the producer's actual names. No frontend sources
 // are built or installed by this tool's build entry.
 for(const pkg of ['parse','option','ast','lex','utils','basic']){
  const choices=[`libcjcj_${pkg}.a`,`lib${pkg}.a`,`lib${pkg}@cjcj.a`];
  let archive;
  for(const name of choices)for(const candidate of [path.join(lib,name),path.join(lib,pkg+'@cjcj',name)])if(!archive&&await fs.stat(candidate).catch(()=>null))archive=candidate;
  if(!archive)throw Error(`missing frontend archive for cjcj.${pkg} in ${lib}`);
  archives.push(archive);
  let cjoFile;
  for(const candidate of [path.join(cjo,pkg+'@cjcj.cjo'),path.join(cjo,pkg+'@cjcj',pkg+'@cjcj.cjo'),path.join(cjo,'cjcj',pkg+'@cjcj.cjo')])if(await fs.stat(candidate).catch(()=>null)){cjoFile=candidate;break;}
  if(!cjoFile)throw Error('missing CJO for cjcj::'+pkg);
  const binaryDir=path.join(workspace,'frontend-binaries',pkg+'@cjcj');await fs.mkdir(binaryDir,{recursive:true});
  const stagedCjo=path.join(binaryDir,pkg+'@cjcj.cjo');
  await stageFile(cjoFile,stagedCjo);await stageFile(archive,path.join(binaryDir,path.basename(archive)));
  const library=path.basename(archive).replace(/^lib/,'').replace(/\.a$/,'');
  packageOptions.push(JSON.stringify(library)+' = '+JSON.stringify(stagedCjo));
 }
 let native='';
 if(values['frontend-native']){
  const input=path.resolve(values['frontend-native']);const dir=path.join(workspace,'frontend-native');await fs.mkdir(dir,{recursive:true});
  native=path.join(dir,path.basename(input));await stageFile(input,native);
 }
 const manifest=(await fs.readFile(path.join(root,'build/cjpm.toml.in'),'utf8'))
  .replace('@TARGET@',values.target)
  .replace('@COMPILE@',JSON.stringify('--set-runtime-rpath'))
  .replace('@LINK@',JSON.stringify(native))
  .replace('@PACKAGES@',packageOptions.join('\n'));
 await writeChanged(path.join(workspace,'cjpm.toml'),Buffer.from(manifest));
 await writeChanged(path.join(workspace,'cangjie-repo.toml'),Buffer.from('[repository.cache]\npath = \"./cache\"\n'));
 const env={...process.env,CANGJIE_HOME:sdk,CJPM_CONFIG:path.join(workspace,'cache'),PATH:path.join(sdk,'bin')+path.delimiter+process.env.PATH,LD_LIBRARY_PATH:[path.join(sdk,'runtime/lib/linux_x86_64_cjnative'),path.join(sdk,'tools/lib'),path.join(sdk,'third_party/llvm/lib')].join(path.delimiter)};
 const args=['build','--target-dir',path.join(build,'target'),'-j',values.jobs,'-V'];
 if(values['build-type']==='debug')args.push('-g');
 if(values.coverage)args.push('--coverage');
 if(values.target!=='x86_64-unknown-linux-gnu')args.push('--target',values.target);
 const log=await fs.open(path.join(build,'cjfmt.log'),'w');
 const child=spawn(cjpm,args,{cwd:workspace,env,stdio:['ignore',log.fd,log.fd]});
 const result=await new Promise(resolve=>{child.once('error',error=>resolve({rc:null,signal:null,error:error.message}));child.once('close',(rc,signal)=>resolve({rc,signal}));});
 await log.close();await fs.writeFile(path.join(build,'commands.json'),JSON.stringify([{argv:[cjpm,...args],cwd:workspace,...result}],null,2));
 if(result.rc!==0){process.stderr.write(await fs.readFile(path.join(build,'cjfmt.log'),'utf8'));process.exit(result.rc??1);}
 // CJPM's executable target is named main; the installed CLI is cjfmt.
 const output=path.resolve(values.output||path.join(build,'cjfmt'));await fs.mkdir(path.dirname(output),{recursive:true});
 await fs.copyFile(path.join(build,'target/'+(values.target==='x86_64-unknown-linux-gnu'?'':values.target+'/')+values['build-type']+'/bin/main'+(values.target.includes('windows')?'.exe':'')),output);
 const sha256=createHash('sha256').update(await fs.readFile(output)).digest('hex');
 await fs.writeFile(path.join(build,'inputs.json'),JSON.stringify({sdk,cjo,archives,native:values['frontend-native']??null,frontendRef:values['frontend-ref']??null,source:root,sourceRef:values['source-ref']??null,language:'Cangjie',output,buildType:values['build-type'],target:values.target,coverage:!!values.coverage,sha256},null,2));
}else if(command==='install'){
 if(!values.prefix)throw Error('install requires --prefix');
 const prefix=path.resolve(values.prefix);await fs.mkdir(path.join(prefix,'bin'),{recursive:true});await fs.mkdir(path.join(prefix,'config'),{recursive:true});
 await fs.copyFile(path.join(build,'cjfmt'),path.join(prefix,'bin/cjfmt'));await fs.chmod(path.join(prefix,'bin/cjfmt'),0o755);
 await fs.copyFile(path.join(root,'config/cangjie-format.toml'),path.join(prefix,'config/cangjie-format.toml'));
 await fs.copyFile(path.join(build,'inputs.json'),path.join(prefix,'cjfmt-build.json'));
}else throw Error('usage: cangjie.mjs build --sdk SDK --frontend-cjo CJO --frontend-lib LIB --build-dir BUILD | install --build-dir BUILD --prefix PREFIX');
