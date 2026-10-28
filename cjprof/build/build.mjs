#!/usr/bin/env zx
// cjprof-only Cangjie producer; never invokes the legacy C++ producer.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const action = args.shift();
function option(name, fallback) { const i=args.indexOf(name); return i<0 ? fallback : args[i+1]; }
const build=path.resolve(option('--build-dir',path.join(root,'build','cangjie-output')));
const sdk=option('--sdk',process.env.CANGJIE_HOME);
function run(argv) {
  const env={...process.env,CANGJIE_HOME:sdk,
    LD_LIBRARY_PATH:path.join(sdk,'runtime/lib/linux_x86_64_cjnative')+':'+path.join(sdk,'tools/lib')};
  const p=spawnSync(argv[0],argv.slice(1),{cwd:root,stdio:'inherit',env});
  if (p.error) throw p.error;
  if (p.status!==0) process.exit(p.status??1);
}
if (action==='build') {
  if (!sdk || !path.isAbsolute(sdk)) throw Error('--sdk requires an absolute compiler SDK path');
  fs.mkdirSync(build,{recursive:true});
  const sources=fs.readdirSync(path.join(root,'cangjie')).filter(x=>x.endsWith('.cj')).sort().map(x=>path.join(root,'cangjie',x));
  const argv=[path.join(sdk,'bin','cjc'),...sources,'-latomic','-lstdc++','-o',path.join(build,'cjprof')];
  fs.writeFileSync(path.join(build,'command.json'),JSON.stringify({argv,sdk,root},null,2));
  run(argv);
  const sharedSources=sources.filter(x=>path.basename(x)!=='main.cj');
  const shared=[path.join(sdk,'bin','cjc'),...sharedSources,'-latomic','-lstdc++','--output-type=dylib','-o',path.join(build,'libcjprof-cangjie.so')];
  run(shared);
  const jdk=option('--jni-home',process.env.JAVA_HOME);
  const runtimeHeader=option('--runtime-header',null);
  if (!jdk || !runtimeHeader) throw Error('JNI build requires --jni-home JDK and --runtime-header matching-runtime/Cangjie.h');
  const bootstrap=[process.env.CC??'cc','-std=c11','-D_GNU_SOURCE','-shared','-fPIC','-Wall','-Wextra','-Werror',
    '-I'+path.join(jdk,'include'),'-I'+path.join(jdk,'include','linux'),'-include',runtimeHeader,
    path.join(root,'build','jni-bootstrap.c'),'-L'+build,'-Wl,--no-as-needed','-lcjprof-cangjie',
    '-L'+path.join(sdk,'runtime','lib','linux_x86_64_cjnative'),'-lcangjie-runtime','-ldl',
    '-Wl,-rpath,$ORIGIN','-o',path.join(build,'libcjprof-jni.so')];
  run(bootstrap);
  const lombok=option('--lombok-jar',process.env.CJPROF_LOMBOK_JAR);
  if (!lombok || !fs.existsSync(lombok)) throw Error('Java API build requires --lombok-jar selected-lombok.jar');
  const javaSources=[];
  function scanJava(dir) { for (const entry of fs.readdirSync(dir,{withFileTypes:true})) {
    const file=path.join(dir,entry.name);
    if(entry.isDirectory())scanJava(file);
    else if(entry.name.endsWith('.java')&&!entry.name.endsWith('Demo.java'))javaSources.push(file);
  }}
  scanJava(path.join(root,'bridge','jni','java'));
  const classes=path.join(build,'java-classes');fs.rmSync(classes,{recursive:true,force:true});fs.mkdirSync(classes,{recursive:true});
  const javac=[path.join(jdk,'bin','javac'),'--release','8','-cp',lombok,'-processorpath',lombok,'-d',classes,...javaSources];
  run(javac);
  run([path.join(jdk,'bin','jar'),'cf',path.join(build,'cjprof.jar'),'-C',classes,'.']);
  fs.cpSync(path.join(root,'static'),path.join(build,'config','static'),{recursive:true});
  fs.writeFileSync(path.join(build,'build-facts.json'),JSON.stringify({language:'Cangjie',sdk,sources,argv,shared,bootstrap,runtimeHeader,jdk,lombok,javaSources,javac},null,2));
} else if (action==='install') {
  const prefix=option('--prefix',null);
  if (!prefix || !path.isAbsolute(prefix)) throw Error('--prefix requires an absolute path');
  const facts=JSON.parse(fs.readFileSync(path.join(build,'build-facts.json')));
  fs.mkdirSync(path.join(prefix,'bin'),{recursive:true});
  fs.copyFileSync(path.join(build,'cjprof'),path.join(prefix,'bin','cjprof'));
  fs.chmodSync(path.join(prefix,'bin','cjprof'),0o755);
  fs.mkdirSync(path.join(prefix,'lib'),{recursive:true});
  for (const lib of ['libcjprof-jni.so','libcjprof-cangjie.so']) fs.copyFileSync(path.join(build,lib),path.join(prefix,'lib',lib));
  fs.mkdirSync(path.join(prefix,'share','java'),{recursive:true});
  fs.copyFileSync(path.join(build,'cjprof.jar'),path.join(prefix,'share','java','cjprof.jar'));
  fs.cpSync(path.join(build,'config','static'),path.join(prefix,'config','static'),{recursive:true});
  fs.writeFileSync(path.join(prefix,'build-facts.json'),JSON.stringify(facts,null,2));
} else { throw Error('usage: build.mjs build --sdk SDK --jni-home JDK --runtime-header Cangjie.h --lombok-jar lombok.jar [--build-dir DIR] | install --build-dir DIR --prefix DIR'); }
