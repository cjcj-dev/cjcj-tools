import fs from 'node:fs';
import path from 'node:path';
import {coffNames} from '../../build/native-host.mjs';

export function profileSources(root,windows) {
  const linuxOnly=new Set(['record.cj','dump.cj','elf.cj']);
  const sources=fs.readdirSync(path.join(root,'src')).filter(name=>name.endsWith('.cj')&&!(windows&&linuxOnly.has(name))).sort().map(name=>path.join(root,'src',name));
  if(windows)sources.push(path.join(root,'platform/windows/live.cj'));
  return sources;
}

export function windowsBootstrap({sdk,jdk,root,runtimeHeader,build,cc}) {
  const declarations=fs.readFileSync(path.join(root,'java/com/cjprof/jni/Cjprof.java'),'utf8');
  const required=Array.from(declarations.matchAll(/public static native [^;]+? (\w+)\(/g),m=>'Java_com_cjprof_jni_Cjprof_'+m[1]);
  const exported=new Set(coffNames(sdk,path.join(build,'libcjprof-cangjie.dll'),'exports'));
  if(!required.length||required.some(name=>!exported.has(name)))throw Error('Windows Cangjie DLL is missing required Java native methods: '+required.filter(name=>!exported.has(name)));
  const def=path.join(build,'cjprof-jni.def');
  fs.writeFileSync(def,'EXPORTS\n'+required.map(name=>name+'=libcjprof-cangjie.'+name).join('\n')+'\n');
  return [cc,'-std=c11','-shared','-Wall','-Wextra','-Werror',
    '-I'+path.join(jdk,'include'),'-I'+path.join(jdk,'include/win32'),'-include',runtimeHeader,
    path.join(root,'native/jni-bootstrap.c'),def,path.join(sdk,'runtime/lib/windows_x86_64_cjnative','libcangjie-runtime.dll'),'-o',path.join(build,'cjprof-jni.dll')];
}
