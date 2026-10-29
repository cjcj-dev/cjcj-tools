#!/usr/bin/env zx
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(process.argv.findIndex(arg => path.resolve(arg) === fileURLToPath(import.meta.url)) + 1);
const {positionals, values: v} = parseArgs({args, allowPositionals: true, options: {
  'build-type': {type: 'string', short: 't', default: 'debug'},
  'build-dir': {type: 'string', default: path.join(root, 'cmake-build')},
  'cangjie-sdk': {type: 'string'}, 'mangle-source': {type: 'string'},
  prefix: {type: 'string'}, 'set-rpath': {type: 'string'},
  target: {type: 'string'}, 'target-sysroot': {type: 'string'},
  help: {type: 'boolean', short: 'h'},
}});
if (v.help) {
  console.log('build.mjs build|install|clean [--build-dir DIR] [--cangjie-sdk SDK] [--mangle-source packages/mangle/src] [-t debug|release|minsizerel|relwithdebinfo|minsizerelwithdebinfo] [--prefix DIR] [--set-rpath RPATH] [--target windows-x86_64 --target-sysroot DIR]');
} else {
  if (positionals.length !== 1) throw Error('expected one build command (see --help)');
  const run = async args => {
    console.log(JSON.stringify({argv: args}));
    const p = spawnSync(args[0], args.slice(1), {cwd: root, stdio: 'inherit'});
    if (p.error) throw p.error;
    if (p.status !== 0) process.exit(p.status ?? 1);
  };
  switch (positionals[0]) {
    case 'build': {
      const types = {debug: 'Debug', release: 'Release', minsizerel: 'MinSizeRel',
        relwithdebinfo: 'RelWithDebInfo', minsizerelwithdebinfo: 'MinSizeRelWithDebInfo'};
      if (!types[v['build-type']]) throw Error('invalid build type');
      const args = ['cmake', '-S', root, '-B', v['build-dir'], '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=' + types[v['build-type']],
        '-DZX_EXECUTABLE=' + fileURLToPath(import.meta.resolve('zx/cli'))];
      for (const [key, cmake] of [['cangjie-sdk', 'CANGJIE_HOME'], ['mangle-source', 'CANGJIE_MANGLE_SOURCE_DIR'],
        ['prefix', 'CMAKE_INSTALL_PREFIX'], ['set-rpath', 'RUNTIME_RPATH']]) {
        if (v[key]) args.push('-D' + cmake + '=' + v[key]);
      }
      if (v.target) {
        if (v.target !== 'windows-x86_64' || !v['target-sysroot']) throw Error('Windows cross build requires --target windows-x86_64 --target-sysroot DIR');
        args.push('-DCMAKE_TOOLCHAIN_FILE=' + path.join(root, 'cmake/mingw_x86_64_toolchain.cmake'),
          '-DCMAKE_SYSROOT=' + v['target-sysroot']);
      }
      await run(args);
      await run(['cmake', '--build', v['build-dir']]);
      break;
    }
    case 'install':
      await run(['cmake', '--install', v['build-dir'], ...(v.prefix ? ['--prefix', v.prefix] : [])]);
      break;
    case 'clean':
      await run(['cmake', '--build', v['build-dir'], '--target', 'clean']);
      break;
    default: throw Error('expected build, install or clean (see --help)');
  }
}
