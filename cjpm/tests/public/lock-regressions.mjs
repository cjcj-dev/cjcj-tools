#!/usr/bin/env zx
// Run only on an allocated build host with an independently installed cjpm.
// Usage: zx lock-regressions.mjs /absolute/install/cjpm /fresh/private/work registry|scripts|workspace|lifecycle
import { $ } from 'zx';
import fs from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import assert from 'node:assert/strict';

const [cjpm, work, mode] = process.argv.slice(2);
assert.ok(path.isAbsolute(cjpm) && path.isAbsolute(work));
assert.ok(['registry', 'scripts', 'workspace', 'lifecycle'].includes(mode));
await fs.mkdir(work, { recursive: false });
const commands = [], checks = [];
async function write(file, text) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, text);
}
async function run(label, argv, cwd, success = true) {
  const result = await $({ cwd, quiet: true, nothrow: true })`${argv}`;
  await write(path.join(work, `${label}.stdout`), result.stdout);
  await write(path.join(work, `${label}.stderr`), result.stderr);
  commands.push({ label, argv, cwd, rc: result.exitCode });
  await write(path.join(work, 'commands.json'), JSON.stringify(commands, null, 2));
  if (success) assert.equal(result.exitCode, 0, label);
  else assert.notEqual(result.exitCode, 0, label);
  return result;
}
async function check(label, fn) {
  try { await fn(); checks.push({ label, pass: true }); }
  catch (error) { checks.push({ label, pass: false, error: error.message }); throw error; }
  finally { await write(path.join(work, 'assertions.json'), JSON.stringify({ executed: true, checks }, null, 2)); }
}
const pkg = (name, output = 'static') => `[package]\nname = "${name}"\nversion = "1.0.0"\ncjc-version = "1.0.0"\noutput-type = "${output}"\ndescription = "Private lock regression fixture"\n`;
const read = file => fs.readFile(file, 'utf8');
const exists = file => fs.stat(file).then(() => true, () => false);
async function consumer(dir, extra = '') {
  await write(path.join(dir, 'cjpm.toml'), pkg('consumer', 'executable') + extra);
  await write(path.join(dir, 'src/main.cj'), 'package consumer\nmain(): Int64 { println(7); return 0 }\n');
  await write(path.join(dir, 'cangjie-repo.toml'), '[repository.cache]\npath = "./cache"\n');
}

async function registry() {
  // The artifact and index are produced by public cjpm bundle, not a made-up archive.
  const artifacts = {};
  for (const [name, value] of [['a', 11], ['b', 22]]) {
    const dir = path.join(work, `package-${name}`);
    await write(path.join(dir, 'cjpm.toml'), pkg('regdep') + '[profile.build]\ncjc-jobs = 2\n');
    await write(path.join(dir, 'README.md'), 'Private registry dependency.\n');
    await write(path.join(dir, 'cangjie-repo.toml'), '[repository.cache]\npath = "./cache"\n');
    await write(path.join(dir, 'src/lib.cj'), `package regdep\npublic func value(): Int64 { ${value} }\n`);
    await run(`bundle-${name}`, [cjpm, 'bundle', '--skip-test', '--skip-lint'], dir);
    artifacts[name] = {
      bytes: await fs.readFile(path.join(dir, 'target/regdep-1.0.0.cjp')),
      index: JSON.parse(await read(path.join(dir, 'target/meta-data.json'))).index,
    };
  }
  const requests = [];
  const server = http.createServer((req, res) => {
    requests.push(req.url);
    const parts = new URL(req.url, 'http://localhost').pathname.split('/').filter(Boolean);
    const artifact = artifacts[parts[0]];
    if (!artifact) { res.writeHead(404).end(); return; }
    if (parts[1] === 'index' && parts.at(-1) === 'regdep') {
      res.end(JSON.stringify(artifact.index) + '\n');
    } else if (parts.slice(1).join('/') === 'pkg/regdep/1.0.0') {
      res.end(artifact.bytes);
    } else res.writeHead(404).end();
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const dir = path.join(work, 'consumer'), lock = path.join(dir, 'cjpm.lock');
  const control = path.join(work, 'control');
  await consumer(control);
  await consumer(dir, '[dependencies]\nregdep = "1.0.0"\n');
  await write(path.join(dir, 'src/main.cj'), 'package consumer\nimport regdep.*\nmain(): Int64 { println(value()); return 0 }\n');
  async function config(registryName) {
    await write(path.join(dir, 'cangjie-repo.toml'), `[repository.cache]\npath = "./cache"\n[repository.home]\nregistry = "${base}/${registryName}"\n`);
  }
  async function build(label, value) {
    await run(label, [cjpm, 'build', '-j', '2'], dir);
    const result = await run(`${label}-consume`, [path.join(dir, 'target/release/bin/main')], dir);
    await check(`${label}-actual-dependency`, () => assert.equal(result.stdout.trim(), String(value)));
  }
  try {
    await config('a');
    await build('cold', 11);
    const original = await read(lock);
    await check('registry-metadata-produced', () => {
      assert.ok(original.includes(`registry+${base}/a`));
      assert.ok(original.includes(`sha256:${artifacts.a.index.sha256sum}`));
    });
    for (const cache of ['warm', 'cold']) {
      for (const fault of ['checksum', 'source']) {
        if (cache === 'cold') await fs.rm(path.join(dir, 'cache/repository'), { recursive: true, force: true });
        const invalid = fault === 'checksum'
          ? original.replace(`sha256:${artifacts.a.index.sha256sum}`, `sha256:${'0'.repeat(64)}`)
          : original.replace(`registry+${base}/a`, `registry+${base}/b`);
        assert.notEqual(invalid, original);
        await write(lock, invalid);
        const result = await run(`${cache}-${fault}`, [cjpm, 'build', '-j', '2'], dir, false);
        await check(`${cache}-${fault}-reached-and-preserved`, async () => {
          assert.match(result.stderr, /locked registry source\/checksum/);
          assert.equal(await read(lock), invalid);
        });
        await run(`${cache}-${fault}-control`, [cjpm, 'build', '-j', '2'], control);
        await write(lock, original);
        await build(`${cache}-${fault}-restored`, 11);
      }
    }
    const correctBytes = artifacts.a.bytes;
    artifacts.a.bytes = artifacts.b.bytes;
    await fs.rm(path.join(dir, 'cache/repository/source'), { recursive: true, force: true });
    const brokenArtifact = await run('artifact-checksum', [cjpm, 'build', '-j', '2'], dir, false);
    await check('artifact-locked-digest-reached', async () => {
      assert.match(brokenArtifact.stderr, /package does not match locked checksum/);
      assert.equal(await read(lock), original);
    });
    artifacts.a.bytes = correctBytes;
    await build('artifact-restored', 11);
    await config('b');
    await run('changed-registry-rejected', [cjpm, 'build', '-j', '2'], dir, false);
    await check('changed-registry-old-lock-safe', async () => assert.equal(await read(lock), original));
    await run('explicit-update', [cjpm, 'update', '--skip-script'], dir);
    await fs.rm(path.join(dir, 'target'), { recursive: true });
    await build('updated', 22);
    const updated = await read(lock);
    await check('updated-source-checksum', () => {
      assert.ok(updated.includes(`registry+${base}/b`));
      assert.ok(updated.includes(`sha256:${artifacts.b.index.sha256sum}`));
    });
    await build('updated-warm', 22);

    // Script resolution uses its own lock section and must carry registry pins too.
    const scriptDir = path.join(work, 'registry-script');
    await consumer(scriptDir, '[script-dependencies]\nregdep = "1.0.0"\n');
    await write(path.join(scriptDir, 'build.cj'), 'package buildscript\nimport regdep.*\nimport std.fs.*\nmain(): Int64 { File.writeTo("script-result", value().toString().toArray()); return 0 }\n');
    const scriptConfig = registryName => `[repository.cache]\npath = "./cache"\n[repository.home]\nregistry = "${base}/${registryName}"\n`;
    await write(path.join(scriptDir, 'cangjie-repo.toml'), scriptConfig('a'));
    await run('registry-script-first', [cjpm, 'build', '-j', '2'], scriptDir);
    const scriptLock = path.join(scriptDir, 'cjpm.lock');
    const firstScriptLock = await read(scriptLock);
    await check('registry-script-metadata-and-consumer', async () => {
      assert.match(firstScriptLock, /\[scripts\./);
      assert.ok(firstScriptLock.includes(`sha256:${artifacts.a.index.sha256sum}`));
      assert.equal(await read(path.join(scriptDir, 'script-result')), '11');
    });
    const invalidScriptLock = firstScriptLock.replace(`sha256:${artifacts.a.index.sha256sum}`, `sha256:${'0'.repeat(64)}`);
    assert.notEqual(invalidScriptLock, firstScriptLock);
    await write(scriptLock, invalidScriptLock);
    const scriptFailure = await run('registry-script-conflict', [cjpm, 'build', '-j', '2'], scriptDir, false);
    await check('registry-script-conflict-reached', async () => {
      assert.match(scriptFailure.stderr, /locked registry source\/checksum/);
      assert.equal(await read(scriptLock), invalidScriptLock);
    });
    await write(scriptLock, firstScriptLock);
    // Keep the warm A index: a successful B update must refresh it before the
    // pre-script asks for B's same-name/same-version artifact.
    await write(path.join(scriptDir, 'cangjie-repo.toml'), scriptConfig('b'));
    const updateRequestStart = requests.length;
    await run('registry-script-update', [cjpm, 'update'], scriptDir);
    await check('registry-script-update-consumer', async () => {
      assert.equal(await read(path.join(scriptDir, 'script-result')), '22');
      assert.ok((await read(scriptLock)).includes(`registry+${base}/b`));
      assert.ok((await read(scriptLock)).includes(`sha256:${artifacts.b.index.sha256sum}`));
      const updateRequests = requests.slice(updateRequestStart);
      const index = updateRequests.findIndex(url => url.startsWith('/b/index/') && url.endsWith('/regdep'));
      const artifact = updateRequests.indexOf('/b/pkg/regdep/1.0.0');
      assert.ok(index >= 0 && artifact > index, JSON.stringify(updateRequests));
    });
    await run('registry-script-update-control', [cjpm, 'build', '-j', '2'], control);
    await run('registry-script-update-reentry', [cjpm, 'check'], scriptDir);
    await check('registry-script-update-reentry-pinned', async () => {
      assert.equal(await read(path.join(scriptDir, 'script-result')), '22');
    });
  } finally {
    await write(path.join(work, 'http-requests.json'), JSON.stringify(requests, null, 2));
    await new Promise(resolve => server.close(resolve));
  }
}

async function scriptFixture() {
  const repo = path.join(work, 'script-dep');
  await write(path.join(repo, 'cjpm.toml'), pkg('sdep'));
  await write(path.join(repo, 'src/lib.cj'), 'package sdep\npublic func value(): Int64 { 11 }\n');
  for (const [label, args] of [
    ['init', ['init', '-b', 'selected']], ['name', ['config', 'user.name', 'Zxilly']],
    ['email', ['config', 'user.email', 'zxilly@outlook.com']], ['add', ['add', '.']],
    ['commit', ['commit', '-m', 'First script dependency']],
  ]) await run(`git-${label}`, ['git', ...args], repo);
  const first = (await run('git-first', ['git', 'rev-parse', 'HEAD'], repo)).stdout.trim();
  const script = 'package buildscript\nimport sdep.*\nimport std.fs.*\nmain(): Int64 { File.writeTo("script-result", value().toString().toArray()); return 0 }\n';
  const declaration = `[script-dependencies]\nsdep = { git = "${repo}", branch = "selected" }\n`;
  const legacy = `version = 0 # legal legacy metadata\n[requires]\n[scripts.sdep] # old resolved script\ngit = "${repo}"\nbranch = "selected"\ncommitId = "${first}"\n`;
  async function advance() {
    await write(path.join(repo, 'src/lib.cj'), 'package sdep\npublic func value(): Int64 { 22 }\n');
    await run('git-add-next', ['git', 'add', '.'], repo);
    await run('git-commit-next', ['git', 'commit', '-m', 'Next script dependency'], repo);
  }
  return { repo, first, script, declaration, legacy, advance };
}

async function scripts() {
  const f = await scriptFixture(), dir = path.join(work, 'consumer');
  await consumer(dir, f.declaration);
  await write(path.join(dir, 'build.cj'), f.script);
  const lock = path.join(dir, 'cjpm.lock'), result = path.join(dir, 'script-result');
  for (const [label, args] of [
    ['check-skip', ['check', '--skip-script']],
    ['build-skip', ['build', '--skip-script', '-j', '2']],
    ['update-skip', ['update', '--skip-script']],
  ]) {
    await write(lock, f.legacy);
    await run(label, [cjpm, ...args], dir);
    await check(`${label}-legacy-script-preserved`, async () => {
      const saved = await read(lock);
      assert.match(saved, /^version = 0$/m);
      assert.ok(saved.includes(f.first) && saved.includes(f.repo));
      assert.equal(await exists(result), false, 'skip must not execute the build script');
    });
  }
  // main.cj runs the root pre-script before doCheck. Keep that public behavior.
  await run('ordinary-check', [cjpm, 'check'], dir);
  const migrated = await read(lock);
  await check('ordinary-check-migrated', async () => {
    assert.match(migrated, /^version = 1$/m);
    assert.ok(migrated.includes(`#${f.first}`));
    assert.equal(await read(result), '11');
  });
  const broken = migrated.replace(/^version = 1/m, 'version = 2');
  await write(lock, broken);
  await run('bad-script-lock', [cjpm, 'build', '-j', '2'], dir, false);
  await check('bad-script-lock-preserved', async () => assert.equal(await read(lock), broken));
  await write(lock, migrated);
  await f.advance();
  await run('script-explicit-update', [cjpm, 'update'], dir);
  await check('script-update-consumed', async () => assert.equal(await read(result), '22'));
}

async function workspace() {
  const f = await scriptFixture(), root = path.join(work, 'workspace'), member = path.join(root, 'member');
  await write(path.join(root, 'cjpm.toml'), '[workspace]\nmembers = ["member"]\n');
  await write(path.join(root, 'cangjie-repo.toml'), '[repository.cache]\npath = "./cache"\n');
  await consumer(member, f.declaration);
  await write(path.join(member, 'build.cj'), f.script);
  const lock = path.join(member, 'cjpm.lock'), result = path.join(member, 'script-result');
  // This is the non-skip check path where the root has no pre-script producer.
  await write(path.join(root, 'cjpm.lock'), f.legacy);
  await run('workspace-check', [cjpm, 'check'], root);
  await check('workspace-check-preserves-unresolved-script', async () => {
    assert.match(await read(path.join(root, 'cjpm.lock')), /^version = 0$/m);
    assert.equal(await exists(result), false);
  });
  await fs.rm(path.join(root, 'cjpm.lock'));
  const manifest = await read(path.join(member, 'cjpm.toml'));
  await write(path.join(member, 'cjpm.toml'), manifest + '[dependencies]\nabsent = { path = "./missing" }\n');
  const firstFailure = await run('member-resolution-failure', [cjpm, 'build', '-j', '2'], root, false);
  await check('failed-outer-resolution-no-member-lock', async () => {
    assert.match(firstFailure.stderr, /missing/);
    assert.equal(await read(result), '11', 'script producer must have been reached before outer failure');
    assert.equal(await exists(lock), false);
  });
  await write(path.join(member, 'cjpm.toml'), manifest);
  await run('member-first', [cjpm, 'build', '-j', '2'], root);
  const saved = await read(lock);
  await check('member-lock-owned-and-consumed', async () => {
    assert.match(saved, /^version = 1$/m);
    assert.match(saved, /\[scripts\./);
    assert.ok(saved.includes(`#${f.first}`));
    assert.equal(await read(result), '11');
    assert.doesNotMatch(await read(path.join(root, 'cjpm.lock')), /\[scripts\./);
  });
  await f.advance();
  await run('member-warm', [cjpm, 'build', '-j', '2'], root);
  await check('member-warm-pinned', async () => assert.equal(await read(result), '11'));
  // Remove only this fixture's outputs/cache; the member lock must drive a cold reentry.
  await run('member-clean', [cjpm, 'clean', '--skip-script'], root);
  await fs.rm(path.join(root, 'cache'), { recursive: true, force: true });
  await fs.rm(path.join(member, 'cache'), { recursive: true, force: true });
  await run('member-cold-reentry', [cjpm, 'build', '-j', '2'], root);
  await check('member-cold-pinned', async () => {
    assert.equal(await read(result), '11');
    assert.equal(await read(lock), saved);
  });
  const invalid = saved.replace(/^version = 1/m, 'version = 2');
  await write(lock, invalid);
  const rootBefore = await read(path.join(root, 'cjpm.lock'));
  await run('invalid-member-lock', [cjpm, 'build', '-j', '2'], root, false);
  await check('invalid-member-both-locks-preserved', async () => {
    assert.equal(await read(lock), invalid);
    assert.equal(await read(path.join(root, 'cjpm.lock')), rootBefore);
  });
  await write(lock, saved);
  await run('member-restored', [cjpm, 'build', '-j', '2'], root);
  await write(path.join(member, 'cjpm.toml'), manifest + '[dependencies]\nabsent = { path = "./missing" }\n');
  await run('existing-member-resolution-failure', [cjpm, 'build', '-j', '2'], root, false);
  await check('existing-member-locks-preserved', async () => {
    assert.equal(await read(lock), saved);
    assert.equal(await read(path.join(root, 'cjpm.lock')), rootBefore);
  });
  await write(path.join(member, 'cjpm.toml'), manifest);
  await write(lock, f.legacy);
  await run('member-v0-migrate', [cjpm, 'build', '-j', '2'], root);
  await check('member-v0-migrated-at-member', async () => {
    assert.equal(await read(lock), saved);
    assert.equal(await read(result), '11');
  });

  const library = path.join(work, 'depmod'), user = path.join(work, 'dependency-consumer');
  await write(path.join(library, 'cjpm.toml'), pkg('depmod') + f.declaration);
  await write(path.join(library, 'src/lib.cj'), 'package depmod\npublic func ordinary(): Int64 { 7 }\n');
  await write(path.join(library, 'build.cj'), f.script);
  await consumer(user, `[dependencies]\ndepmod = { path = "${library}" }\n`);
  await write(path.join(user, 'src/main.cj'), 'package consumer\nimport depmod.*\nmain(): Int64 { println(ordinary()); return 0 }\n');
  await run('dependency-module-script', [cjpm, 'build', '-j', '2'], user);
  await check('dependency-module-lock-owned', async () => {
    assert.match(await read(path.join(library, 'cjpm.lock')), /\[scripts\./);
    assert.equal(await read(path.join(library, 'script-result')), '22');
    assert.doesNotMatch(await read(path.join(user, 'cjpm.lock')), /\[scripts\./);
  });
}

async function lifecycle() {
  const f = await scriptFixture(), dir = path.join(work, 'consumer');
  // Build the real app before introducing its build script. Keep nonempty
  // ordinary metadata to verify that final script writes preserve requires.
  const ordinary = `[dependencies]\nsdep = { git = "${f.repo}", branch = "selected" }\n`;
  await consumer(dir, ordinary);
  await write(path.join(dir, 'src/main.cj'), 'package consumer\nimport std.env.*\nimport std.fs.*\nmain(): Int64 { File.writeTo("app-result", "ran".toArray()); return if (getCommandLine().contains("--fail")) { 9 } else { 0 } }\n');
  await run('lifecycle-build-app', [cjpm, 'build', '--skip-script', '-j', '2'], dir);
  const lock = path.join(dir, 'cjpm.lock'), marker = path.join(dir, 'script-result');
  const original = await read(lock);
  await check('lifecycle-ordinary-baseline', () => {
    assert.match(original, /\[requires\./);
    assert.doesNotMatch(original, /\[scripts\./);
  });
  await write(path.join(dir, 'cjpm.toml'), pkg('consumer', 'executable') + ordinary + f.declaration);
  await write(path.join(dir, 'build.cj'), f.script);
  const requires = text => text.split(/^\[scripts(?:\.|\])/m)[0].trimEnd();
  async function preserved(label) {
    await check(label, async () => assert.equal(await read(lock), original));
  }
  async function produced(label, value) {
    await check(label, async () => assert.equal(await read(marker), String(value)));
  }
  async function saved(label, value, commit) {
    await check(label, async () => {
      const content = await read(lock);
      assert.match(content, /^version = 1$/m);
      assert.match(content, /\[scripts\./);
      assert.ok(content.includes(`#${commit}`));
      assert.equal(requires(content), requires(original));
      assert.equal(await read(marker), String(value));
    });
  }
  await run('run-skip-script-control', [cjpm, 'run', '--skip-build', '--skip-script'], dir);
  await preserved('run-skip-script-no-write');
  await check('run-skip-script-no-producer', async () => assert.equal(await exists(marker), false));

  await run('run-missing-executable', [cjpm, 'run', '--skip-build', '--name', 'absent'], dir, false);
  await produced('run-missing-reached-pre', 11);
  await preserved('run-missing-no-commit');
  await fs.rm(path.join(dir, 'app-result'));
  await run('run-program-failure', [cjpm, 'run', '--skip-build', '--', '--fail'], dir, false);
  await check('run-failure-program-reached', async () => assert.equal(await read(path.join(dir, 'app-result')), 'ran'));
  await preserved('run-program-failure-no-commit');

  const postFailure = f.script.replace('return 0', 'return if (getCommandLine().contains("post-run")) { 9 } else { 0 }')
    .replace('import std.fs.*', 'import std.fs.*\nimport std.env.*');
  await write(path.join(dir, 'build.cj'), postFailure);
  const post = await run('run-post-failure', [cjpm, 'run', '--skip-build'], dir, false);
  await check('run-post-failure-reached', () => assert.match(post.stderr, /post-run/));
  await preserved('run-post-failure-no-commit');
  await write(path.join(dir, 'build.cj'), f.script);

  await run('run-skip-first', [cjpm, 'run', '--skip-build'], dir);
  await saved('run-skip-first-persisted', 11, f.first);
  const pinned = await read(lock);
  await f.advance();
  await run('run-skip-warm', [cjpm, 'run', '--skip-build'], dir);
  await saved('run-skip-warm-pinned', 11, f.first);
  // Remove only this fixture's script outputs/cache; preserve the existing app.
  await fs.rm(path.join(dir, 'build-script-cache'), { recursive: true, force: true });
  await fs.rm(path.join(dir, 'cache'), { recursive: true, force: true });
  await run('run-skip-cold', [cjpm, 'run', '--skip-build'], dir);
  await saved('run-skip-cold-pinned', 11, f.first);

  const invalid = pinned.replace(/^version = 1/m, 'version = 2');
  await write(lock, invalid);
  await fs.rm(marker);
  await run('run-skip-invalid-lock', [cjpm, 'run', '--skip-build'], dir, false);
  await check('run-skip-invalid-preserved', async () => {
    assert.equal(await read(lock), invalid);
    assert.equal(await exists(marker), false);
  });
  await write(lock, pinned);
  await run('run-skip-restored', [cjpm, 'run', '--skip-build'], dir);
  await saved('run-skip-restored-pinned', 11, f.first);

  await write(lock, original);
  await fs.rm(path.join(dir, 'build-script-cache'), { recursive: true, force: true });
  const next = (await run('git-next', ['git', 'rev-parse', 'HEAD'], f.repo)).stdout.trim();
  await run('clean-invalid-target', [cjpm, 'clean', '--target-dir', '.'], dir, false);
  await produced('clean-failure-reached-pre', 22);
  await preserved('clean-failure-no-commit');
  await run('clean-script-control', [cjpm, 'clean', '--skip-script'], dir);
  await preserved('clean-skip-script-no-write');
  await run('clean-script-first', [cjpm, 'clean'], dir);
  await saved('clean-script-persisted', 22, next);
  await check('clean-removes-output-preserves-lock', async () => {
    assert.equal(await exists(path.join(dir, 'target')), false);
    assert.equal(await exists(path.join(dir, 'build-script-cache')), false);
    assert.equal(await exists(lock), true);
  });
}

await ({ registry, scripts, workspace, lifecycle })[mode]();
console.log(`PASS public lock regression: ${mode}`);
