// cjpm wasm32-wasi (WASI preview1, M0) consumer suite.
// usage: node wasm32-wasi.mjs <cjpm> <new-work-dir>   (CANGJIE_HOME = a wasm32-wasi capable SDK, e.g. ci/wasm-sdk-overlay.mjs output)
// Writes small projects, runs cjpm build/run/test --target for wasm32-wasi and checks exact exit codes and messages.
// Cases marked BLOCKED pin today's explicit failure of a dependency outside cjpm (lane-1 wasm std) and flip when it lands.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const [cjpmArg, workArg] = process.argv.slice(2);
assert(cjpmArg && workArg, 'usage: wasm32-wasi.mjs <cjpm> <new-work-dir>');
const cjpm = path.resolve(cjpmArg), work = path.resolve(workArg);
assert(!fs.existsSync(work) || fs.readdirSync(work).length === 0, 'use a new empty work directory');
const home = process.env.CANGJIE_HOME;
assert(home && fs.existsSync(path.join(home, 'modules/wasi_wasm32_cjnative/std/std.core.cjo')), 'CANGJIE_HOME must be a wasm32-wasi SDK');
const node = path.join(home, 'tools/bin/node');
const REL = 'target/wasm32-unknown-wasi/release';
// node flags cjpm passes to the runner (WasmRunner.command); direct-runner cases use the same set.
const NODE_FLAGS = ['--no-warnings', '--no-turbo-fast-api-calls'];

function write(file, text) { fs.mkdirSync(path.dirname(file), {recursive: true}); fs.writeFileSync(file, text); }
function module(name, type, deps, file, src) {
  const d = deps.map(x => `  ${x} = { path = "../${x}" }\n`).join('');
  write(path.join(work, name, 'cjpm.toml'), `[package]\n  cjc-version = "1.0.0"\n  name = "${name}"\n  version = "1.0.0"\n  output-type = "${type}"\n` + (d ? `\n[dependencies]\n${d}` : ''));
  write(path.join(work, name, 'src', file), src);
}
module('mathlib', 'static', [], 'fib.cj', 'package mathlib\n\npublic func fib(n: Int64): Int64 {\n    var a = 0\n    var b = 1\n    for (_ in 0..n) {\n        let t = a + b\n        a = b\n        b = t\n    }\n    return a\n}\n');
module('app', 'executable', ['mathlib'], 'main.cj', 'package app\n\nimport mathlib.fib\n\nmain(): Int64 {\n    let f = fib(10)\n    let g = fib(9)\n    println("fib(10)=${f} fib(9)=${g}")\n    return f + g - 60\n}\n');
module('zero', 'executable', ['mathlib'], 'main.cj', 'package zero\n\nimport mathlib.fib\n\nmain(): Int64 {\n    println("fib(10)=${fib(10)}")\n    return 0\n}\n');
module('twice', 'static', [], 'twice.cj', 'macro package twice\n\nimport std.ast.*\n\npublic macro Twice(input: Tokens): Tokens {\n    return quote(($input) + ($input))\n}\n');
module('appm', 'executable', ['twice'], 'main.cj', 'package appm\n\nimport twice.Twice\n\nmain(): Int64 {\n    println("twice(21)=${@Twice(21)}")\n    return 0\n}\n');
module('athrow', 'executable', [], 'main.cj', 'package athrow\n\nmain(): Int64 {\n    throw Exception("boom")\n}\n');

const results = [];
function run(name, dir, args, {env = {}, expectRc, expect}) {
  const p = spawnSync(args[0], args.slice(1), {cwd: path.join(work, dir), encoding: 'utf8', env: {...process.env, ...env}, maxBuffer: 16 << 20});
  const text = ((p.stdout ?? '') + (p.stderr ?? '')).replace(/\x1b\[[0-9;]*m/g, '');
  const pass = p.error === undefined && p.status === expectRc && expect.test(text);
  results.push({name, rc: p.status, expectRc, expect: String(expect), pass, tail: text.slice(-400)});
}
const sha = f => fs.existsSync(f) ? spawnSync('sha256sum', [f], {encoding: 'utf8'}).stdout.slice(0, 64) : null;
function fileCase(name, file, magic) {
  const ok = fs.existsSync(file) && fs.readFileSync(file).subarray(0, 4).toString('hex') === magic;
  results.push({name, rc: ok ? 0 : 1, expectRc: 0, expect: `${path.relative(work, file)} magic ${magic}`, pass: ok, tail: ''});
}

run('build-wasm32-wasi', 'app', [cjpm, 'build', '--target', 'wasm32-wasi'], {expectRc: 0, expect: /cjpm build success/});
fileCase('artifact-main.wasm', path.join(work, 'app', REL, 'bin/main.wasm'), '0061736d');
fileCase('artifact-libmathlib.a', path.join(work, 'app', REL, 'mathlib/libmathlib.a'), '213c6172');
const first = sha(path.join(work, 'app', REL, 'bin/main.wasm'));
run('run-nonzero-like-native', 'app', [cjpm, 'run', '--target', 'wasm32-wasi', '--skip-build'], {expectRc: 1, expect: /fib\(10\)=55 fib\(9\)=34/});
run('runner-exact-status', 'app', [node, ...NODE_FLAGS, `${REL}/cjpm-wasi-runner.mjs`, `${REL}/bin/main.wasm`], {expectRc: 29, expect: /fib\(10\)=55/});
run('run-zero', 'zero', [cjpm, 'run', '--target', 'wasm32-wasi'], {expectRc: 0, expect: /cjpm run finished/});
for (const alias of ['wasm32-wasip1', 'wasm32-unknown-wasi', 'wasm32-unknown-wasip1']) {
  fs.rmSync(path.join(work, 'app', 'target'), {recursive: true, force: true});
  run(`build-${alias}`, 'app', [cjpm, 'build', '--target', alias], {expectRc: 0, expect: /cjpm build success/});
  const s = sha(path.join(work, 'app', REL, 'bin/main.wasm'));
  results.push({name: `alias-${alias}-same-artifact`, rc: s === first ? 0 : 1, expectRc: 0, expect: `sha ${first}`, pass: s !== null && s === first, tail: String(s)});
}
for (const t of ['wasm32-unknown-unknown', 'wasm32-wasip2', 'wasm64-wasi', 'wasm32-unknown-emscripten', 'wasm32-wasi-threads']) {
  run(`reject-${t}`, 'app', [cjpm, 'build', '--target', t], {expectRc: 1, expect: new RegExp(`wasm target '${t}' is not supported`)});
}
run('run-rejects-non-wasm-target', 'app', [cjpm, 'run', '--target', 'aarch64-unknown-linux-gnu'], {expectRc: 1, expect: /supports only the wasm32-wasi target/});
run('test-needs-wasm-std.unittest', 'app', [cjpm, 'test', '--target', 'wasm32-wasi'], {expectRc: 1, expect: /needs std\.unittest built for wasm32-wasi/});
run('bench-needs-wasm-std.unittest', 'app', [cjpm, 'bench', '--target', 'wasm32-wasi'], {expectRc: 1, expect: /needs std\.unittest built for wasm32-wasi/});
run('build-target-dir', 'app', [cjpm, 'build', '--target', 'wasm32-wasi', '--target-dir', path.join(work, 'tdir')], {expectRc: 0, expect: /cjpm build success/});
fileCase('target-dir-artifact', path.join(work, 'tdir', 'wasm32-unknown-wasi/release/bin/main.wasm'), '0061736d');
run('run-missing-node-override', 'app', [cjpm, 'run', '--target', 'wasm32-wasi', '--skip-build'], {env: {CJPM_WASM_NODE: '/nonexistent/node'}, expectRc: 1, expect: /CJPM_WASM_NODE='\/nonexistent\/node' does not exist/});
// cjpm runs node with --no-turbo-fast-api-calls (V8 SIGSEGV in the WASI fd_write fast API on large memories); a shim records argv.
const shim = path.join(work, 'node-shim.sh'), argvLog = path.join(work, 'node-shim.argv');
write(shim, `#!/bin/sh\nprintf '%s\\n' "$@" > '${argvLog}'\nexec '${node}' "$@"\n`); fs.chmodSync(shim, 0o755);
run('run-node-flags', 'app', [cjpm, 'run', '--target', 'wasm32-wasi', '--skip-build'], {env: {CJPM_WASM_NODE: shim}, expectRc: 1, expect: /fib\(10\)=55 fib\(9\)=34/});
const argv = fs.existsSync(argvLog) ? fs.readFileSync(argvLog, 'utf8').split('\n') : [];
const flagsOk = NODE_FLAGS.every((f, i) => argv[i] === f) && /cjpm-wasi-runner\.mjs$/.test(argv[NODE_FLAGS.length] ?? '');
results.push({name: 'run-node-argv-fast-api-off', rc: flagsOk ? 0 : 1, expectRc: 0, expect: `argv starts ${NODE_FLAGS.join(' ')} <runner.mjs>`, pass: flagsOk, tail: argv.slice(0, 4).join(' ')});
const toml = path.join(work, 'app', 'cjpm.toml'), original = fs.readFileSync(toml, 'utf8');
const withToml = (extra, fn) => { fs.writeFileSync(toml, original + extra); try { fn(); } finally { fs.writeFileSync(toml, original); } };
withToml('\n[profile.build]\n  lto = "full"\n', () => run('reject-lto', 'app', [cjpm, 'build', '--target', 'wasm32-wasi'], {expectRc: 1, expect: /profile\.build\.lto' \(LTO\) is not supported/}));
withToml('\n[target.wasm32-wasi]\n  compile-macros-for-target = "all"\n', () => run('reject-compile-macros-for-target', 'app', [cjpm, 'build', '--target', 'wasm32-wasi'], {expectRc: 1, expect: /compile-macros-for-target' in .* is not supported/}));
withToml('\n[target.wasm32-wasi]\n  compile-option = "--wasm32-wasi-suite-no-such-option"\n', () => run('alias-target-section-applied', 'app', [cjpm, 'build', '--target', 'wasm32-wasi'], {expectRc: 1, expect: /invalid option: '--wasm32-wasi-suite-no-such-option'/}));
for (const [a, b] of [['wasm32-wasi', 'wasm32-unknown-wasi'], ['wasm32-wasip1', 'wasm32-wasi']]) {
  withToml(`\n[target.${a}]\n  compile-option = "-O2"\n\n[target.${b}]\n  compile-option = "-O2"\n`, () => run(`reject-two-sections-${a}+${b}`, 'app', [cjpm, 'build', '--target', 'wasm32-wasi'],
    {expectRc: 1, expect: /all configure wasm32-unknown-wasi; keep exactly one of these sections/}));
}
const libToml = path.join(work, 'mathlib', 'cjpm.toml'), libOriginal = fs.readFileSync(libToml, 'utf8');
fs.writeFileSync(libToml, libOriginal.replace('output-type = "static"', 'output-type = "dynamic"'));
run('reject-dynamic-library', 'app', [cjpm, 'build', '--target', 'wasm32-wasi'], {expectRc: 1, expect: /package 'mathlib' \(no dynamic libraries\) is not supported/});
fs.writeFileSync(libToml, libOriginal);
run('runtime-exception-explicit', 'athrow', [cjpm, 'run', '--target', 'wasm32-wasi'], {expectRc: 1, expect: /throwing an exception/});
run('runtime-exception-status', 'athrow', [node, ...NODE_FLAGS, `${REL}/cjpm-wasi-runner.mjs`, `${REL}/bin/main.wasm`], {expectRc: 134, expect: /throwing an exception/});
// workspace: members build into one target dir; like native workspaces, `run` needs --name.
write(path.join(work, 'ws', 'cjpm.toml'), '[workspace]\n  members = ["app", "mathlib"]\n');
const noTarget = root => f => !path.relative(root, f).split(path.sep).includes('target');
for (const m of ['app', 'mathlib']) fs.cpSync(path.join(work, m), path.join(work, 'ws', m), {recursive: true, filter: noTarget(path.join(work, m))});
fs.writeFileSync(path.join(work, 'ws', 'app', 'cjpm.toml'), fs.readFileSync(path.join(work, 'app', 'cjpm.toml'), 'utf8'));
run('workspace-build', 'ws', [cjpm, 'build', '--target', 'wasm32-wasi'], {expectRc: 0, expect: /cjpm build success/});
fileCase('workspace-artifact-app.wasm', path.join(work, 'ws', REL, 'bin/app.wasm'), '0061736d');
run('workspace-run-name', 'ws', [cjpm, 'run', '--target', 'wasm32-wasi', '--skip-build', '--name', 'app'], {expectRc: 1, expect: /fib\(10\)=55 fib\(9\)=34/});
// build.cj is compiled for the host with --cfg target=<canonical triple>.
fs.cpSync(path.join(work, 'zero'), path.join(work, 'scripted'), {recursive: true, filter: noTarget(path.join(work, 'zero'))});
write(path.join(work, 'scripted', 'build.cj'), 'import std.fs.*\nimport std.process.Process\n\n@When[target == "wasm32-unknown-wasi"]\nfunc which(): String { "wasm32-unknown-wasi" }\n\n@When[target != "wasm32-unknown-wasi"]\nfunc which(): String { "other" }\n\nfunc stagePreBuild(): Int64 {\n    File.writeTo("script-target.txt", which().toArray())\n    0\n}\n\nmain(): Int64 {\n    match (Process.current.arguments[0]) {\n        case "pre-build" => stagePreBuild()\n        case _ => 0\n    }\n}\n');
fs.writeFileSync(path.join(work, 'scripted', 'cjpm.toml'), fs.readFileSync(path.join(work, 'zero', 'cjpm.toml'), 'utf8').replace('name = "zero"', 'name = "scripted"'));
fs.writeFileSync(path.join(work, 'scripted', 'src', 'main.cj'), fs.readFileSync(path.join(work, 'zero', 'src', 'main.cj'), 'utf8').replace('package zero', 'package scripted'));
run('build-script-run', 'scripted', [cjpm, 'run', '--target', 'wasm32-wasi'], {expectRc: 0, expect: /cjpm run finished/});
const marker = path.join(work, 'scripted', 'script-target.txt');
const seen = fs.existsSync(marker) ? fs.readFileSync(marker, 'utf8') : 'MISSING';
results.push({name: 'build-script-sees-canonical-target', rc: seen === 'wasm32-unknown-wasi' ? 0 : 1, expectRc: 0, expect: 'script-target.txt == wasm32-unknown-wasi', pass: seen === 'wasm32-unknown-wasi', tail: seen});
run('BLOCKED-macro-consumer-needs-wasm-std.ast', 'appm', [cjpm, 'build', '-V', '--target', 'wasm32-wasi'], {expectRc: 1,
  expect: /(?=[\s\S]*Compiling package .twice.:(?:(?!--target)[^\n])*--compile-macro)(?=[\s\S]*Compiling package .appm.:[^\n]*--target=wasm32-unknown-wasi)[\s\S]*can not find package .std\.ast./});

fs.writeFileSync(path.join(work, 'results.json'), JSON.stringify({cjpm, home, results}, null, 2));
const failed = results.filter(r => !r.pass);
for (const r of results) console.log(`${r.pass ? 'PASS' : 'FAIL'} ${r.name}: rc=${r.rc} expect rc=${r.expectRc} ${r.expect}`);
console.log(`WASM32_WASI_FAILS=${failed.length} of ${results.length}`);
process.exit(failed.length === 0 ? 0 : 1);
