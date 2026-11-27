import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {hostTarget, loaderEnv, frontendCxxLibraries} from '../packages/build/native-host.mjs';

const root = path.resolve(import.meta.dirname, '..');
const preload = new URL('./fixtures/native-host.mjs', import.meta.url).href;
const hosts = [
  ['linux','x64','x86_64-unknown-linux-gnu','linux_x86_64_cjnative','LD_LIBRARY_PATH'],
  ['linux','arm64','aarch64-unknown-linux-gnu','linux_aarch64_cjnative','LD_LIBRARY_PATH'],
  ['darwin','arm64','aarch64-apple-darwin','darwin_aarch64_cjnative','DYLD_LIBRARY_PATH'],
  ['darwin','x64','x86_64-apple-darwin','darwin_x86_64_cjnative','DYLD_LIBRARY_PATH'],
  ['win32','x64','x86_64-w64-mingw32','windows_x86_64_cjnative',null],
];

function run(file, args, options, rc = 0) {
  const p = spawnSync(file, args, {cwd:root, encoding:'utf8', ...options});
  assert.ifError(p.error);
  assert.equal(p.status, rc, p.stdout+p.stderr);
  return p.stdout;
}

for (const [system, host, expected, cross] of [
  ['Windows','AMD64','windows_x86_64_cjnative'], ['Darwin','arm64','darwin_aarch64_cjnative'],
  ['Darwin','x86_64','darwin_x86_64_cjnative'], ['Linux','x86_64','linux_x86_64_cjnative'],
  ['Linux','aarch64','linux_aarch64_cjnative'],
  ['Windows','aarch64','windows_x86_64_cjnative','amd64'], ['Darwin','x86_64','darwin_aarch64_cjnative','ARM64'],
]) {
  test('cjtrace CMake '+system+'/'+(cross ?? host)+(cross?' cross':' native'), () => {
    run('cmake', ['-DSYSTEM='+system, '-DHOST_CPU='+host, '-DTARGET_CPU='+(cross ?? 'unused'),
      '-DCMAKE_CROSSCOMPILING='+(cross?'ON':'OFF'), '-DEXPECTED='+expected,
      '-P', 'tests/cjtrace-target.cmake']);
  });
}

function fixture(t, platform, arch, success = '') {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'native host-'));
  t.after(() => fs.rmSync(work, {recursive:true, force:true}));
  const at = (...parts) => path.join(work, ...parts);
  const write = (name, bytes = 'fixture') => {
    const file = at(name);
    fs.mkdirSync(path.dirname(file), {recursive:true});
    fs.writeFileSync(file, bytes, {mode:0o755});
    return file;
  };
  const env = {...process.env, NODE_OPTIONS:'--import='+preload, FIXTURE_PLATFORM:platform, FIXTURE_ARCH:arch,
    FIXTURE_RECORD:at('capture'), FIXTURE_SUCCESS:success, MINGW_PATH:at('mingw'), CC:at('fixture-cc')};
  delete env.LD_LIBRARY_PATH;
  delete env.DYLD_LIBRARY_PATH;
  function tool(name, phase, args, rc) {
    run(process.execPath, ['build.mjs', phase, '--tool', name, '--build-root', at('build'),
      ...(phase === 'install'?['--prefix', at('prefix')]:[]), '--', ...args], {env}, rc);
  }
  const calls = () => fs.readFileSync(at('capture'),'utf8').trim().split('\n').map(line => JSON.parse(line));
  return {at, write, tool, calls};
}

for (const [platform, arch, hostTriple, tuple, key] of hosts) {
  test('host tuple, triple and loader '+platform+'/'+arch, () => {
    assert.deepEqual(hostTarget(platform, arch), {hostTriple, tuple});
    assert.deepEqual(loaderEnv(['/runtime','/tools'], platform), key?{[key]:'/runtime:/tools'}:{});
  });

  function cjfmt(t, cross) {
    const {at, write, tool, calls} = fixture(t, platform, arch);
    const packages = ['parse','option','ast','lex','utils','basic'];
    for (const pkg of packages) {
      write('frontend/'+pkg+'@cjcj.cjo');
      write('frontend/lib'+pkg+'.a');
    }
    tool('cjfmt','build',['--sdk',at('sdk'),'--cjpm-sdk',at('bootstrap'),
      '--frontend-cjo',at('frontend'),'--frontend-lib',at('frontend'), ...(cross?['--target',cross]:[])],73);
    const [call] = calls();
    assert.equal(call.file, at('bootstrap/tools/bin/cjpm'+(platform==='win32'?'.exe':'')));
    assert.equal(call.CANGJIE_HOME, at('sdk'));
    const manifest = fs.readFileSync(path.join(call.cwd,'cjpm.toml'),'utf8');
    assert.ok(manifest.includes('[target.'+(cross || hostTriple)+'.bin-dependencies.package-option]'), manifest);
    for (const pkg of packages) assert.ok(manifest.includes('"'+pkg+'" = '));
    if (cross) assert.deepEqual(call.args.slice(-2), ['--target',cross]);
    else assert.ok(!call.args.includes('--target'));
    const runtime = at('bootstrap/runtime/lib',tuple);
    if (key) assert.equal(call[key], [runtime,at('bootstrap/tools/lib'),at('bootstrap/third_party/llvm/lib')].join(':'));
    else assert.ok(call.PATH.split(path.delimiter).includes(runtime));
    for (const other of ['DYLD_LIBRARY_PATH','LD_LIBRARY_PATH'].filter(k=>k!==key)) assert.equal(call[other], undefined);
  }
  test('cjfmt manifest and child environment '+platform+'/'+arch, t => cjfmt(t));
  if (platform==='darwin' && arch==='arm64') {
    test('cjfmt explicit cross target keeps the Darwin host loader', t => cjfmt(t,'x86_64-w64-mingw32'));
  }
}

for (const [platform, arch, , tuple, key] of hosts.filter(h => h[1]==='x64')) {
  const cxx = mingw => platform==='darwin'?['-lc++']:platform==='linux'?['-lstdc++']:
    ['-L'+path.join(mingw,'x86_64-w64-mingw32/lib'),'-lc++','-lunwind'];
  test('frontend C++ runtime '+platform, () => {
    assert.deepEqual(frontendCxxLibraries(platform,'selected mingw'), cxx('selected mingw'));
    if (platform==='win32') assert.throws(()=>frontendCxxLibraries(platform,''),/MINGW_PATH/);
  });
  test('cjcompat compiler arguments '+platform, t => {
    const {at, write, tool, calls} = fixture(t, platform, arch);
    const a = write('libs/ast@cjcj/libast.a'), b = write('libs/basic@cjcj/libbasic.a');
    write('libs/driver@cjcj/libdriver.a');
    const ref = run('git',['rev-parse','HEAD']).trim();
    tool('cjcompat','build',['--sdk',at('sdk'),'--compiler-source',root,'--frontend-ref',ref,
      '--compiler-libs',at('libs'),'--runtime-config',at('config.o'),'--shim',at('shim.o'),'--llvm',at('llvm/libLLVM')],73);
    const [call] = calls();
    const links = call.args.flatMap((arg,i) => arg==='--link-option'?[call.args[i+1]]:[]);
    const archives = platform==='darwin'?['-force_load',a,'-force_load',b]:['--start-group',a,b,'--end-group'];
    assert.deepEqual(links,[...archives,at('config.o'),at('shim.o'),at('llvm/libLLVM'),...cxx(at('mingw'))]);
    if (key) assert.equal(call[key], [at('sdk/runtime/lib',tuple),at('sdk/tools/lib'),at('llvm')].join(':'));
    else assert.ok(call.PATH.split(path.delimiter).includes(at('sdk/runtime/lib',tuple)));
  });
}

for (const name of ['lsp', 'cjlint']) {
  test(name+' Darwin build and install select the same runtime', t => {
    const {at, write, tool, calls} = fixture(t, 'darwin', 'arm64', 'cjpm');
    const tuple = 'darwin_aarch64_cjnative', triple = 'aarch64-apple-darwin';
    const llvm = write('llvm/libLLVM.dylib','fixture llvm');
    const shim = write('shim.o'), config = write('config.o');
    write('sdk/runtime/lib/'+tuple+'/libcangjie-runtime.dylib','fixture runtime');
    write('sdk/bin/cjc');
    write('sdk/modules/fixture.cjo');
    write('sdk/third_party/flatbuffers/modules/flatbuffers.cjo');
    const inputs = name==='lsp' ? ['--cjpm',at('sdk/tools/bin/cjpm'),'--server','stdio',
      '--frontend-packages',at('packages'),'--runtime-config',config,'--json-build',at('json')] :
      ['--analysis-sdk',at('sdk'),'--frontend-source',root,'--frontend-ref','1'.repeat(40),
       '--frontend-artifacts',at('packages'),'--frontend-runtime-object',config];
    tool(name,'build',['--sdk',at('sdk'),'--llvm-shim',shim,'--llvm-library',llvm,...inputs],0);
    const call = calls().at(-1);
    const manifest = fs.readFileSync(path.join(call.cwd,'cjpm.toml'),'utf8');
    assert.ok(manifest.includes('[target.'+triple+'.bin-dependencies]'));
    let links;
    if (name==='lsp') {
      const response = manifest.match(/--link-option=@(native-link-[a-f0-9]+\.rsp)/);
      assert.ok(response, manifest);
      links = fs.readFileSync(path.join(call.cwd,response[1]),'utf8').trim().split('\n').map(s=>JSON.parse(s));
      assert.ok(links.includes(path.join(at('json/lib',tuple),'libstdx.encoding.json.a')));
    } else {
      links = JSON.parse(manifest.match(/^link-option = (.+)$/m)[1]).split(' ');
      assert.ok(call.DYLD_LIBRARY_PATH.startsWith(at('sdk/runtime/lib',tuple)+':'));
    }
    for (const flag of ['-lc++','-export_dynamic','-rpath','@executable_path/../lib']) assert.ok(links.includes(flag), flag);
    assert.ok(!links.some(arg=>arg.startsWith('--export-dynamic-symbol') || arg.includes('$ORIGIN')));
    tool(name,'install',[],0);
    assert.equal(fs.readFileSync(at('prefix/lib/libcangjie-runtime.dylib'),'utf8'),'fixture runtime');
    assert.equal(fs.readFileSync(at('prefix/lib/libLLVM.dylib'),'utf8'),'fixture llvm');
    if (name==='cjlint') assert.equal(fs.readFileSync(at('prefix/runtime/lib',tuple,'libcangjie-runtime.dylib'),'utf8'),'fixture runtime');
  });
}

test('cjprof Linux arm64 passes the host runtime to both compilers', t => {
  const {at, tool, calls} = fixture(t, 'linux', 'arm64', 'cjc');
  tool('cjprof','build',['--sdk',at('sdk'),'--jni-home',at('jdk'),'--runtime-header',at('Cangjie.h')],73);
  const records = calls(), runtime = at('sdk/runtime/lib/linux_aarch64_cjnative');
  assert.deepEqual(records.map(row=>path.basename(row.file)), ['cjc','cjc','fixture-cc']);
  for (const row of records) assert.equal(row.LD_LIBRARY_PATH,[runtime,at('sdk/tools/lib')].join(':'));
  assert.ok(records[2].args.includes('-L'+runtime));
});

test('cjtrace install consumes the normalized Windows SDK directory', t => {
  const {at, write} = fixture(t,'win32','x64');
  const build = at('trace build'), sdk = at('sdk');
  write('sdk/runtime/lib/windows_x86_64_cjnative/selected.dll','selected runtime');
  run('cmake',['-S','packages/cjtrace-recover','-B',build,'-G','Ninja','-DCMAKE_SYSTEM_NAME=Windows',
    '-DCMAKE_SYSTEM_PROCESSOR=AMD64','-DCANGJIE_TRIPLE=x86_64-windows-gnu','-Dcjc_path='+path.join(sdk,'bin/cjc'),
    '-DCANGJIE_MANGLE_SOURCE_DIR='+at('mangle')]);
  // Exercise the generated install rules without compiling the tool.
  write('trace build/cjtrace-recover.exe','fixture executable');
  run('cmake',['--install',build,'--prefix',at('prefix')]);
  assert.equal(fs.readFileSync(at('prefix/bin/selected.dll'),'utf8'),'selected runtime');
});
