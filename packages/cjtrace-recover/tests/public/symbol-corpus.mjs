#!/usr/bin/env zx
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const args = process.argv.slice(process.argv.findIndex(arg => path.resolve(arg) === fileURLToPath(import.meta.url)) + 1);
const [binary, baseline, elf, work] = args;
if (!work) throw Error('usage: symbol-corpus.mjs <trace> <native-oracle> <cjc-ELF> <work>');
await fs.mkdir(work, {recursive: true});
const commands = [];
async function run(label, argv, input) {
  const p = spawnSync(argv[0], argv.slice(1), {input, encoding: 'utf8', timeout: 60000, maxBuffer: 16 * 1024 * 1024});
  await fs.writeFile(path.join(work, label + '.stdout'), p.stdout ?? '');
  await fs.writeFile(path.join(work, label + '.stderr'), p.stderr ?? '');
  commands.push({label, argv, rc: p.status, signal: p.signal, executorError: p.error?.message ?? null});
  await fs.writeFile(path.join(work, 'commands.json'), JSON.stringify(commands, null, 2));
  return p;
}
const nm = await run('producer-nm', ['nm', '--defined-only', elf]);
if (nm.status !== 0) throw Error('nm producer failed');
const names = [...new Set(nm.stdout.split('\n').map(l => l.trim().split(/\s+/).at(-1))
  .filter(s => s?.startsWith('_C') || s?.includes('.$lambda.')))];
if (!names.length) throw Error('no compiler-produced symbols');
const map = path.join(work, 'symbols.map'), trace = path.join(work, 'trace.txt');
await fs.writeFile(map, names.map((s, i) => `${s} s${i} real.cj`).join('\n') + '\n');
await fs.writeFile(trace, names.map((s, i) => `    at s${i}(SOURCE:${i + 1})`).join('\n') + '\n');
const old = await run('baseline', [baseline], names.join('\n') + '\n');
const current = await run('candidate', [binary, '-m', map, '-f', trace]);
const expected = old.stdout.trimEnd().split('\n').map((name, i) => `    at ${name}(real.cj:${i + 1})`);
const actual = current.stdout.trimEnd().split('\n');
const checks = [{name: 'both-entries-completed', assertionReached: true, pass: old.status === 0 && current.status === 0},
  {name: 'all-inputs-consumed', assertionReached: true, pass: actual.length === names.length && expected.length === names.length}];
for (const [i, symbol] of names.entries()) checks.push({name: 'symbol-' + i, symbol,
  assertionReached: old.status === 0 && current.status === 0, pass: actual[i] === expected[i], actual: actual[i], expected: expected[i]});
const groups = {compressed: names.filter(s => s.includes('Y')).length,
  concurrent: names.filter(s => s.startsWith('_CNcr')).length,
  generic: names.filter(s => s.includes('I')).length, lambda: names.filter(s => s.includes('L_') || s.includes('$lambda')).length,
  globalInit: names.filter(s => s.startsWith('_CG')).length};
await fs.writeFile(path.join(work, 'assertions.json'), JSON.stringify({executed: true, N: names.length, groups, checks}, null, 2));
console.log(JSON.stringify({N: names.length, groups, failures: checks.filter(c => !c.pass).slice(0, 12), failureCount: checks.filter(c => !c.pass).length}));
process.exitCode = checks.every(c => c.pass) ? 0 : 1;
