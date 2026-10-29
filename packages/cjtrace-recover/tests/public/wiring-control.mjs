#!/usr/bin/env zx
import fs from 'node:fs/promises';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const args = process.argv.slice(process.argv.findIndex(arg => path.resolve(arg) === fileURLToPath(import.meta.url)) + 1);
const [binary, compilerInputs, work] = args;
if (!work) throw Error('usage: wiring-control.mjs <installed-trace> <concurrent-symbols-work> <work>');
await fs.mkdir(work, {recursive: true});
const map = path.join(compilerInputs, 'symbols.map'), trace = path.join(compilerInputs, 'trace.txt');
const argv = [binary, '-m', map, '-f', trace];
const p = spawnSync(argv[0], argv.slice(1), {encoding: 'utf8', timeout: 30000});
await fs.writeFile(path.join(work, 'stdout'), p.stdout ?? '');
await fs.writeFile(path.join(work, 'stderr'), p.stderr ?? '');
await fs.writeFile(path.join(work, 'command.json'), JSON.stringify({argv, rc: p.status, signal: p.signal, executorError: p.error?.message ?? null}, null, 2));
const reached = p.status === 0 && p.stdout.includes('    at ');
const checks = [
  {name: 'compiler-concurrent-symbol-restored', assertionReached: reached, pass: reached && p.stdout.includes('std.concurrent.')},
  {name: 'ordinary-independent-control', assertionReached: reached,
    pass: reached && p.stdout.split('\n').includes('    at default.ordinaryControl()(source.cj:2)')},
];
await fs.writeFile(path.join(work, 'assertions.json'), JSON.stringify({executed: true, checks}, null, 2));
console.log(JSON.stringify(checks));
process.exitCode = checks.every(c => c.pass) ? 0 : 1;
