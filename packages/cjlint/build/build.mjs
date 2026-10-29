#!/usr/bin/env zx
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const source=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const {positionals,values:v}=parseArgs({allowPositionals:true,options:{sdk:{type:'string'},'analysis-sdk':{type:'string'},'frontend-source':{type:'string'},'frontend-artifacts':{type:'string'},
  'frontend-ref':{type:'string'},'frontend-runtime-object':{type:'string'},'llvm-shim':{type:'string'},'llvm-library':{type:'string'},
  'build-dir':{type:'string'},prefix:{type:'string'},jobs:{type:'string',default:'4'}}});
const action=positionals[0],build=path.resolve(v['build-dir']??path.join(source,'build/cangjie-build'));
if(!['build','install'].includes(action))throw Error('Usage: build.mjs build --sdk <host-sdk> --frontend-source <fixed-cjcj-source> --frontend-ref <sha> --build-dir <dir> [--jobs N] | install --build-dir <dir> --prefix <dir>');
fs.mkdirSync(build,{recursive:true});
const evidence=path.join(build,'commands.json');
const commands=fs.existsSync(evidence)?JSON.parse(fs.readFileSync(evidence,'utf8')):[];
function run(name,argv,options={}) {
  const log=path.join(build,`${commands.length}-${name}`),out=fs.openSync(log+'.stdout','w'),err=fs.openSync(log+'.stderr','w');
  const begin=new Date().toISOString();
  const r=spawnSync(argv[0],argv.slice(1),{cwd:build,env:process.env,stdio:['ignore',out,err],...options});
  fs.closeSync(out);fs.closeSync(err);
  commands.push({name,argv,cwd:options.cwd??build,start:begin,end:new Date().toISOString(),rc:r.status,signal:r.signal,error:r.error?.message??null});
  fs.writeFileSync(evidence,JSON.stringify(commands,null,2)+'\n');
  console.log(`${name} rc=${r.status} signal=${r.signal}`);
  if(r.status!==0)throw Error(`${name} failed; see ${log}.stderr`);
}
const hash=f=>createHash('sha256').update(fs.readFileSync(f)).digest('hex');
try {
if(action==='build') {
  for(const key of ['sdk','frontend-source','frontend-ref','frontend-artifacts','frontend-runtime-object','llvm-shim','llvm-library'])if(!v[key])throw Error(`--${key} is required for the full frontend`);
  if(!/^[0-9a-f]{40}$/.test(v['frontend-ref']))throw Error('frontend-ref must be a full source commit');
  if(!/^[1-9][0-9]*$/.test(v.jobs))throw Error('jobs must be positive');
  const sdk=path.resolve(v.sdk),frontend=path.resolve(v['frontend-source']);
  const project=path.join(build,'project');
  fs.mkdirSync(project,{recursive:true});
  fs.cpSync(path.join(source,'src'),path.join(project,'src'),{recursive:true});
  const configObject=path.resolve(v['frontend-runtime-object']);
  const llvmShim=path.resolve(v['llvm-shim']),llvmLibrary=path.resolve(v['llvm-library']);
  for(const file of [configObject,llvmShim,llvmLibrary])if(!fs.statSync(file).isFile())throw Error('Missing frontend infrastructure input: '+file);
  const quote=x=>JSON.stringify(x);
  const artifacts=path.resolve(v['frontend-artifacts']);
  const directories=['basic','utils','lex','option','ast','parse','flatbuffers','conditional_compilation','modules',
    'macro_pkg','meta_transformation','mangle','sema','chir','codegen','incremental_compilation','frontend'];
  const manifest=fs.readFileSync(path.join(source,'cjpm.toml.in'),'utf8')
    .replace('@LINK@',quote([configObject,llvmShim,llvmLibrary,'-lstdc++'].join(' ')))
    .replace('@FRONTEND@',JSON.stringify(directories.map(p=>path.join(artifacts,p+'@cjcj'))));
  fs.writeFileSync(path.join(project,'cjpm.toml'),manifest);
  const cjc=path.join(sdk,'bin/cjc'),cjpm=path.join(sdk,'tools/bin/cjpm');
  const env={...process.env,CANGJIE_HOME:sdk,PATH:path.join(sdk,'bin')+path.delimiter+process.env.PATH,
    LD_LIBRARY_PATH:[path.join(sdk,'runtime/lib/linux_x86_64_cjnative'),path.join(sdk,'lib/linux_x86_64_cjnative')].join(path.delimiter)};
  delete env.LD_PRELOAD;delete env.LD_AUDIT;
  // CJPM derives the real sema subpackage link closure from the supplied CJO
  // metadata, exactly as the normal shared frontend producer's consumer does.
  run('cangjie-build',[cjpm,'build','--target-dir',path.join(build,'target'),'-j',v.jobs],{cwd:project,env});
  const candidates=['target/release/bin/cjlint','target/release/bin/main'].map(p=>path.join(build,p));
  const executable=candidates.find(p=>fs.existsSync(p));
  if(!executable)throw Error('Normal cjpm build did not produce cjlint executable');
  run('relocatable-loader-path',['patchelf','--set-rpath','$ORIGIN/../lib',executable]);
  const metadata={tool:'cjlint',language:'Cangjie',reference:'271b2f4c20be309205eca5e58bb09ffa24727a64',
    frontend:{ref:v['frontend-ref'],source:frontend,artifacts:v['frontend-artifacts'],runtimeObject:configObject,llvmShim,llvmLibrary},host:{sdk,compiler:cjc,sha256:hash(cjc)},
    executable,sha256:hash(executable),qualification:'host development; complete rule and target-runtime qualification pending'};
  if(v['analysis-sdk'])metadata.analysis={sdk:path.resolve(v['analysis-sdk']),scope:'explicit analysis modules; separate from host execution SDK'};
  fs.writeFileSync(path.join(build,'product.json'),JSON.stringify(metadata,null,2)+'\n');
} else {
  if(!v.prefix)throw Error('install requires --prefix');
  const metadata=JSON.parse(fs.readFileSync(path.join(build,'product.json'),'utf8'));
  if(hash(metadata.executable)!==metadata.sha256)throw Error('Build product changed before installation');
  const analysisSdk=v['analysis-sdk']?path.resolve(v['analysis-sdk']):metadata.analysis?.sdk;
  if(!analysisSdk)throw Error('install requires --analysis-sdk or a build with an explicit analysis SDK; host modules are not an implicit target');
  const analysisModules=path.join(analysisSdk,'modules');
  if(!fs.statSync(analysisModules).isDirectory())throw Error('Missing analysis SDK modules: '+analysisModules);
  metadata.analysis={sdk:analysisSdk,scope:'analysis module input; host runtime remains the recorded host SDK runtime'};
  const prefix=path.resolve(v.prefix);
  fs.mkdirSync(path.join(prefix,'bin'),{recursive:true});fs.mkdirSync(path.join(prefix,'lib'),{recursive:true});
  fs.copyFileSync(metadata.executable,path.join(prefix,'bin/cjlint'));
  fs.chmodSync(path.join(prefix,'bin/cjlint'),0o755);
  fs.cpSync(path.join(source,'config'),path.join(prefix,'config'),{recursive:true});
  // Carry the actual host runtime dependencies; do not mix a target runtime into
  // a host build or copy the old libcjlint/libcangjie-lsp libraries.
  const lddEnv={...process.env,LD_LIBRARY_PATH:[path.join(metadata.host.sdk,'runtime/lib/linux_x86_64_cjnative'),
    path.join(metadata.host.sdk,'lib/linux_x86_64_cjnative'),path.dirname(metadata.frontend.llvmLibrary)].join(path.delimiter)};
  delete lddEnv.LD_PRELOAD;delete lddEnv.LD_AUDIT;
  const ldd=spawnSync('ldd',[metadata.executable],{encoding:'utf8',env:lddEnv});
  fs.writeFileSync(path.join(build,'install-ldd.stdout'),ldd.stdout??'');
  if(ldd.status!==0||(ldd.stdout??'').includes('not found'))throw Error('Cannot determine installed host runtime dependencies');
  for(const line of (ldd.stdout??'').split('\n')) {
    const match=line.match(/^\s*(\S+)\s+=>\s+(\/\S+)/);
    if(!match)continue;
    const [,name,file]=match;
    if(name.includes('cjlint')||name.includes('cangjie-lsp'))throw Error('Old C++ lint dependency is forbidden');
    if(file.startsWith(metadata.host.sdk+'/')||fs.realpathSync(file)===fs.realpathSync(metadata.frontend.llvmLibrary))fs.copyFileSync(fs.realpathSync(file),path.join(prefix,'lib',name));
  }
  fs.cpSync(analysisModules,path.join(prefix,'modules'),{recursive:true});
  const runtimeDirectory=path.join(prefix,'runtime/lib/linux_x86_64_cjnative');fs.mkdirSync(runtimeDirectory,{recursive:true});
  const runtimeLink=path.join(runtimeDirectory,'libcangjie-runtime.so');
  if(!fs.existsSync(runtimeLink))fs.symlinkSync('../../../lib/libcangjie-runtime.so',runtimeLink);
  fs.writeFileSync(path.join(prefix,'cjlint-build.json'),JSON.stringify(metadata,null,2)+'\n');
  console.log(`installed ${prefix}`);
}
} finally {
  if(process.platform==='linux'&&fs.existsSync('/proc/self/cgroup')) {
    const group=fs.readFileSync('/proc/self/cgroup','utf8').trim().split('::').at(-1);
    const resource={group,at:new Date().toISOString()};
    for(const key of ['cpu.max','cpuset.cpus.effective','memory.max','memory.peak','memory.events','memory.swap.max','memory.swap.current']) {
      const file='/sys/fs/cgroup'+group+'/'+key;
      if(fs.existsSync(file))resource[key]=fs.readFileSync(file,'utf8').trim();
    }
    fs.writeFileSync(path.join(build,`resources-${action}-${commands.length}-${Date.now()}.json`),JSON.stringify(resource,null,2)+'\n');
  }
}
