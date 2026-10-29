#!/usr/bin/env zx
// Use an independently installed cjpm and a fresh private directory.
import { $ } from 'zx';
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';

const [cjpm, work] = process.argv.slice(2);
assert.ok(path.isAbsolute(cjpm) && path.isAbsolute(work));
await fs.mkdir(work, { recursive: false });
const repo = path.join(work, 'remote');
const project = path.join(work, 'project');
const commands = [], checks = [];
async function write(file, data) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, data);
}
async function run(label, argv, cwd = project, success = true) {
  const result = await $({ cwd, quiet: true, nothrow: true })`${argv}`;
  await write(path.join(work, `${label}.stdout`), result.stdout);
  await write(path.join(work, `${label}.stderr`), result.stderr);
  commands.push({ label, argv, cwd, rc: result.exitCode });
  await write(path.join(work, 'commands.json'), JSON.stringify(commands, null, 2));
  if (success) assert.equal(result.exitCode, 0, label);
  else assert.notEqual(result.exitCode, 0, label);
  return result.stdout.trim();
}
async function check(label, fn) {
  try { fn(); checks.push({ label, pass: true }); }
  catch (error) { checks.push({ label, pass: false, error: error.message }); throw error; }
  finally { await write(path.join(work, 'assertions.json'), JSON.stringify({ executed: true, checks }, null, 2)); }
}
const pkg = (name, output) => `[package]\nname = "${name}"\nversion = "1.0.0"\ncjc-version = "1.0.0"\noutput-type = "${output}"\n`;
await write(path.join(repo, 'cjpm.toml'), pkg('dep', 'static'));
await write(path.join(repo, 'src/lib.cj'), 'package dep\npublic func value(): Int64 { 11 }\n');
for (const [label, args] of [
  ['init', ['init', '-b', 'selected']],
  ['author-name', ['config', 'user.name', 'Zxilly']],
  ['author-email', ['config', 'user.email', 'zxilly@outlook.com']],
  ['add-first', ['add', '.']], ['commit-first', ['commit', '-m', 'First dependency value']],
]) await run(label, ['git', ...args], repo);
const first = await run('first-sha', ['git', 'rev-parse', 'HEAD'], repo);
const manifest = pkg('consumer', 'executable') + `[dependencies]\ndep = { git = "${repo}", branch = "selected" }\n`;
await write(path.join(project, 'cjpm.toml'), manifest);
await write(path.join(project, 'cangjie-repo.toml'), '[repository.cache]\npath = "../cache"\n');
await write(path.join(project, 'src/main.cj'), 'package consumer\nimport dep.*\nmain(): Int64 { println(value()); return 0 }\n');
const lockPath = path.join(project, 'cjpm.lock');
const program = path.join(project, 'target/release/bin/main');
async function build(label, value) {
  await run(`${label}-build`, [cjpm, 'build', '-j', '2']);
  const actual = await run(`${label}-program`, [program]);
  await check(`${label}-dependency-consumed`, () => assert.equal(actual, String(value)));
}
// This legal v0 input exercises the same public loader as existing installations.
await write(lockPath, '"version" = 0 # old lock\n["requires"] # dependencies\n');
await build('v0-migrate', 11);
const original = await fs.readFile(lockPath, 'utf8');
await write(path.join(work, 'first-v1.lock'), original);
await check('v1-metadata-written', () => {
  assert.match(original, /^version = 1\s*$/m);
  assert.ok(original.includes(`git+${repo}?branch=selected#${first}`));
  assert.match(original, /version = "1\.0\.0"/);
  assert.match(original, /dependencies = \[\s*\]/);
});
// Move the remote branch. Rebuilding with the lock must still consume the old commit.
await write(path.join(repo, 'src/lib.cj'), 'package dep\npublic func value(): Int64 { 22 }\n');
await run('add-second', ['git', 'add', '.'], repo);
await run('commit-second', ['git', 'commit', '-m', 'Second dependency value'], repo);
const second = await run('second-sha', ['git', 'rev-parse', 'HEAD'], repo);
await fs.rm(path.join(project, 'target'), { recursive: true });
await build('locked-reentry', 11);
const reread = await fs.readFile(lockPath, 'utf8');
await check('v1-stable-roundtrip', () => assert.equal(reread, original));
await run('explicit-update', [cjpm, 'update']);
await build('updated-selection', 22);
const updated = await fs.readFile(lockPath, 'utf8');
await write(path.join(work, 'updated-v1.lock'), updated);
await check('v1-updated-resolved-source', () => assert.ok(updated.includes(`#${second}`)));
for (const [label, invalid] of Object.entries({
  unsupported: updated.replace(/^version = 1/m, 'version = 2'),
  negative: updated.replace(/^version = 1/m, 'version = -1'),
  stringVersion: updated.replace(/^version = 1/m, 'version = "1"'),
  missingSource: updated.replace(/^source = .*\n/m, ''),
  abbreviatedCommit: updated.replace(`#${second}`, '#1234'),
})) {
  assert.notEqual(invalid, updated, `${label} fixture changes its target`);
  await write(lockPath, invalid);
  await run(`${label}-reject`, [cjpm, 'build', '-j', '2'], project, false);
  const retained = await fs.readFile(lockPath, 'utf8');
  await check(`${label}-no-lock-rewrite`, () => assert.equal(retained, invalid));
}
// A failed resolution must not replace a previously valid lock with partial metadata.
await write(lockPath, updated);
await write(path.join(project, 'cjpm.toml'), manifest + 'absent = { path = "./missing" }\n');
await run('resolution-failure', [cjpm, 'build', '-j', '2'], project, false);
const retained = await fs.readFile(lockPath, 'utf8');
await check('failed-resolution-preserves-valid-lock', () => assert.equal(retained, updated));
await write(path.join(project, 'cjpm.toml'), manifest);
await build('restored', 22);
console.log('PASS public lock migration, metadata, dependency selection and failure preservation');
