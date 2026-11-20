// Host tools are built with the selected native SDK. Keep target selection
// separate from the machine that happens to drive a cross build of cjfmt.
import fs from 'node:fs';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

export const windows = process.platform === 'win32';
export const hostTriple = windows ? 'x86_64-w64-mingw32' : 'x86_64-unknown-linux-gnu';
export const tuple = windows ? 'windows_x86_64_cjnative' : 'linux_x86_64_cjnative';
export const executable = file => file + (windows ? '.exe' : '');
export const dllRoots = sdk => [path.join(sdk,'runtime/lib',tuple), path.join(sdk,'lib',tuple),
  path.join(sdk,'third_party/llvm/bin'), path.join(sdk,'tools/lib'), path.join(sdk,'bin')];

export function buildEnv(sdk, cjpmSdk=sdk) {
  const env={...process.env,CANGJIE_HOME:sdk};
  const key=Object.keys(env).find(key=>key.toUpperCase()==='PATH') ?? 'PATH';
  env[key]=[path.join(sdk,'bin'),...(windows?[...dllRoots(cjpmSdk),...dllRoots(sdk)]:[]),env[key]].join(path.delimiter);
  return env;
}

export function frontendCxxLibraries() {
  if (!windows) return ['-lstdc++'];
  if (!process.env.MINGW_PATH) throw Error('MINGW_PATH is required for the selected Windows C++ runtime');
  return ['-L'+path.join(process.env.MINGW_PATH,'x86_64-w64-mingw32/lib'),'-lc++','-lunwind'];
}

// CJPM passes compile-option tokens as cjc argv. Keep the response reference
// attached to the singular driver option so only the native linker opens it.
export function nativePackageOptions(workspace, args, compile = '', response = windows) {
  if (!response || !args.length) {
    return 'compile-option = '+JSON.stringify(compile)+'\nlink-option = '+JSON.stringify(args.join(' '));
  }
  const lines=args.map(arg=>{
    if (/[\0\r\n]/.test(arg)) throw Error('invalid native linker argument');
    const value=windows ? arg.replaceAll('\\','/') : arg.replaceAll('\\','\\\\');
    return '"'+value.replaceAll('"','\\"')+'"';
  });
  const body=lines.join('\n')+'\n';
  // CJPM's incremental command must change when the ordered linker inputs do.
  const name='native-link-'+createHash('sha256').update(body).digest('hex')+'.rsp';
  fs.writeFileSync(path.join(workspace,name),body);
  // Quote the whole token for CJPM: an unquoted '=' becomes two argv entries.
  const option='"--link-option=@'+name+'"';
  return 'compile-option = '+JSON.stringify([compile,option].filter(Boolean).join(' '));
}

export function coffNames(sdk, image, kind) {
  const reader=path.join(process.env.CJCJ_NATIVE_LLVM_BIN || path.join(sdk,'third_party/llvm/bin'),executable('llvm-readobj'));
  const p=spawnSync(reader,['--coff-'+kind,image],{encoding:'utf8',maxBuffer:32*1024*1024});
  if (p.error || p.status!==0 || !/^Format: COFF-x86-64\s*$/m.test(p.stdout)) throw Error('cannot read x64 PE '+image+': '+(p.error??p.stderr));
  const blocks=kind==='exports'?/^Export \{([\s\S]*?)^\}/gm:/^(?:Delay)?Import \{([\s\S]*?)^\}/gm;
  return Array.from(p.stdout.matchAll(blocks),m=>{
    const name=m[1].match(/^\s*Name: (.+?)\s*$/m)?.[1];
    if (!name && kind!=='exports') throw Error('unnamed PE import: '+image);
    return name;
  }).filter(Boolean);
}

// Windows resolves DLLs beside the executable. Also retain lib/ for an SDK
// packager that installs its own launcher and records the producer's bytes.
export function installDlls({sdk,images,prefix,llvm,lint=false}) {
  const seen=new Set(),queue=[...images];
  for (const image of queue) for (const dll of coffNames(sdk,image,'imports')) {
    const name=dll.toLowerCase();
    if (path.win32.basename(name)!==name || !name.endsWith('.dll')) throw Error('invalid PE dependency: '+dll);
    if (seen.has(name)) continue;
    seen.add(name);
    if (lint && /^lib(?:cjlint|cangjie-lsp)\./.test(name)) throw Error('retired lint dependency: '+dll);
    const from=[llvm,...dllRoots(sdk).map(dir=>path.join(dir,dll)),...images].find(file=>file && path.basename(file).toLowerCase()===name && fs.statSync(file,{throwIfNoEntry:false})?.isFile());
    if (!from) {
      if (/^(api|ext)-ms-win-/.test(name) || fs.statSync(path.join(process.env.SystemRoot,'System32',dll),{throwIfNoEntry:false})?.isFile()) continue;
      throw Error('unresolved selected SDK dependency: '+dll+' from '+image);
    }
    queue.push(from);
    const dirs=['lib','bin'];
    if (lint && name==='libcangjie-runtime.dll') dirs.push(path.join('runtime/lib',tuple));
    for (const dir of dirs) {
      const target=path.join(prefix,dir,name);
      fs.mkdirSync(path.dirname(target),{recursive:true});
      if(path.resolve(from).toLowerCase()!==path.resolve(target).toLowerCase()) fs.copyFileSync(from,target);
    }
  }
}
