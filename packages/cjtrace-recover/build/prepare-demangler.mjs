#!/usr/bin/env zx
// The compiler owns the grammar. Compile its actual sources, with only the
// AST-independent declarations from MangleUtils, rather than a vendored fork.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const [input, output] = process.argv.slice(process.argv.findIndex(arg => path.resolve(arg) === fileURLToPath(import.meta.url)) + 1);
if (!input || !output) throw Error('usage: prepare-demangler.mjs <packages/mangle/src> <output>');
await fs.mkdir(output, {recursive: true});
for (const name of ['CangjieDemangle', 'DeCompression', 'Demangler', 'DemangleUtils']) {
  await fs.copyFile(path.join(input, name + '.cj'), path.join(output, name + '.cj'));
}
const utils = await fs.readFile(path.join(input, 'MangleUtils.cj'), 'utf8');
const constants = [...utils.matchAll(/^public let .+$/gm)].map(m => m[0]);
function declaration(text, marker) {
  const start = text.indexOf(marker);
  if (start < 0) throw Error('missing compiler declaration: ' + marker);
  let end = text.indexOf('{', start), depth = 1;
  while (depth && ++end < text.length) {
    if (text[end] === '{') depth++;
    if (text[end] === '}') depth--;
  }
  if (depth) throw Error('unclosed compiler declaration: ' + marker);
  return text.slice(start, end + 1);
}
const functions = ['StartsWith', 'EndsWith', 'IsDigit', 'IsAlpha', 'IsAlnum', 'IsPrimitivePrefix']
  .map(name => declaration(utils, 'public func ' + name + '('));
const compression = await fs.readFile(path.join(input, 'Compression.cj'), 'utf8');
const containers = ['StringRef', 'IntRef'].map(name => declaration(compression, 'public class ' + name + ' {'));
await fs.writeFile(path.join(output, 'MangleUtils.cj'),
  'package cjcj::mangle\n\n' + [...constants, ...functions, ...containers].join('\n\n') + '\n');
// T271's native demangler already rejects bare D. Carry that exact, approved
// compatibility correction on generated build input. Newer compiler sources
// already own the same correction; accept only its exact reverse-applicable
// shape, rather than ignoring any failed patch or changing the input original.
const patch = fileURLToPath(new URL('mangle-bare-D.diff', import.meta.url));
function patchStatus(options) {
  const result = spawnSync('patch', ['--batch', '--fuzz=0', '-p1', '-i', patch, ...options], {cwd: output, stdio: 'inherit'});
  if (result.error) throw result.error;
  if (result.signal) throw Error('mangle-bare-D patch interrupted: ' + result.signal);
  return result.status;
}
if (patchStatus(['--forward', '--dry-run']) === 0) {
  if (patchStatus(['--forward']) !== 0) throw Error('mangle-bare-D patch failed after preparation check');
} else if (patchStatus(['--reverse', '--dry-run']) !== 0) {
  throw Error('mangle-bare-D source shape changed; update the explicit compiler source contract');
}
