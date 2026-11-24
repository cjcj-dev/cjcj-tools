#!/usr/bin/env node
// Clean-machine build contract: build/build.mjs and build/prepare-demangler.mjs
// run under plain node with no zx package reachable from the package, and the
// CMake generator step is driven by the native node executable.
// usage: node tests/public/build-no-zx.mjs <compiler packages/mangle/src>
// (or CANGJIE_MANGLE_SOURCE_DIR). POSIX hosts only: cmake is stubbed by a
// /bin/sh wrapper in PATH.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const pkg = path.resolve(fileURLToPath(new URL('../../', import.meta.url)));
const mangleArg = process.argv.slice(process.argv.findIndex(arg => path.resolve(arg) === fileURLToPath(import.meta.url)) + 1)[0];
const mangle = mangleArg ?? process.env.CANGJIE_MANGLE_SOURCE_DIR;
if (!mangle) throw Error('usage: build-no-zx.mjs <compiler packages/mangle/src> (or CANGJIE_MANGLE_SOURCE_DIR)');
if (process.platform === 'win32') throw Error('build-no-zx.mjs stubs cmake with a POSIX shell wrapper');

const work = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'trace-no-zx-')));
const checks = [];
function check(name, fn) {
  try { fn(); checks.push({name, pass: true}); }
  catch (error) { checks.push({name, pass: false, error: String(error)}); }
  fs.writeFileSync(path.join(work, 'assertions.json'), JSON.stringify(checks, null, 2));
}
function zxAncestors(start) {
  const found = [];
  for (let dir = start; ; dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, 'node_modules', 'zx'))) found.push(path.join(dir, 'node_modules', 'zx'));
    if (path.dirname(dir) === dir) return found;
  }
}
// Isolated environment: no module search hints, and the stub cmake first in PATH.
const env = {...process.env};
for (const key of ['NODE_PATH', 'NODE_OPTIONS', 'npm_config_prefix']) delete env[key];

// Copy the package build inputs out of the source tree, so no ancestor of the
// scripts can provide node_modules/zx.
const copy = path.join(work, 'cjtrace-recover');
fs.mkdirSync(copy);
for (const entry of ['build', 'cmake', 'CMakeLists.txt']) fs.cpSync(path.join(pkg, entry), path.join(copy, entry), {recursive: true});
check('no node_modules/zx in any ancestor of the copied build scripts', () =>
  assert.deepEqual(zxAncestors(path.join(copy, 'build')), []));

// (a) build.mjs build with a stub cmake that records argv.
const bin = path.join(work, 'bin'), log = path.join(work, 'cmake-argv.jsonl');
fs.mkdirSync(bin);
fs.writeFileSync(path.join(work, 'cmake-stub.cjs'),
  "require('node:fs').appendFileSync(process.env.TRACE_CMAKE_LOG, JSON.stringify(process.argv.slice(2)) + '\\n');\n");
fs.writeFileSync(path.join(bin, 'cmake'),
  '#!/bin/sh\nexec ' + JSON.stringify(process.execPath) + ' ' + JSON.stringify(path.join(work, 'cmake-stub.cjs')) + ' "$@"\n', {mode: 0o755});
const buildDir = path.join(work, 'cmake-build');
const build = spawnSync(process.execPath, [path.join(copy, 'build', 'build.mjs'), 'build', '--build-dir', buildDir, '--mangle-source', mangle],
  {cwd: work, encoding: 'utf8', env: {...env, PATH: bin + path.delimiter + (env.PATH ?? ''), TRACE_CMAKE_LOG: log}});
fs.writeFileSync(path.join(work, 'build.stdout'), build.stdout ?? '');
fs.writeFileSync(path.join(work, 'build.stderr'), build.stderr ?? '');
check('build.mjs does not need the zx package', () => assert.doesNotMatch(build.stderr ?? '', /ERR_MODULE_NOT_FOUND|Cannot find package 'zx'/));
check('build.mjs build exits 0', () => { assert.equal(build.signal, null); assert.equal(build.status, 0, build.stderr); });
const calls = fs.existsSync(log) ? fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) : [];
check('cmake configured then built', () => {
  assert.equal(calls.length, 2, JSON.stringify(calls));
  assert.deepEqual(calls[0].slice(0, 6), ['-S', copy, '-B', buildDir, '-G', 'Ninja']);
  assert.deepEqual(calls[1], ['--build', buildDir]);
});
const zx = (calls[0] ?? []).filter(arg => arg.startsWith('-DZX_EXECUTABLE='));
check('-DZX_EXECUTABLE is process.execPath', () => assert.deepEqual(zx, ['-DZX_EXECUTABLE=' + process.execPath]));
check('-DZX_EXECUTABLE is a native executable file, not a script', () => {
  const exe = zx[0]?.slice('-DZX_EXECUTABLE='.length) ?? '';
  assert(path.isAbsolute(exe), exe);
  assert(fs.statSync(exe).isFile(), exe);
  fs.accessSync(exe, fs.constants.X_OK);
  assert.doesNotMatch(exe, /\.[cm]?js$/i);
  assert.notEqual(fs.readFileSync(exe).subarray(0, 2).toString('latin1'), '#!', exe + ' is an interpreter script');
});
check('-DCANGJIE_MANGLE_SOURCE_DIR forwarded', () => assert((calls[0] ?? []).includes('-DCANGJIE_MANGLE_SOURCE_DIR=' + mangle)));

// (b) prepare-demangler.mjs directly under node on the real compiler sources.
const names = ['CangjieDemangle', 'DeCompression', 'Demangler', 'DemangleUtils', 'MangleUtils', 'Compression'];
const digest = () => Object.fromEntries(names.map(n => [n, crypto.createHash('sha256').update(fs.readFileSync(path.join(mangle, n + '.cj'))).digest('hex')]));
const before = digest(), out = path.join(work, 'demangler-source');
const prepare = spawnSync(process.execPath, [path.join(copy, 'build', 'prepare-demangler.mjs'), mangle, out], {cwd: work, encoding: 'utf8', env});
fs.writeFileSync(path.join(work, 'prepare.stdout'), prepare.stdout ?? '');
fs.writeFileSync(path.join(work, 'prepare.stderr'), prepare.stderr ?? '');
check('prepare-demangler.mjs exits 0 under node', () => { assert.equal(prepare.signal, null); assert.equal(prepare.status, 0, prepare.stderr); });
check('prepare-demangler.mjs does not need the zx package', () => assert.doesNotMatch(prepare.stderr ?? '', /ERR_MODULE_NOT_FOUND/));
check('prepared files are exactly the demangler inputs', () =>
  assert.deepEqual(fs.existsSync(out) ? fs.readdirSync(out).filter(f => f.endsWith('.cj')).sort() : [],
    ['CangjieDemangle.cj', 'DeCompression.cj', 'DemangleUtils.cj', 'Demangler.cj', 'MangleUtils.cj']));
for (const n of ['CangjieDemangle', 'DeCompression', 'DemangleUtils'])
  check(n + '.cj copied verbatim', () => assert.equal(fs.readFileSync(path.join(out, n + '.cj'), 'utf8'), fs.readFileSync(path.join(mangle, n + '.cj'), 'utf8')));
check('MangleUtils.cj carries only the AST-independent declarations', () => {
  const text = fs.readFileSync(path.join(out, 'MangleUtils.cj'), 'utf8');
  assert(text.startsWith('package cjcj::mangle\n'));
  for (const marker of ['public func StartsWith(', 'public func IsPrimitivePrefix(', 'public class StringRef {', 'public class IntRef {']) assert(text.includes(marker), marker);
});
check('Demangler.cj rejects bare D', () => assert.match(fs.readFileSync(path.join(out, 'Demangler.cj'), 'utf8'),
  /if \(ch == b'D'\) \{\n\s+return Reject\("invalid primitive type"\)/));
check('compiler sources unchanged', () => assert.deepEqual(digest(), before));

// (c) direct cmake configure finds node or zx on a clean machine.
check('CMakeLists.txt accepts node or zx', () => assert.match(fs.readFileSync(path.join(pkg, 'CMakeLists.txt'), 'utf8'),
  /^find_program\(ZX_EXECUTABLE NAMES node zx REQUIRED\)$/m));

for (const c of checks.filter(c => !c.pass)) console.error('FAIL ' + c.name + ': ' + c.error);
assert(checks.every(c => c.pass), 'TRACE_BUILD_NO_ZX_TARGET ' + work);
console.log('TRACE_BUILD_NO_ZX_PASS ' + checks.length + ' checks ' + work);
