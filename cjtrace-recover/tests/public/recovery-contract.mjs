#!/usr/bin/env zx
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const args = process.argv.slice(process.argv.findIndex(arg => path.resolve(arg) === fileURLToPath(import.meta.url)) + 1);
const [binary, work, baseline] = args;
if (!binary || !work) throw Error('usage: recovery-contract.mjs <installed-trace> <work> [baseline-trace]');
await fs.mkdir(work, {recursive: true});
const commands = [], checks = [];
async function run(label, argv) {
  const env = baseline && argv[0] === baseline && process.env.CJTRACE_BASELINE_LD_LIBRARY_PATH
    ? {...process.env, LD_LIBRARY_PATH: process.env.CJTRACE_BASELINE_LD_LIBRARY_PATH} : process.env;
  const p = spawnSync(argv[0], argv.slice(1), {env, encoding: 'utf8', timeout: 30000, maxBuffer: 8 * 1024 * 1024});
  await fs.writeFile(path.join(work, label + '.stdout'), p.stdout ?? '');
  await fs.writeFile(path.join(work, label + '.stderr'), p.stderr ?? '');
  commands.push({label, argv, rc: p.status, signal: p.signal, executorError: p.error?.message ?? null});
  await fs.writeFile(path.join(work, 'commands.json'), JSON.stringify(commands, null, 2));
  return {rc: p.status, out: p.stdout ?? '', err: p.stderr ?? ''};
}
function check(name, pass, details = {}) { checks.push({name, pass, assertionReached: true, ...details}); }
async function invoke(label, argv, rc, contains, stderr = false) {
  const r = await run(label, [binary, ...argv]);
  check(label, r.rc === rc && (contains === undefined || (stderr ? r.err : r.out).includes(contains)), {expectedRc: rc, actualRc: r.rc});
  return r;
}
const map = path.join(work, 'map'), trace = path.join(work, 'trace');
await fs.writeFile(map, '_CN7default15ordinaryControlHv control src/control.cj\n_CNcr5probeHv target src/concurrent.cj\n');
await fs.writeFile(trace, 'Exception: probe\r\n    at target(SOURCE:17)\r\n    at _control(SOURCE:0)\r\n    at unknown(SOURCE:3)\r\nnot a frame\r\n');
const recovered = await invoke('recover-crlf', ['-m', map, '-f', trace], 0);
check('concurrent-namespace', recovered.out.includes('    at std.concurrent.probe()(src/concurrent.cj:17)'));
check('ordinary-control', recovered.out.includes('    at default.ordinaryControl()(src/control.cj)'));
check('unmapped-and-nonframe', recovered.out.endsWith('    at unknown(SOURCE:3)\nnot a frame\n'));
await invoke('help', ['-h'], 0, 'Usage: cjtrace-recover');
await invoke('version', ['-v'], 0, 'Cangjie Trace Recover:');
await invoke('no-options', [], 1, 'Try:', true);
await invoke('unknown-option', ['--unknown'], 1, 'invalid option', true);
await invoke('missing-map-option', ['-f', trace], 1, "option '-m'", true);
await invoke('missing-trace-option', ['-m', map], 1, "option '-f'", true);
await invoke('missing-map-file', ['-m', path.join(work, 'absent'), '-f', trace], 1, 'failed to read file', true);
await invoke('missing-trace-file', ['-m', map, '-f', path.join(work, 'absent')], 1, 'failed to read file', true);
await invoke('missing-map-value', ['-m', '-f', trace], 1);
const extra = path.join(work, 'extra');
await fs.writeFile(extra, '_CN7default15ordinaryControlHv control\n');
await invoke('multi-map-path-preserved', ['-m', map + ',' + extra, '-f', trace], 0, 'src/control.cj');
await fs.writeFile(extra, '_CN7default15ordinaryControlHv control conflicting.cj\n');
await invoke('duplicate-path-rejected', ['-m', map + ',' + extra, '-f', trace], 1, 'Duplicate symbol', true);
await fs.writeFile(extra, '_CN7default5otherHv control\n');
await invoke('duplicate-name-rejected', ['-m', map + ',' + extra, '-f', trace], 1, 'Duplicate symbol', true);
for (const [label, text] of [['too-few-fields', 'only\n'], ['too-many-fields', 'one two three four\n']]) {
  await fs.writeFile(extra, text);
  await invoke(label, ['-m', extra, '-f', trace], 1, 'Invalid mapping file', true);
}
await invoke('empty-map-list-member', ['-m', map + ',', '-f', trace], 1, 'failed to read file', true);
await fs.writeFile(extra, 'user.main a\ncj_entry$ b\n_CN8std$core c\nrt$ d\n_CN7default15ordinaryControlHv control\n');
await fs.writeFile(trace, '    at a(SOURCE:0)\n    at b(SOURCE:0)\n    at c(SOURCE:0)\n    at d(SOURCE:0)\n    at control(SOURCE:2)');
const filtered = await invoke('runtime-frames-filtered', ['-m', extra, '-f', trace], 0);
check('exact-filter-output', filtered.out === '    at default.ordinaryControl()(:2)\n');
await fs.writeFile(extra, '_CN7default15ordinaryControlHv control C:\\src\\original.cj\n');
await invoke('windows-path', ['-m', extra, '-f', trace], 0, 'C:\\src\\original.cj:2');
await fs.writeFile(extra, '');
await fs.writeFile(trace, '');
const empty = await invoke('empty-input', ['-m', extra, '-f', trace], 1, 'failed to read file', true);
check('empty-output', empty.out === '');
if (baseline) {
  const oldEmpty = await run('baseline-empty-input', [baseline, '-m', extra, '-f', trace]);
  check('baseline-empty-input-contract', oldEmpty.rc === empty.rc && oldEmpty.out === empty.out);
}
// Grammar branches come from third_party/demangler/Demangler.cpp, not just
// one exported function. All travel through the public map/trace consumer.
const primitives = {u:'Unit', n:'Nothing', b:'Bool', Dh:'Float16', f:'Float32', d:'Float64', c:'Rune',
  a:'Int8', s:'Int16', i:'Int32', l:'Int64', h:'UInt8', t:'UInt16', j:'UInt32', m:'UInt64', q:'IntNative', r:'UIntNative', k:'CString'};
const cases = Object.entries(primitives).map(([code, type]) => ({name: 'primitive-' + code,
  symbol: '_CN7default5probeH' + code, expected: 'default.probe(' + type + ')'}));
cases.push({name: 'invalid-bare-D', symbol: '_CN7default5probeHD', expected: '_CN7default5probeHD'});
const types = ['CN7default3BoxE', 'RN7default3VecE', 'NN7default5ColorE', 'Pl', 'A0_l', 'A1_i',
  'T0_IliEE', 'T0_liE', 'V2_l', 'F0llE', 'FCilE', 'G_', 'CN7default3BoxIlEE'];
for (const type of types) cases.push({name: 'type-' + type, symbol: '_CN7default5probeH' + type});
cases.push({name: 'tuple-valid', symbol: '_CN7default5probeHT0_liE', expected: 'default.probe(Tuple<Int64,Int32>)'});
for (const count of [16, 17, 32, 33]) cases.push({name: 'argument-count-' + count,
  symbol: '_CN7default5probeH' + 'l'.repeat(count), expected: 'default.probe(' + Array(count).fill('Int64').join(', ') + ')'});
const table = await fs.readFile(new URL('../../../third_party/demangler/Utils.h', import.meta.url), 'utf8');
for (const [, code, pkg] of table.matchAll(/\{"([a-z]{2})", "([^"]+)"\}/g)) {
  cases.push({name: 'std-package-' + code, symbol: '_CN' + code + '5probeHv', expected: pkg + '.probe()'});
}
for (const [name, symbol] of [
  ['nested', '_CN7default3Box3getHv'], ['generic', '_CN7default2idIlEHl'],
  ['lambda', '_CN7default5probeHvL_'], ['inner-function', 'default.$lambda.1'],
  ['wrapped', '_CVN7default5probeHv$'], ['c-wrapper', '_CN7default5probeHv$real'],
  ['get-property', '_CN7default3Boxpg5valueHv'], ['set-property', '_CN7default3Boxps5valueHl'],
  ['operator', '_CN7default2plHll'], ['private-file', '_CN7defaultU12345678901233fooHv'],
  ['operator-encoded', '_CN7defaultplHll'], ['property-get', '_CN7default3Box5valuepgHv'],
  ['property-set', '_CN7default3Box5valuepsHl'], ['global-variable-valid', '_CGV7default3fooHv'],
  ['local-counter', '_CN7default3fooK_Hv'], ['module', '_CN7foo$bar3fooHv'],
  ['namespace', '_CN7abc:xyz3fooHv'], ['anonymous', '_CN03fooHv'],
  ['global-variable-init', '_CGVN7default3fooHv'], ['param-init', '_CPI7default3fooHv'],
  ...['iiHv', 'irHv', 'ifHv', 'ilHv', 'fiHv', 'flHv'].flatMap(s => [['package-' + s, '_CGP7default' + s], ['file-' + s, '_CGF7default' + s]]),
  ['bad-prefix', 'not_mangled'], ['short-prefix', '_C'], ['short-package', '_CNat'],
  ['invalid-length', '_CN999default3fooHv'], ['invalid-type', '_CN7default5probeHZ'],
]) cases.push({name, symbol});
await fs.writeFile(extra, cases.map((c, i) => `${c.symbol} s${i} source.cj`).join('\n') + '\n');
await fs.writeFile(trace, cases.map((c, i) => `    at s${i}(SOURCE:${i + 1})`).join('\n') + '\n');
const grammar = await invoke('grammar-matrix', ['-m', extra, '-f', trace], 0);
const lines = grammar.out.trimEnd().split('\n');
for (const [i, c] of cases.entries()) {
  if (c.expected) check(c.name, lines[i] === `    at ${c.expected}(source.cj:${i + 1})`, {actual: lines[i]});
}
if (baseline) {
  const old = await run('baseline-grammar', [baseline, '-m', extra, '-f', trace]);
  check('baseline-grammar-executed', old.rc === 0);
  const oldLines = old.out.trimEnd().split('\n');
  for (const [i, c] of cases.entries()) check('differential-' + c.name, lines[i] === oldLines[i], {symbol: c.symbol, actual: lines[i], expected: oldLines[i]});
}
await fs.writeFile(path.join(work, 'grammar-cases.json'), JSON.stringify(cases, null, 2));
await fs.writeFile(path.join(work, 'assertions.json'), JSON.stringify({executed: true, checks}, null, 2));
console.log(JSON.stringify({checks: checks.length, failures: checks.filter(c => !c.pass)}));
process.exitCode = checks.every(c => c.pass) ? 0 : 1;
