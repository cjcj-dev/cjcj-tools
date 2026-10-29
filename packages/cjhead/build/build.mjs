#!/usr/bin/env zx
import {$} from 'zx';
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';
import {createHash} from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const {values: v, positionals} = parseArgs({args: process.argv.slice(process.argv.findIndex(arg => path.resolve(arg) === fileURLToPath(import.meta.url)) + 1), allowPositionals: true, options: {
  cjc: {type: 'string'}, 'frontend-dir': {type: 'string'}, shim: {type: 'string'},
  'runtime-config': {type: 'string'},
  'llvm-lib': {type: 'string'}, 'frontend-commit': {type: 'string'},
  'build-dir': {type: 'string', default: path.join(root, 'output')},
  prefix: {type: 'string'}, jobs: {type: 'string', default: '4'},
  'runtime-dir': {type: 'string'}, 'source-commit': {type: 'string'}, help: {type: 'boolean'},
}});
const command = positionals[0] ?? 'build';
if (v.help || !['build', 'install'].includes(command)) {
  console.log('zx build/build.mjs build --cjc PATH --frontend-dir CJO_DIR --shim LLVM_SHIM.o --llvm-lib LIBLLVM --frontend-commit SHA [--build-dir DIR] [--jobs N]\nzx build/build.mjs install --build-dir DIR --prefix DIR [--runtime-dir DIR]');
  process.exit(v.help ? 0 : 2);
}
const build = path.resolve(v['build-dir']);
await fs.mkdir(build, {recursive: true});
const exe = 'cjhead' + (process.platform === 'win32' ? '.exe' : '');
const factsFile = path.join(build, 'build-facts.json');
const digest = async file => createHash('sha256').update(await fs.readFile(file)).digest('hex');

if (command === 'build') {
  for (const key of ['frontend-dir', 'shim', 'llvm-lib', 'frontend-commit']) {
    if (!v[key]) throw Error('Required option: --' + key);
  }
  const cjc = path.resolve(v.cjc ?? path.join(process.env.CANGJIE_HOME ?? '', 'bin/cjc'));
  const frontend = path.resolve(v['frontend-dir']);
  const jobs = Number(v.jobs);
  if (!Number.isInteger(jobs) || jobs < 1) throw Error('Invalid --jobs');
  const packages = ['ast', 'basic', 'chir', 'codegen', 'conditional_compilation', 'flatbuffers', 'frontend',
    'incremental_compilation', 'lex', 'macro_pkg', 'mangle', 'meta_transformation', 'modules', 'option', 'parse', 'sema', 'utils'];
  const imports = [], libraries = [];
  for (const name of packages) {
    const dir = path.join(frontend, name + '@cjcj');
    await fs.access(path.join(dir, name + '@cjcj.cjo'));
    imports.push('--import-path', dir);
    for (const file of (await fs.readdir(dir)).sort()) {
      if (file.endsWith('.a')) libraries.push(path.join(dir, file));
    }
  }
  const product = path.join(build, exe);
  const link = process.platform === 'darwin'
    ? libraries.flatMap(file => ['-force_load', file])
    : ['--start-group', ...libraries, '--end-group'];
  link.push(path.resolve(v['llvm-lib']), process.platform === 'darwin' ? '-lc++' : '-lstdc++');
  if (process.platform !== 'win32') {
    link.push('-rpath', process.platform === 'darwin' ? '@executable_path/../lib' : '$ORIGIN/../lib');
  }
  const argv = [cjc, '-p', path.join(root, 'src'), '-o', product, '-j', String(jobs), ...imports,
    ...(v['runtime-config'] ? [path.resolve(v['runtime-config'])] : []),
    path.resolve(v.shim), ...link.flatMap(option => ['--link-options', option])];
  const result = await $({cwd: root, nothrow: true, quiet: true})`${argv}`;
  await fs.writeFile(path.join(build, 'compile.stdout'), result.stdout);
  await fs.writeFile(path.join(build, 'compile.stderr'), result.stderr);
  const facts = {command: argv, rc: result.exitCode, signal: result.signal ?? null,
    frontend: {commit: v['frontend-commit'], directory: frontend}, llvm: path.resolve(v['llvm-lib']),
    cjc, runtimeConfig: v['runtime-config'] ? path.resolve(v['runtime-config']) : null,
    platform: process.platform, architecture: process.arch,
    sourceCommit: v['source-commit'] ?? null, runtimeDirectory: v['runtime-dir'] ?? null};
  if (result.exitCode === 0) facts.product = {path: product, sha256: await digest(product)};
  await fs.writeFile(factsFile, JSON.stringify(facts, null, 2) + '\n');
  process.stdout.write(result.stdout); process.stderr.write(result.stderr);
  process.exitCode = result.exitCode;
} else {
  if (!v.prefix) throw Error('Required option: --prefix');
  const facts = JSON.parse(await fs.readFile(factsFile, 'utf8'));
  if (facts.rc !== 0 || !facts.product) throw Error('No successful cjhead build');
  const prefix = path.resolve(v.prefix);
  await fs.mkdir(path.join(prefix, 'bin'), {recursive: true});
  await fs.mkdir(path.join(prefix, 'lib'), {recursive: true});
  await fs.copyFile(facts.product.path, path.join(prefix, 'bin', exe));
  await fs.chmod(path.join(prefix, 'bin', exe), 0o755);
  const libraryDir = path.join(prefix, process.platform === 'win32' ? 'bin' : 'lib');
  await fs.copyFile(facts.llvm, path.join(libraryDir, path.basename(facts.llvm)));
  const runtime = v['runtime-dir'] ?? facts.runtimeDirectory;
  if (runtime) {
    for (const item of await fs.readdir(runtime)) {
      if (/\.(so(?:\..*)?|dylib|dll)$/.test(item)) {
        await fs.copyFile(path.join(runtime, item), path.join(libraryDir, item));
      }
    }
  }
  await fs.mkdir(path.join(prefix, 'share', 'cjhead'), {recursive: true});
  for (const item of ['LICENSE', 'COPYRIGHT', 'COPYRIGHT_EN', 'user_guide.md']) {
    await fs.copyFile(path.join(root, 'doc', item), path.join(prefix, 'share', 'cjhead', item));
  }
  await fs.writeFile(path.join(prefix, 'share', 'cjhead', 'build-facts.json'), JSON.stringify(facts, null, 2) + '\n');
  console.log('Installed cjhead: ' + prefix);
}
